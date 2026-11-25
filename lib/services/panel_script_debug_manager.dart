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
      return PanelScriptDebugRun.fromJson(
        payload['run'],
        replayed: payload['replayed'] == true,
      );
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
      return PanelScriptDebugDetail.fromJson(await _api.getJson(path));
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
      return PanelScriptDebugRun.fromJson(payload['run']);
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
