const logCleanupOutcomes = [
  'deleted',
  'missing',
  'busy',
  'conflict',
  'failed',
  'unknown',
];

bool validLogCleanupId(Object? value, {int length = 32}) =>
    value is String && RegExp('^[a-f0-9]{$length}\$').hasMatch(value);

bool validLogCleanupFilename(String name) =>
    name.endsWith('.log') &&
    name.trim() == name &&
    name.length <= 255 &&
    !RegExp(r'[/\\:\x00-\x1f]').hasMatch(name);

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('日志清理响应格式无效');
  }
  return value;
}

int _count(Object? value, {int? max}) {
  if (value is! int || value < 0 || (max != null && value > max)) {
    throw const FormatException('日志清理数量无效');
  }
  return value;
}

String _hex(Object? value, {int length = 32}) {
  if (!validLogCleanupId(value, length: length)) {
    throw const FormatException('日志清理身份无效');
  }
  return value as String;
}

double _time(Object? value) {
  if (value is! num || !value.isFinite || value < 0) {
    throw const FormatException('日志清理时间无效');
  }
  return value.toDouble();
}

class PanelLogCleanupCapabilities {
  const PanelLogCleanupCapabilities.unsupported()
    : supported = false,
      maxFiles = 0,
      maxGroups = 0,
      previewTtlSeconds = 0;

  const PanelLogCleanupCapabilities._(
    this.supported,
    this.maxFiles,
    this.maxGroups,
    this.previewTtlSeconds,
  );

  final bool supported;
  final int maxFiles;
  final int maxGroups;
  final int previewTtlSeconds;

  factory PanelLogCleanupCapabilities.fromJson(Object? payload) {
    final root = _map(payload);
    final row = _map(root['capabilities']);
    if (root['ok'] != true || row['supported'] is! bool) {
      throw const FormatException('日志清理能力响应无效');
    }
    if (row['supported'] == false) {
      return const PanelLogCleanupCapabilities.unsupported();
    }
    final files = _count(row['max_files'], max: 200);
    final groups = _count(row['max_groups'], max: 20);
    final ttl = _count(row['preview_ttl_seconds'], max: 600);
    if (files == 0 || groups == 0 || ttl == 0) {
      throw const FormatException('日志清理能力限制无效');
    }
    return PanelLogCleanupCapabilities._(true, files, groups, ttl);
  }
}

class PanelLogCleanupItem {
  const PanelLogCleanupItem._(
    this.filename,
    this.version,
    this.group,
    this.sizeBytes,
    this.status,
  );

  final String filename;
  final String version;
  final String group;
  final int sizeBytes;
  final String status;

  factory PanelLogCleanupItem.fromJson(
    Object? payload, {
    bool preview = false,
  }) {
    final row = _map(payload);
    final name = row['filename'];
    final group = row['group'];
    final status = row['status'];
    if (name is! String ||
        !validLogCleanupFilename(name) ||
        group is! String ||
        group.length > 512 ||
        status is! String ||
        !(preview
                ? const ['ready', 'busy', 'conflict', 'missing']
                : logCleanupOutcomes)
            .contains(status)) {
      throw const FormatException('日志清理目标无效');
    }
    return PanelLogCleanupItem._(
      name,
      _hex(row['version'], length: 64),
      group,
      _count(row['size_bytes']),
      status,
    );
  }

  bool sameTarget(PanelLogCleanupItem other) =>
      filename == other.filename &&
      version == other.version &&
      group == other.group &&
      sizeBytes == other.sizeBytes;
}

List<PanelLogCleanupItem> _items(Object? value, {bool preview = false}) {
  if (value is! List || value.isEmpty || value.length > 200) {
    throw const FormatException('日志清理清单无效');
  }
  final items = value
      .map((item) => PanelLogCleanupItem.fromJson(item, preview: preview))
      .toList();
  if (items.map((item) => item.filename).toSet().length != items.length) {
    throw const FormatException('日志清理目标重复');
  }
  return List.unmodifiable(items);
}

class PanelLogCleanupPreview {
  const PanelLogCleanupPreview._({
    required this.id,
    required this.digest,
    required this.createdAt,
    required this.expiresAt,
    required this.groups,
    required this.items,
    required this.totalBytes,
  });

