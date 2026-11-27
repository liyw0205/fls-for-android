import 'dart:convert';

class PanelTaskConfigSnapshot {
  const PanelTaskConfigSnapshot({
    required this.taskId,
    required this.path,
    required this.content,
    required this.revision,
    required this.exists,
    required this.maxBytes,
  });

  final String taskId;
  final String path;
  final String content;
  final String revision;
  final bool exists;
  final int maxBytes;

  factory PanelTaskConfigSnapshot.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['task_id'] is! String ||
        (value['task_id'] as String).isEmpty ||
        value['path'] is! String ||
        (value['path'] as String).isEmpty ||
        value['content'] is! String ||
        value['revision'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['revision'] as String) ||
        value['exists'] is! bool ||
        value['max_bytes'] is! int) {
      throw const FormatException('任务配置响应格式无效');
    }
    final maximum = value['max_bytes'] as int;
    final content = value['content'] as String;
    if (maximum < 1 ||
        maximum > 1024 * 1024 ||
        content.length > maximum ||
        utf8.encode(content).length > maximum) {
      throw const FormatException('任务配置超过编辑上限');
    }
    return PanelTaskConfigSnapshot(
      taskId: value['task_id'] as String,
      path: value['path'] as String,
      content: content,
      revision: value['revision'] as String,
      exists: value['exists'] as bool,
      maxBytes: maximum,
    );
  }
}

class PanelTaskConfigSubmission {
  const PanelTaskConfigSubmission({
    required this.taskId,
    required this.requestId,
    required this.status,
    required this.path,
    required this.cleanupRequired,
  });

  final String taskId;
  final String requestId;
  final String status;
  final String path;
  final bool cleanupRequired;

  factory PanelTaskConfigSubmission.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['task_id'] is! String ||
        value['request_id'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['request_id'] as String) ||
        value['path'] is! String ||
        !const {
          'saved',
          'not_saved',
          'unknown',
          'missing',
        }.contains(value['status']) ||
        (value['cleanup_required'] != null &&
            value['cleanup_required'] is! bool)) {
      throw const FormatException('任务配置提交响应格式无效');
    }
    final status = value['status'] as String;
    final expectedSaved = status == 'saved'
        ? true
        : status == 'not_saved'
        ? false
        : null;
    if (!value.containsKey('saved') ||
        value['saved'] != expectedSaved ||
        (status != 'missing' && (value['path'] as String).isEmpty)) {
      throw const FormatException('任务配置提交状态无效');
    }
    return PanelTaskConfigSubmission(
      taskId: value['task_id'] as String,
      requestId: value['request_id'] as String,
      status: status,
      path: value['path'] as String,
      cleanupRequired: value['cleanup_required'] == true,
    );
  }
}

class PanelTaskConfigRecovery {
  String? requestId;
}
