const notifyPublicFields = {
  'BARK_GROUP',
  'BARK_SOUND',
  'PUSH_PLUS_TEMPLATE',
  'SMTP_SSL',
  'SMTP_NAME',
  'NTFY_PRIORITY',
  'GOTIFY_PRIORITY',
  'WEBHOOK_METHOD',
  'WEBHOOK_CONTENT_TYPE',
};

class PanelNotifyRecovery {
  String? requestId;
}

class NotifyField {
  const NotifyField(
    this.key,
    this.label,
    this.kind,
    this.sensitive,
    this.multiline,
    this.maxLength,
    this.options,
  );
  final String key, label, kind;
  final bool sensitive, multiline;
  final int maxLength;
  final List<String> options;

  factory NotifyField.parse(Object? raw) {
    final value = _object(raw);
    final key = _text(value['key'], 100);
    if (value['sensitive'] is! bool ||
        value['multiline'] is! bool ||
        value['max_length'] is! int ||
        (value['max_length'] as int) < 1 ||
        (value['max_length'] as int) > 16384 ||
        !const [
          'text',
          'select',
          'boolean',
          'integer',
          'secret',
        ].contains(value['kind']) ||
        (value['sensitive'] == false && !notifyPublicFields.contains(key))) {
      throw const FormatException('通知字段定义无效');
    }
    return NotifyField(
      key,
      _text(value['label'], 200),
      value['kind'] as String,
      value['sensitive'] as bool,
      value['multiline'] as bool,
      value['max_length'] as int,
      _strings(value['options'], 20, 100),
    );
  }
}

class NotifyChannel {
  const NotifyChannel(this.id, this.name, this.fields);
  final String id, name;
  final List<NotifyField> fields;

  static List<NotifyChannel> schema(Object? raw) {
    final data = _object(raw);
    if (data['ok'] != true ||
        data['channels'] is! List ||
        (data['channels'] as List).length > 30) {
      throw const FormatException('通知渠道定义无效');
    }
    final channels = (data['channels'] as List).map((raw) {
      final row = _object(raw);
      if (row['fields'] is! List || (row['fields'] as List).length > 30) {
        throw const FormatException('通知字段数量无效');
      }
      final fields = (row['fields'] as List).map(NotifyField.parse).toList();
      if (fields.map((f) => f.key).toSet().length != fields.length) {
        throw const FormatException('通知字段重复');
      }
      return NotifyChannel(
        _text(row['id'], 50),
        _text(row['name'], 200),
        List.unmodifiable(fields),
      );
    }).toList();
    if (channels.isEmpty ||
        channels.map((c) => c.id).toSet().length != channels.length) {
      throw const FormatException('通知渠道重复或为空');
    }
    return List.unmodifiable(channels);
  }
}

class PanelNotifyItem {
  const PanelNotifyItem({
    required this.id,
    required this.name,
    required this.channel,
    required this.version,
    required this.logMode,
    required this.enabled,
    required this.isDefault,
    required this.referenceCount,
    this.values = const {},
    this.configured = const {},
    this.invalidFields = const [],
  });
  final String id, name, channel, version, logMode;
  final bool enabled, isDefault;
  final int referenceCount;
  final Map<String, String> values;
  final Map<String, bool> configured;
  final List<String> invalidFields;

  factory PanelNotifyItem.parse(Object? raw, {bool detail = false}) {
    final row = _object(raw);
    if (row['enabled'] is! bool ||
        row['default'] is! bool ||
        row['reference_count'] is! int ||
        (row['reference_count'] as int) < 0 ||
        row.containsKey('config')) {
      throw const FormatException('通知配置响应无效');
    }
    final values = <String, String>{};
    final configured = <String, bool>{};
    if (detail) {
      for (final entry in _object(row['values']).entries) {
        if (!notifyPublicFields.contains(entry.key)) {
          throw const FormatException('通知响应包含非公开字段');
        }
        values[entry.key] = _text(entry.value, 500, empty: true);
      }
      for (final entry in _object(row['configured']).entries) {
        if (entry.value is! bool) throw const FormatException('通知凭据状态无效');
        configured[entry.key] = entry.value as bool;
      }
    }
    return PanelNotifyItem(
      id: _text(row['id'], 200),
      name: _text(row['name'], 200),
      channel: _text(row['channel'], 50),
      version: _version(row['version']),
      logMode: _text(row['log_mode'], 50),
      enabled: row['enabled'] as bool,
      isDefault: row['default'] as bool,
      referenceCount: row['reference_count'] as int,
      values: Map.unmodifiable(values),
      configured: Map.unmodifiable(configured),
      invalidFields: detail
          ? _strings(row['invalid_fields'], 30, 100)
          : const [],
    );
  }
}

