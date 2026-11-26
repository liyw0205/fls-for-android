class PanelConfigRecovery {
  String? requestId;
  bool isApply = false;
}

class PanelConfigSettings {
  const PanelConfigSettings({
    required this.settings,
    required this.revision,
    required this.credentials,
    required this.apply,
    required this.schema,
  });

  final Map<String, Object?> settings;
  final String revision;
  final Map<String, Object?> credentials;
  final Map<String, Object?> apply;
  final Map<String, Object?> schema;

  static const themes = {
    'deepseek',
    'neumorphism',
    'editorial',
    'glassmorphism',
  };
  static const taskTypes = {
    'py',
    'sh',
    'js',
    'ts',
    'ps1',
    'bat',
    'php',
    'rb',
    'pl',
    'lua',
    'jar',
  };
  static const numberLimits = <String, (int, int?)>{
    'port': (1, 65535),
    'log_cleanup_minutes': (1, 1440),
    'log_max_size_mb': (1, null),
    'log_keep_per_task': (1, null),
    'task_timeout_seconds': (0, null),
    'random_delay_seconds': (0, 120),
  };

  bool get tokenConfigured => credentials['token_configured'] == true;
  bool get tokenManagedByEnvironment =>
      credentials['token_managed_by_environment'] == true;
  bool get totpConfigured => credentials['totp_configured'] == true;
  bool get securityEnabled => credentials['security_verify_enabled'] == true;
  String get securityType => credentials['security_verify_type'] as String;
  String get applyStatus => apply['status'] as String;

  factory PanelConfigSettings.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['settings'] is! Map<String, dynamic> ||
        value['credentials'] is! Map<String, dynamic> ||
        value['apply'] is! Map<String, dynamic> ||
        value['schema'] is! Map<String, dynamic> ||
        value['revision'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['revision'] as String)) {
      throw const FormatException('面板配置响应格式无效');
    }
    final settings = value['settings'] as Map<String, dynamic>;
    final credentials = value['credentials'] as Map<String, dynamic>;
    final apply = value['apply'] as Map<String, dynamic>;
    final schema = value['schema'] as Map<String, dynamic>;
    final types = settings['task_types'];
    if (!themes.contains(settings['theme']) ||
        settings['online_script_source'] is! String ||
        settings['online_script_source_requires_reveal'] is! bool ||
        types is! Map<String, dynamic> ||
        types.keys.any((key) => !taskTypes.contains(key)) ||
        types.isEmpty ||
        types.values.any((value) => value is! bool) ||
        numberLimits.entries.any((entry) {
          final number = settings[entry.key];
          return number is! int ||
              number < entry.value.$1 ||
              (entry.value.$2 != null && number > entry.value.$2!);
        }) ||
        settings.containsKey('admin_token') ||
        settings.containsKey('totp_secret') ||
        !const {
          'succeeded',
          'failed',
          'unknown',
          '',
        }.contains(apply['status']) ||
        credentials['token_configured'] is! bool ||
        credentials['token_managed_by_environment'] is! bool ||
        credentials['totp_configured'] is! bool ||
        credentials['security_verify_enabled'] is! bool ||
        !const {'code', 'totp'}.contains(credentials['security_verify_type'])) {
      throw const FormatException('面板配置响应字段无效');
    }
    return PanelConfigSettings(
      settings: Map.unmodifiable(settings),
      revision: value['revision'] as String,
      credentials: Map.unmodifiable(credentials),
      apply: Map.unmodifiable(apply),
      schema: Map.unmodifiable(schema),
    );
  }
}

class PanelConfigResult {
  const PanelConfigResult({
    required this.requestId,
    required this.saved,
    required this.applyStatus,
    required this.state,
    required this.revision,
    required this.reauthRequired,
  });

  final String requestId;
  final bool? saved;
  final String? applyStatus;
  final String state;
  final String revision;
  final bool reauthRequired;

  bool get applied => applyStatus == 'succeeded';

  factory PanelConfigResult.fromJson(Object? value, {String? expectedId}) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['request_id'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['request_id'] as String) ||
        (expectedId != null && value['request_id'] != expectedId) ||
        !value.containsKey('saved') ||
        !(value['saved'] == null || value['saved'] is bool) ||
        !(value['apply_status'] == null ||
            const {
              'pending',
              'succeeded',
              'failed',
              'unknown',
            }.contains(value['apply_status'])) ||
        (value['revision'] is! String && value['revision'] != null) ||
        (value['state'] != null &&
            !const {
              'prepared',
              'pending',
              'completed',
              'failed',
              'missing',
              'unknown',
            }.contains(value['state'])) ||
        (value['saved'] == true &&
            (!RegExp(
                  r'^[a-f0-9]{64}$',
                ).hasMatch(value['revision'] as String? ?? '') ||
                value['apply_status'] == null ||
                value['reauth_required'] is! bool)) ||
        (const {'succeeded', 'failed'}.contains(value['apply_status']) &&
            value['saved'] != true)) {
      throw const FormatException('配置操作响应格式无效');
    }
    return PanelConfigResult(
      requestId: value['request_id'] as String,
      saved: value['saved'] as bool?,
      applyStatus: value['apply_status'] as String?,
      state: value['state'] as String? ?? '',
      revision: value['revision'] as String? ?? '',
      reauthRequired: value['reauth_required'] == true,
    );
  }
}
