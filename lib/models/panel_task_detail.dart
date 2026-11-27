class PanelTaskDetail {
  const PanelTaskDetail({
    required this.task,
    required this.runtime,
    required this.history,
  });

  final Map<String, dynamic> task;
  final Map<String, dynamic> runtime;
  final List<Map<String, dynamic>> history;

  bool get active => runtime['active'] == true || runtime['running'] == true;

  String get executionLabel => switch (runtime['status']) {
    'starting' => '启动中',
    'delaying' => '延迟中',
    'retry_wait' => '等待重试',
    'stopping' => '正在停止',
    'unknown' => '结果未知',
    'success' => active ? '正在完成' : '已完成',
    'failed' => active ? '正在完成' : '运行失败',
    'timeout' => active ? '正在完成' : '运行超时',
    'start_failed' => active ? '正在完成' : '启动失败',
    _ => active ? '运行中' : '已停止',
  };

  factory PanelTaskDetail.fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['ok'] != true) {
      throw const FormatException('任务详情响应格式无效');
    }
    final task = value['task'];
    final runtime = value['runtime'];
    final history = value['history'];
    if (task is! Map<String, dynamic> ||
        task['id'] == null ||
        task['id'].toString().trim().isEmpty ||
        runtime is! Map<String, dynamic> ||
        history is! List) {
      throw const FormatException('任务详情字段格式无效');
    }
    final rows = <Map<String, dynamic>>[];
    for (final key in ['active', 'stop_requested']) {
      if (runtime.containsKey(key) && runtime[key] is! bool) {
        throw const FormatException('任务运行状态格式无效');
      }
    }
    for (final row in history) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('任务运行历史格式无效');
      }
      rows.add(Map.unmodifiable(row));
    }
    return PanelTaskDetail(
      task: Map.unmodifiable(task),
      runtime: Map.unmodifiable(runtime),
      history: List.unmodifiable(rows),
    );
  }
}