class PanelNotifyPage {
  const PanelNotifyPage(this.items, this.page, this.pages, this.total);
  final List<PanelNotifyItem> items;
  final int page, pages, total;

  factory PanelNotifyPage.parse(Object? raw) {
    final row = _object(raw);
    if (row['ok'] != true ||
        row['items'] is! List ||
        (row['items'] as List).length > 100 ||
        row['page'] is! int ||
        row['pages'] is! int ||
        row['total'] is! int ||
        (row['page'] as int) < 1 ||
        (row['pages'] as int) < (row['page'] as int) ||
        (row['total'] as int) < (row['items'] as List).length) {
      throw const FormatException('通知列表响应无效');
    }
    return PanelNotifyPage(
      List.unmodifiable(
        (row['items'] as List).map((v) => PanelNotifyItem.parse(v)),
      ),
      row['page'] as int,
      row['pages'] as int,
      row['total'] as int,
    );
  }
}

class NotifyDefaults {
  const NotifyDefaults(this.ids, this.version);
  final List<String> ids;
  final String version;
  factory NotifyDefaults.parse(Object? raw) {
    final row = _object(raw);
    if (row['ok'] != true) throw const FormatException('默认通知响应无效');
    return NotifyDefaults(
      _strings(row['default_ids'], 1000, 200),
      _version(row['version']),
    );
  }
}

class NotifyResult {
  const NotifyResult(
    this.requestId,
    this.saved,
    this.currentMatches,
    this.confirmRequired,
    this.retryAllowed,
  );
  final String requestId;
  final bool? saved;
  final bool currentMatches, confirmRequired, retryAllowed;

  factory NotifyResult.parse(Object? raw, String id, {bool query = false}) {
    final row = _object(raw);
    if (row['ok'] != true ||
        row['request_id'] != id ||
        !row.containsKey('saved') ||
        (row['saved'] != null && row['saved'] is! bool) ||
        row['resolved'] != (row['saved'] != null)) {
      throw const FormatException('通知提交结果无效');
    }
    if (query &&
        (!const [
              'missing',
              'unknown',
              'prepared',
              'failed',
              'completed',
            ].contains(row['state']) ||
            row['retry_allowed'] is! bool ||
            (row['state'] == 'completed' && row['saved'] != true) ||
            (const ['missing', 'unknown'].contains(row['state']) &&
                row['saved'] != null) ||
            (const ['prepared', 'failed'].contains(row['state']) &&
                row['saved'] != false) ||
            (row['retry_allowed'] == true && row['saved'] != false))) {
      throw const FormatException('通知回执状态无效');
    }
    return NotifyResult(
      id,
      row['saved'] as bool?,
      row['current_matches'] == true,
      row['confirm_required'] == true,
      row['retry_allowed'] == true,
    );
  }
}

Map<String, dynamic> _object(Object? raw) {
  if (raw is! Map<String, dynamic>) throw const FormatException('通知数据格式无效');
  return raw;
}

String _text(Object? raw, int limit, {bool empty = false}) {
  if (raw is! String ||
      raw.length > limit ||
      (!empty && raw.isEmpty) ||
      RegExp(r'[\x00-\x1f]').hasMatch(raw)) {
    throw const FormatException('通知文本格式无效');
  }
  return raw;
}

String _version(Object? raw) {
  if (raw is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw)) {
    throw const FormatException('通知版本格式无效');
  }
  return raw;
}

List<String> _strings(Object? raw, int max, int limit) {
  if (raw is! List || raw.length > max) throw const FormatException('通知列表字段无效');
  return List.unmodifiable(raw.map((value) => _text(value, limit)));
}