  final String id;
  final String digest;
  final double createdAt;
  final double expiresAt;
  final List<String> groups;
  final List<PanelLogCleanupItem> items;
  final int totalBytes;

  bool get expired => DateTime.now().millisecondsSinceEpoch / 1000 >= expiresAt;

  factory PanelLogCleanupPreview.fromJson(Object? payload) {
    final root = _map(payload);
    final row = _map(root['preview']);
    if (root['ok'] != true) throw const FormatException('日志预检查响应无效');
    final groups = row['groups'];
    final versions = _map(row['group_versions']);
    if (groups is! List ||
        groups.length > 20 ||
        groups.any(
          (group) => group is! String || group.isEmpty || group.length > 512,
        ) ||
        groups.toSet().length != groups.length ||
        versions.length != groups.length ||
        groups.any(
          (group) => !validLogCleanupId(versions[group], length: 64),
        )) {
      throw const FormatException('日志预检查分组无效');
    }
    final created = _time(row['created_at']);
    final expires = _time(row['expires_at']);
    final items = _items(row['items'], preview: true);
    final total = _count(row['total_bytes']);
    if (expires <= created ||
        expires - created > 601 ||
        _count(row['total_files'], max: 200) != items.length ||
        total != items.fold<int>(0, (sum, item) => sum + item.sizeBytes) ||
        (groups.isNotEmpty &&
            items.any((item) => !groups.contains(item.group)))) {
      throw const FormatException('日志预检查清单不一致');
    }
    return PanelLogCleanupPreview._(
      id: _hex(row['preview_id']),
      digest: _hex(row['digest'], length: 64),
      createdAt: created,
      expiresAt: expires,
      groups: List.unmodifiable(groups.cast<String>()),
      items: items,
      totalBytes: total,
    );
  }
}

class PanelLogCleanupResult {
  const PanelLogCleanupResult._(
    this.requestId,
    this.status,
    this.items,
    this.counts,
    this.reconciled,
  );

  final String requestId;
  final String status;
  final List<PanelLogCleanupItem> items;
  final Map<String, int> counts;
  final bool reconciled;

  factory PanelLogCleanupResult.fromJson(
    Object? payload, {
    required String requestId,
    required PanelLogCleanupPreview preview,
  }) {
    final root = _map(payload);
    final row = _map(root['request']);
    final status = row['status'];
    if (root['ok'] != true ||
        row['request_id'] != requestId ||
        !validLogCleanupId(requestId) ||
        !const ['completed', 'unknown', 'missing'].contains(status)) {
      throw const FormatException('日志清理回执身份不匹配');
    }
    final rawCounts = _map(row['counts']);
    if (rawCounts.length != logCleanupOutcomes.length ||
        logCleanupOutcomes.any((key) => !rawCounts.containsKey(key))) {
      throw const FormatException('日志清理计数无效');
    }
    final counts = {
      for (final key in logCleanupOutcomes)
        key: _count(rawCounts[key], max: 200),
    };
    if (status == 'missing') {
      if (row['items'] is! List ||
          (row['items'] as List).isNotEmpty ||
          counts.values.any((value) => value != 0)) {
        throw const FormatException('缺失的日志清理回执格式无效');
      }
      return PanelLogCleanupResult._(
        requestId,
        'missing',
        const [],
        Map.unmodifiable(counts),
        false,
      );
    }
    if (row['preview_id'] != preview.id ||
        row['digest'] != preview.digest ||
        row['reconciled'] is! bool) {
      throw const FormatException('日志清理回执与预检查不匹配');
    }
    _time(row['created_at']);
    final items = _items(row['items']);
    final expected = {for (final item in preview.items) item.filename: item};
    if (items.length != expected.length ||
        items.any(
          (item) =>
              !expected.containsKey(item.filename) ||
              !item.sameTarget(expected[item.filename]!),
        ) ||
        logCleanupOutcomes.any(
          (key) =>
              counts[key] != items.where((item) => item.status == key).length,
        ) ||
        (status == 'unknown') !=
            items.any((item) => item.status == 'unknown')) {
      throw const FormatException('日志清理回执目标或计数不一致');
    }
    return PanelLogCleanupResult._(
      requestId,
      status as String,
      items,
      Map.unmodifiable(counts),
      row['reconciled'] as bool,
    );
  }
}
