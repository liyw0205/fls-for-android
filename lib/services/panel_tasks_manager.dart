import 'dart:math';

import '../models/panel_collection.dart';
import '../models/panel_task_detail.dart';
import '../models/panel_task_draft.dart';
import '../models/panel_task_summary.dart';
import 'panel_api_client.dart';

class PanelTasksManager {
  const PanelTasksManager(this._api);

  final PanelApiClient _api;

  Future<PanelCollectionPage> fetchCollections({
    String query = '',
    int page = 1,
    int limit = 50,
  }) async {
    final queryString = Uri(
      queryParameters: {'q': query, 'page': '$page', 'limit': '$limit'},
    ).query;
    const path = '/api/collections';
    final payload = await _api.getJson('$path?$queryString');
    try {
      return PanelCollectionPage.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelCollectionTaskPage> fetchCollectionTasks(
    String collectionId, {
    String view = 'members',
    String query = '',
    int page = 1,
    int limit = 50,
  }) async {
    if (!const {'members', 'available'}.contains(view)) {
      throw ArgumentError.value(view, 'view', '合集任务视图无效');
    }
    final path = '/api/collection/${Uri.encodeComponent(collectionId)}';
    final queryString = Uri(
      queryParameters: {
        'view': view,
        'q': query,
        'page': '$page',
        'limit': '$limit',
      },
    ).query;
    final payload = await _api.getJson('$path?$queryString');
    try {
      return PanelCollectionTaskPage.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<Map<String, dynamic>> saveCollection({
    required String requestId,
    required String name,
    required String remark,
    String collectionId = '',
    String? collectionVersion,
  }) async {
    final payload = await _api.postJson('/api/collection/save', {
      'request_id': requestId,
      'collection_id': collectionId,
      'name': name,
      'remark': remark,
      ...?collectionVersion == null
          ? null
          : {'collection_version': collectionVersion},
    });
    return _collectionMutationPayload(payload, '/api/collection/save');
  }

  Future<Map<String, dynamic>> addTasksToCollection({
    required String collectionId,
    required List<String> taskIds,
    required Map<String, String> expectedCollections,
    required String requestId,
  }) async {
    final path =
        '/api/collection/add-task/${Uri.encodeComponent(collectionId)}';
    final payload = await _api.postJson(path, {
      'request_id': requestId,
      'task_ids': taskIds,
      'expected_collections': expectedCollections,
    });
    return _collectionMutationPayload(payload, path);
  }

  Future<Map<String, dynamic>> removeTaskFromCollection({
    required String taskId,
    required String collectionId,
    required String requestId,
  }) async {
    final path =
        '/api/task/action/clear_collection/${Uri.encodeComponent(taskId)}';
    final payload = await _api.postJson(path, {
      'request_id': requestId,
      'expected_collection': collectionId,
    });
    return _collectionMutationPayload(payload, path);
  }

  Future<Map<String, dynamic>> deleteCollection({
    required String collectionId,
    required List<String> expectedMembers,
    required String collectionVersion,
    required String requestId,
  }) async {
    final path = '/api/collection/delete/${Uri.encodeComponent(collectionId)}';
    final payload = await _api.postJson(path, {
      'request_id': requestId,
      'expected_members': expectedMembers,
      'collection_version': collectionVersion,
    });
    return _collectionMutationPayload(payload, path);
  }

  static String newRequestId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Map<String, dynamic> _collectionMutationPayload(
    Object? payload,
    String path,
  ) {
    if (payload is! Map<String, dynamic> || payload['ok'] != true) {
      final message = payload is Map<String, dynamic>
          ? payload['msg']?.toString()
          : null;
      throw PanelApiException(
        message?.trim().isNotEmpty == true ? message!.trim() : '合集操作失败',
        path: path,
      );
    }
    return payload;
  }

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
