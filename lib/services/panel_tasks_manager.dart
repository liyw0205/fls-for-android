import '../models/panel_task_detail.dart';
import '../models/panel_task_draft.dart';
import '../models/panel_task_summary.dart';
import 'panel_api_client.dart';

class PanelTasksManager {
  const PanelTasksManager(this._api);

  final PanelApiClient _api;

  Future<PanelTaskFormOptions> fetchTaskFormOptions() async {
    final payload = await _api.getJson('/api/tasks/form-options');
    try {
      return PanelTaskFormOptions.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/tasks/form-options');
    }
  }

  Future<Map<String, dynamic>> createTask(
    PanelTaskDraft task, {
    required String requestId,
  }) async {
    final payload = await _api.postJson('/api/tasks', {
      'request_id': requestId,
      'task': task.toJson(),
    });
    return _savedTaskPayload(payload, '/api/tasks');
  }

  Future<Map<String, dynamic>> updateTask(
    String taskId,
    PanelTaskDraft task, {
    required String expectedUpdatedAt,
  }) async {
    final path = '/api/tasks/${Uri.encodeComponent(taskId)}';
    final payload = await _api.putJson(path, {
      'expected_updated_at': expectedUpdatedAt,
      'task': task.toJson(),
    });
    return _savedTaskPayload(payload, path);
  }

  Future<Map<String, dynamic>> reloadScheduler() async {
    const path = '/api/scheduler/reload';
    final payload = await _api.postJson(path, const {});
    if (payload is! Map<String, dynamic> || payload['ok'] != true) {
      final message = payload is Map<String, dynamic>
          ? payload['msg']?.toString()
          : null;
      throw PanelApiException(
        message?.trim().isNotEmpty == true ? message!.trim() : '调度器重载失败',
        path: path,
      );
    }
    return payload;
  }

  Map<String, dynamic> _savedTaskPayload(Object? payload, String path) {
    if (payload is! Map<String, dynamic> || payload['ok'] != true) {
      final message = payload is Map<String, dynamic>
          ? payload['msg']?.toString()
          : null;
      throw PanelApiException(
        message?.trim().isNotEmpty == true ? message!.trim() : '保存任务失败',
        path: path,
      );
    }
    return payload;
  }

  Future<List<PanelTaskSummary>> fetchTasks() async {
    final payload = await _api.getJson('/api/status');
    if (payload is! List) throw const FormatException('任务列表格式无效');
    return payload.map(PanelTaskSummary.fromJson).toList();
  }

  Future<PanelTaskDetail> fetchTaskDetail(String taskId) async {
    final path = '/api/task/${Uri.encodeComponent(taskId)}';
    final payload = await _api.getJson(path);
    try {
      return PanelTaskDetail.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<String> fetchTaskLog(String taskId, {int lines = 300}) async {
    if (lines < 1 || lines > 1000) {
      throw ArgumentError.value(lines, 'lines', '必须在 1 到 1000 之间');
    }
    final path = '/api/task/${Uri.encodeComponent(taskId)}/log?lines=$lines';
    final payload = await _api.getJson(path);
    if (payload is! Map<String, dynamic> || payload['ok'] != true) {
      final message = payload is Map<String, dynamic>
          ? payload['msg']?.toString()
          : null;
      throw PanelApiException(
        message?.trim().isNotEmpty == true ? message!.trim() : '任务日志格式无效',
        path: path,
      );
    }
    final log = payload['log'];
    if (log is! String) throw const FormatException('任务日志格式无效');
    return log;
  }

  Future<void> performAction(
    String action,
    String taskId, {
    bool? enabled,
  }) async {
    if (!const {'run', 'stop', 'toggle'}.contains(action)) {
      throw ArgumentError.value(action, 'action', '不支持的任务操作');
    }
    final payload = await _api.postJson(
      '/api/task/action/${Uri.encodeComponent(action)}/${Uri.encodeComponent(taskId)}',
      <String, Object?>{'enabled': ?enabled},
    );
    if (payload is! Map<String, dynamic> || payload['ok'] != true) {
      final message = payload is Map<String, dynamic>
          ? payload['msg']?.toString()
          : null;
      throw PanelApiException(
        message?.trim().isNotEmpty == true ? message!.trim() : '任务操作失败',
        path: '/api/task/action/$action/$taskId',
      );
    }
  }
}
