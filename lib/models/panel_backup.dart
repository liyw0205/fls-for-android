class PanelBackupCapabilities {
  const PanelBackupCapabilities({
    required this.items,
    required this.formats,
    required this.uploadLimitBytes,
    required this.extractedLimitBytes,
    required this.entryLimit,
    this.preflightEnabled = false,
    this.preflightLimit = 0,
    this.preflightTtlSeconds = 0,
    this.restoreEnabled = false,
  });

  final List<String> items;
  final List<String> formats;
  final int uploadLimitBytes;
  final int extractedLimitBytes;
  final int entryLimit;
  final bool preflightEnabled;
  final int preflightLimit;
  final int preflightTtlSeconds;
  final bool restoreEnabled;

  factory PanelBackupCapabilities.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        value['formats'] is! List) {
      throw const FormatException('备份能力响应格式无效');
    }
    return PanelBackupCapabilities(
      items: (value['items'] as List).whereType<String>().toList(),
      formats: (value['formats'] as List).whereType<String>().toList(),
      uploadLimitBytes: _integer(value['upload_limit_bytes']),
      extractedLimitBytes: _integer(value['extracted_limit_bytes']),
      entryLimit: _integer(value['entry_limit']),
      preflightEnabled: value['preflight_enabled'] == true,
      preflightLimit: _integer(value['preflight_limit']),
      preflightTtlSeconds: _integer(value['preflight_ttl_seconds']),
      restoreEnabled: value['restore_enabled'] == true,
    );
  }
}

class PanelBackupPreflight {
  const PanelBackupPreflight({
    required this.requestId,
    required this.status,
    required this.active,
    required this.cancelAllowed,
    required this.filename,
    required this.format,
    required this.archiveSizeBytes,
    required this.archiveSha256,
    required this.items,
    required this.entryCount,
    required this.expandedBytes,
    required this.dependencyFiles,
    required this.warnings,
    required this.errorCode,
    required this.expiresAt,
  });

  final String requestId;
  final String status;
  final bool active;
  final bool cancelAllowed;
  final String filename;
  final String format;
  final int archiveSizeBytes;
  final String archiveSha256;
  final List<String> items;
  final int entryCount;
  final int expandedBytes;
  final List<String> dependencyFiles;
  final List<String> warnings;
  final String errorCode;
  final int expiresAt;

  factory PanelBackupPreflight.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['preflight'] is! Map<String, dynamic>) {
      throw const FormatException('备份预检查响应格式无效');
    }
    final record = value['preflight'] as Map<String, dynamic>;
    final id = record['preflight_id']?.toString() ?? '';
    final state = record['status']?.toString() ?? '';
    final digest = record['archive_sha256']?.toString() ?? '';
    final filename = record['filename']?.toString() ?? '';
    final format = record['format']?.toString() ?? '';
    final items = _strings(record['items']);
    final dependencies = _strings(record['dependency_files']);
    final warnings = _strings(record['warnings']);
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !const {
          'uploading',
          'checking',
          'ready',
          'failed',
          'cancelled',
          'expired',
          'unknown',
        }.contains(state) ||
        (digest.isNotEmpty && !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) ||
        filename.isEmpty ||
        filename.length > 255 ||
        filename != filename.trim() ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename.contains(':') ||
        filename.codeUnits.any((unit) => unit < 32 || unit == 127) ||
        !const {'tar.gz', 'tgz', 'tar', 'zip'}.contains(format) ||
        items.length != items.toSet().length ||
        items.any((item) => !const {'data', 'scripts'}.contains(item)) ||
        dependencies.any(
          (item) =>
              !const {'requirements.txt', 'dependencies.txt'}.contains(item),
        ) ||
        warnings.any(
          (item) => !const {
            'data_restore_may_change_panel_access',
            'contains_native_session_store',
          }.contains(item),
        )) {
      throw const FormatException('备份预检查摘要无效');
    }
    return PanelBackupPreflight(
      requestId: id,
      status: state,
      active: record['active'] == true,
      cancelAllowed: record['cancel_allowed'] == true,
      filename: filename,
      format: format,
      archiveSizeBytes: _integer(record['archive_size_bytes']),
      archiveSha256: digest,
      items: items,
      entryCount: _integer(record['entry_count']),
      expandedBytes: _integer(record['expanded_bytes']),
      dependencyFiles: dependencies,
      warnings: warnings,
      errorCode: record['error_code']?.toString() ?? '',
      expiresAt: _integer(record['expires_at']),
    );
  }
}

