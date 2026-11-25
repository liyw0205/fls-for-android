import 'dart:math';

import '../models/panel_script_pull.dart';
import 'panel_api_client.dart';

class PanelScriptPullManager {
  const PanelScriptPullManager(this._api);

  final PanelApiClient _api;

  static String newRequestId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<PanelScriptPullOptions> fetchOptions() async {
    const path = '/api/scripts/pull-options';
    try {
      return PanelScriptPullOptions.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelScriptPullJob> submitFile({
    required String url,
    required String path,
    required String requestId,
    String proxyId = '',
  }) async {
    _requirePath(path);
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw ArgumentError.value(requestId, 'requestId');
    }
    final payload = await _api.postJson('/api/scripts/pull', {
      'url': url.trim(),
      'path': path,
      'proxy_id': proxyId,
      'request_id': requestId,
    });
    return _readJob(payload, '/api/scripts/pull');
  }

  Future<PanelScriptPullHistory> fetchHistory({int limit = 20}) async {
    if (limit < 1 || limit > 100) throw ArgumentError.value(limit, 'limit');
    final path = '/api/scripts/pull-history?limit=$limit';
    try {
      return PanelScriptPullHistory.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/scripts/pull-history');
    }
  }

  Future<PanelScriptPullJob> fetchJob(String jobId) async {
    _requireId(jobId, 'jobId');
    final path = '/api/scripts/pull/$jobId';
    return _readJob(await _api.getJson(path), path);
  }

  Future<PanelScriptPullJob> cancel(String jobId) async {
    _requireId(jobId, 'jobId');
    final path = '/api/scripts/pull/$jobId/cancel';
    return _readJob(await _api.postJson(path, const {}), path);
  }

  PanelScriptPullJob _readJob(Object? payload, String path) {
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本拉取作业响应格式无效');
      }
      return PanelScriptPullJob.fromJson(payload['job']);
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
