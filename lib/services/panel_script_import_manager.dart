import 'dart:io';

import '../models/panel_script_import.dart';
import 'panel_api_client.dart';
import 'panel_script_pull_manager.dart';

typedef PanelScriptImportUploadProgress =
    void Function(int sentBytes, int totalBytes);

class PanelScriptImportManager {
  const PanelScriptImportManager(this._api);

  static const maxUploadBytes = 64 * 1024 * 1024;

  final PanelApiClient _api;

  Future<PanelScriptImportJob> submit({
    required String filePath,
    required String filename,
    required String path,
    required String requestId,
    required PanelScriptImportUploadProgress onProgress,
  }) async {
    _requirePath(path);
    if (filename.trim().isEmpty ||
        filename != filename.trim() ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename.contains('\u0000') ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw ArgumentError('脚本导入参数无效');
    }
    final file = File(filePath);
    final size = await file.length();
    if (size > maxUploadBytes) {
      throw const PanelApiException('文件超过 64 MiB 限制', statusCode: 413);
    }
    final payload = await _api.postMultipartFile(
      '/api/scripts/import',
      filePath: filePath,
      filename: filename,
      fields: {'path': path, 'request_id': requestId},
      onProgress: onProgress,
    );
    return _readJob(payload, '/api/scripts/import');
  }

  Future<PanelScriptImportHistory> fetchHistory({int limit = 20}) async {
    if (limit < 1 || limit > 100) throw ArgumentError.value(limit, 'limit');
    const path = '/api/scripts/import-history';
    try {
      return PanelScriptImportHistory.fromJson(
        await _api.getJson('$path?limit=$limit'),
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelScriptImportJob> fetchJob(String jobId) async {
    _requireId(jobId, 'jobId');
    final path = '/api/scripts/import/$jobId';
    return _readJob(await _api.getJson(path), path);
  }

  Future<PanelScriptImportJob> cancel(String jobId) async {
    _requireId(jobId, 'jobId');
    final path = '/api/scripts/import/$jobId/cancel';
    return _readJob(await _api.postJson(path, const {}), path);
  }

  PanelScriptImportJob _readJob(Object? payload, String path) {
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本导入作业响应格式无效');
      }
      return PanelScriptImportJob.fromJson(payload['job']);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  static String kindForFilename(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.zip')) return 'zip';
    if (lower.endsWith('.tar')) return 'tar';
    if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) return 'tar.gz';
    return 'file';
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

  static String newRequestId() => PanelScriptPullManager.newRequestId();
}
