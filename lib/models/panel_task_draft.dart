class PanelTaskDraft {
  const PanelTaskDraft({
    required this.name,
    required this.remark,
    required this.command,
    required this.cron,
    required this.configPath,
    required this.collectionId,
    required this.enabled,
    required this.environment,
    required this.proxyId,
    required this.notifyMode,
    required this.notifyIds,
    required this.randomDelayMode,
    required this.randomDelaySeconds,
    required this.retryAttempts,
    required this.retryIntervalSeconds,
    this.updatedAt = '',
  });

  factory PanelTaskDraft.empty() => const PanelTaskDraft(
    name: '',
    remark: '',
    command: 'task ',
    cron: '',
    configPath: '',
    collectionId: '',
    enabled: true,
    environment: {},
    proxyId: '',
    notifyMode: 'default',
    notifyIds: [],
    randomDelayMode: 'none',
    randomDelaySeconds: 1,
    retryAttempts: 0,
    retryIntervalSeconds: 60,
  );

  factory PanelTaskDraft.fromTask(Map<String, dynamic> task) {
    final environment = task['env'];
    final notify = task['notify'];
    final delay = task['random_delay'];
    final retry = task['retry'];
    final notifyIds = notify is Map && notify['ids'] is List
        ? (notify['ids'] as List).whereType<String>().toList()
        : const <String>[];
    return PanelTaskDraft(
      name: _string(task['name']),
      remark: _string(task['remark']),
      command: _string(task['command']),
      cron: _string(task['cron']),
      configPath: _string(task['config_path']),
      collectionId: _string(task['collection_id']),
      enabled: task['enabled'] == true,
      environment: environment is Map
          ? environment.map(
              (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
            )
          : const {},
      proxyId: _string(task['proxy_id']),
      notifyMode: notify is Map
          ? _string(notify['mode'], fallback: 'default')
          : 'default',
      notifyIds: notifyIds,
      randomDelayMode: delay is Map
          ? _string(delay['mode'], fallback: 'none')
          : 'none',
      randomDelaySeconds: _integer(delay is Map ? delay['seconds'] : null, 1),
      retryAttempts: _integer(retry is Map ? retry['attempts'] : null, 0),
      retryIntervalSeconds: _integer(
        retry is Map ? retry['interval_seconds'] : null,
        60,
      ),
      updatedAt: _string(task['updated_at']),
    );
  }

  final String name;
  final String remark;
  final String command;
  final String cron;
  final String configPath;
  final String collectionId;
  final bool enabled;
  final Map<String, String> environment;
  final String proxyId;
  final String notifyMode;
  final List<String> notifyIds;
  final String randomDelayMode;
  final int randomDelaySeconds;
  final int retryAttempts;
  final int retryIntervalSeconds;
  final String updatedAt;

  Map<String, Object?> toJson() => {
    'name': name,
    'remark': remark,
    'command': command,
    'cron': cron,
    'config_path': configPath,
    'collection_id': collectionId,
    'enabled': enabled,
    'env': environment,
    'proxy_id': proxyId,
    'notify': {'mode': notifyMode, 'ids': notifyIds},
    'random_delay': {
      'mode': randomDelayMode,
      'seconds': randomDelayMode == 'custom' ? randomDelaySeconds : 0,
    },
    'retry': {
      'attempts': retryAttempts,
      'interval_seconds': retryIntervalSeconds,
    },
  };

  static String _string(Object? value, {String fallback = ''}) =>
      value?.toString() ?? fallback;

  static int _integer(Object? value, int fallback) => switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text) ?? fallback,
    _ => fallback,
  };
}

class PanelTaskFormOption {
  const PanelTaskFormOption({
    required this.id,
    required this.name,
    this.detail = '',
  });

  final String id;
  final String name;
  final String detail;

  factory PanelTaskFormOption.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('任务表单选项格式无效');
    }
    final id = _asString(value['id']);
    final name = _asString(value['name']);
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('任务表单选项缺少标识或名称');
    }
    return PanelTaskFormOption(
      id: id,
      name: name,
      detail: _asString(value['channel_name'] ?? value['type']),
    );
  }

  static String _asString(Object? value) => value?.toString().trim() ?? '';
}

class PanelTaskFormOptions {
  const PanelTaskFormOptions({
    required this.collections,
    required this.proxies,
    required this.notifications,
  });

  final List<PanelTaskFormOption> collections;
  final List<PanelTaskFormOption> proxies;
  final List<PanelTaskFormOption> notifications;

  factory PanelTaskFormOptions.fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['ok'] != true) {
      throw const FormatException('任务表单选项响应无效');
    }
    List<PanelTaskFormOption> parse(String key) {
      final raw = value[key];
      if (raw is! List) throw FormatException('$key 格式无效');
      return raw.map(PanelTaskFormOption.fromJson).toList(growable: false);
    }

    return PanelTaskFormOptions(
      collections: parse('collections'),
      proxies: parse('proxies'),
      notifications: parse('notifications'),
    );
  }
}
