import 'dart:math';

import '../models/panel_script_debug.dart';
import 'panel_api_client.dart';

class PanelScriptDebugManager {
  const PanelScriptDebugManager(this._api);

  final PanelApiClient _api;

  static String newRequestId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<PanelScriptDebugRun> start({
    required String path,
    required String requestId,
  }) async {
    _requirePath(path);
    _requireId(requestId, 'requestId');
    const endpoint = '/api/scripts/debug-runs';
    final payload = await _api.postJson(endpoint, {
      'path': path,
      'request_id': requestId,
    });
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本调试启动响应格式无效');
      }
      final run = PanelScriptDebugRun.fromJson(
        payload['run'],
        replayed: payload['replayed'] == true,
      );
      if (run.path != path ||
          (run.requestId != null && run.requestId != requestId)) {
        throw const FormatException('脚本调试启动响应与原请求不一致');
      }
      return run;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: endpoint);
    }
  }

  Future<PanelScriptDebugHistory> fetchHistory({int limit = 20}) async {
    if (limit < 1 || limit > 100) throw ArgumentError.value(limit, 'limit');
    final path = '/api/scripts/debug-runs?limit=$limit';
    try {
      return PanelScriptDebugHistory.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelScriptDebugDetail> fetchRun(
    String debugId, {
    int lines = 1200,
  }) async {
    _requireId(debugId, 'debugId');
    if (lines < 1 || lines > 1200) throw ArgumentError.value(lines, 'lines');
    final path = '/api/scripts/debug-runs/$debugId?lines=$lines';
    try {
      final detail = PanelScriptDebugDetail.fromJson(await _api.getJson(path));
      if (detail.run.id != debugId) {
        throw const FormatException('脚本调试状态返回了其他作业');
      }
      return detail;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelScriptDebugRun> fetchRequest(String requestId) async {
    _requireId(requestId, 'requestId');
    final path = '/api/scripts/debug-requests/$requestId';
    try {
      final payload = await _api.getJson(path);
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('原调试提交响应格式无效');
      }
      final run = PanelScriptDebugRun.fromJson(payload['run']);
      if (run.requestId != requestId) {
        throw const FormatException('原调试提交返回了其他请求');
      }
      return run;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelScriptDebugRun> stop(String debugId) async {
    _requireId(debugId, 'debugId');
    final path = '/api/scripts/debug-runs/$debugId/stop';
    final payload = await _api.postJson(path, const {});
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本调试停止响应格式无效');
      }
      final run = PanelScriptDebugRun.fromJson(payload['run']);
      if (run.id != debugId) {
        throw const FormatException('停止响应返回了其他调试作业');
      }
      return run;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  static void _requireId(String value, String name) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw ArgumentError.value(value, name);
    }
  }

  static void _requirePath(String path) {
    if (path.isEmpty ||
        path.length > 4096 ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(path, 'path', '脚本路径无效');
    }
  }
}