class PanelBackupFile {
  const PanelBackupFile({
    required this.name,
    required this.version,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String name;
  final String version;
  final int sizeBytes;
  final String modifiedAt;

  factory PanelBackupFile.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('备份文件记录格式无效');
    }
    final name = value['name']?.toString() ?? '';
    final version = value['version']?.toString() ?? '';
    if (name.isEmpty ||
        name != name.trim() ||
        name.contains('/') ||
        name.contains('\\') ||
        !name.endsWith('.tar.gz') ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) {
      throw const FormatException('备份文件身份无效');
    }
    return PanelBackupFile(
      name: name,
      version: version,
      sizeBytes: _integer(value['size_bytes']),
      modifiedAt: value['modified_at']?.toString() ?? '',
    );
  }
}

class PanelBackupFilesPage {
  const PanelBackupFilesPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelBackupFile> items;
  final int page;
  final int pages;
  final int total;

  factory PanelBackupFilesPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('备份文件分页响应格式无效');
    }
    return PanelBackupFilesPage(
      items: (value['items'] as List)
          .map(PanelBackupFile.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelBackupJob {
  const PanelBackupJob({
    required this.id,
    required this.items,
    required this.status,
    required this.active,
    required this.cancelAllowed,
    required this.cancelRequested,
    required this.filename,
    required this.sizeBytes,
    required this.createdAt,
    required this.updatedAt,
    required this.cleanupRequired,
  });

  final String id;
  final List<String> items;
  final String status;
  final bool active;
  final bool cancelAllowed;
  final bool cancelRequested;
  final String filename;
  final int sizeBytes;
  final String createdAt;
  final String updatedAt;
  final bool cleanupRequired;

  factory PanelBackupJob.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        value['items'] is! List ||
        value['status'] is! String) {
      throw const FormatException('备份作业记录格式无效');
    }
    final id = value['id'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw const FormatException('备份作业标识无效');
    }
    return PanelBackupJob(
      id: id,
      items: (value['items'] as List).whereType<String>().toList(),
      status: value['status'] as String,
      active: value['active'] == true,
      cancelAllowed: value['cancel_allowed'] == true,
      cancelRequested: value['cancel_requested'] == true,
      filename: value['filename']?.toString() ?? '',
      sizeBytes: _integer(value['size_bytes']),
      createdAt: value['created_at']?.toString() ?? '',
      updatedAt: value['updated_at']?.toString() ?? '',
      cleanupRequired: value['cleanup_required'] == true,
    );
  }
}

class PanelBackupJobsPage {
  const PanelBackupJobsPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelBackupJob> items;
  final int page;
  final int pages;
  final int total;

  factory PanelBackupJobsPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('备份作业分页响应格式无效');
    }
    return PanelBackupJobsPage(
      items: (value['items'] as List)
          .map(PanelBackupJob.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelBackupRequest {
  const PanelBackupRequest({
    required this.requestId,
    required this.kind,
    required this.status,
    required this.accepted,
    required this.items,
  });

  final String requestId;
  final String kind;
  final String status;
  final bool? accepted;
  final List<String> items;

  factory PanelBackupRequest.fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['ok'] != true) {
      throw const FormatException('备份请求查询响应格式无效');
    }
    final request = value['request'];
    if (request is! Map<String, dynamic> ||
        request['request_id'] is! String ||
        request['kind'] is! String ||
        request['status'] is! String) {
      throw const FormatException('备份请求摘要格式无效');
    }
    return PanelBackupRequest(
      requestId: request['request_id'] as String,
      kind: request['kind'] as String,
      status: request['status'] as String,
      accepted: request['accepted'] is bool
          ? request['accepted'] as bool
          : null,
      items: request['items'] is List
          ? (request['items'] as List).whereType<String>().toList()
          : const [],
    );
  }
}

int _integer(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

List<String> _strings(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];
