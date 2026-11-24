class PanelTaskSummary {
  const PanelTaskSummary({
    required this.id,
    required this.name,
    required this.command,
    required this.cron,
    required this.enabled,
    required this.running,
    required this.runCount,
    this.pid,
    this.processName,
    this.collectionId = '',
    this.remark = '',
    this.pinned = false,
    this.createdAt = '',
    this.updatedAt = '',
  });

  final String id;
  final String name;
  final String command;
  final String cron;
  final bool enabled;
  final bool running;
  final int runCount;
  final String? pid;
  final String? processName;
  final String collectionId;
  final String remark;
  final bool pinned;
  final String createdAt;
  final String updatedAt;

  factory PanelTaskSummary.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('任务数据格式无效');
    }
    final id = value['id']?.toString().trim() ?? '';
    final name = value['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('任务缺少 ID 或名称');
    }
    return PanelTaskSummary(
      id: id,
      name: name,
      command: value['command']?.toString() ?? '',
      cron: value['cron']?.toString() ?? '',
      enabled: value['enabled'] == true,
      running: value['running'] == true,
      runCount: _asInt(value['run_count']),
      pid: value['pid']?.toString(),
      processName: value['process_name']?.toString(),
      collectionId: value['collection_id']?.toString() ?? '',
      remark: value['remark']?.toString() ?? '',
      pinned: value['pinned'] == true,
      createdAt: value['created_at']?.toString() ?? '',
      updatedAt: value['updated_at']?.toString() ?? '',
    );
  }

  static int _asInt(Object? value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text) ?? 0,
    _ => 0,
  };
}
