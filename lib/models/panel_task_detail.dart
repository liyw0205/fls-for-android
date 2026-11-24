class PanelTaskDetail {
  const PanelTaskDetail({
    required this.task,
    required this.runtime,
    required this.history,
  });

  final Map<String, dynamic> task;
  final Map<String, dynamic> runtime;
  final List<Map<String, dynamic>> history;

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
