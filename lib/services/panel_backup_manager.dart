import 'dart:io';
import 'dart:math';

import '../models/panel_backup.dart';
import 'panel_api_client.dart';

class PanelBackupManager {
  const PanelBackupManager(this._api);

  final PanelApiClient _api;

  static String newRequestId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Future<PanelBackupCapabilities> fetchCapabilities() async {
    const path = '/api/backup/native/capabilities';
    try {
      return PanelBackupCapabilities.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupFilesPage> fetchFiles({
    int page = 1,
    int limit = 25,
  }) async {
    _validatePage(page, limit);
    const path = '/api/backup/native/files';
    final query = Uri(queryParameters: {'page': '$page', 'limit': '$limit'});
    try {
      return PanelBackupFilesPage.fromJson(
        await _api.getJson('$path?${query.query}'),
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupJobsPage> fetchJobs({int page = 1, int limit = 25}) async {
    _validatePage(page, limit);
    const path = '/api/backup/native/jobs';
    final query = Uri(queryParameters: {'page': '$page', 'limit': '$limit'});
    try {
      return PanelBackupJobsPage.fromJson(
        await _api.getJson('$path?${query.query}'),
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupJob> fetchJob(String jobId) async {
    _validateId(jobId);
    final path = '/api/backup/native/jobs/${Uri.encodeComponent(jobId)}';
    final value = await _api.getJson(path);
    if (value is! Map<String, dynamic> || value['ok'] != true) {
      throw PanelApiException('备份作业响应格式无效', path: path);
    }
    try {
      return PanelBackupJob.fromJson(value['job']);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRequest> requestStatus(String requestId) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/requests/$requestId';
    try {
      return PanelBackupRequest.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupPreflight> createPreflight({
    required String filePath,
    required String filename,
    required String requestId,
    required int maxBytes,
    required void Function(int sentBytes, int totalBytes) onProgress,
  }) async {
    _validateRequestId(requestId);
    _validateArchiveFilename(filename);
    if (maxBytes < 1) throw ArgumentError.value(maxBytes, 'maxBytes');
    final file = File(filePath);
    final size = await file.length();
    if (size < 1 || size > maxBytes) {
      throw PanelApiException('备份文件超过面板有效上传上限', statusCode: 413);
    }
    const path = '/api/backup/native/preflights';
    try {
      return PanelBackupPreflight.fromJson(
        await _api.postMultipartFile(
          path,
          filePath: filePath,
          filename: filename,
          fields: {'preflight_id': requestId},
          onProgress: onProgress,
          timeout: const Duration(minutes: 30),
        ),
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupPreflight> fetchPreflight(String requestId) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/preflights/$requestId';
    try {
      return PanelBackupPreflight.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupPreflight> cancelPreflight(String requestId) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/preflights/$requestId/cancel';
    try {
      return PanelBackupPreflight.fromJson(await _api.postJson(path, const {}));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<Map<String, dynamic>> create({
    required String requestId,
    required List<String> items,
    bool confirmRetry = false,
  }) async {
    _validateRequestId(requestId);
    if (items.isEmpty ||
        items.any((item) => !const {'data', 'scripts'}.contains(item)) ||
        items.toSet().length != items.length) {
      throw ArgumentError('备份范围无效');
    }
    final value = await _api.postJson('/api/backup/native/jobs', {
      'request_id': requestId,
      'items': items,
      if (confirmRetry) 'confirm_retry': true,
    });
    return _responseMap(value, '/api/backup/native/jobs');
  }

  Future<Map<String, dynamic>> cancel(String jobId) async {
    _validateId(jobId);
    final path = '/api/backup/native/jobs/$jobId/cancel';
    return _responseMap(await _api.postJson(path, const {}), path);
  }

  Future<Map<String, dynamic>> deleteFile({
    required String requestId,
    required PanelBackupFile file,
  }) async {
    _validateRequestId(requestId);
    const path = '/api/backup/native/files/delete';
    return _responseMap(
      await _api.postJson(path, {
        'request_id': requestId,
        'filename': file.name,
        'version': file.version,
      }),
      path,
    );
  }

  Future<int> downloadFile({
    required PanelBackupFile file,
    required String destinationPath,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
  }) {
    final query = Uri(queryParameters: {'version': file.version});
    final path =
        '/api/backup/native/files/${Uri.encodeComponent(file.name)}/download?${query.query}';
    return _api.downloadFile(
      path,
      destinationPath: destinationPath,
      onProgress: onProgress,
    );
  }

  static Map<String, dynamic> _responseMap(Object? value, String path) {
    if (value is! Map<String, dynamic>) {
      throw PanelApiException('备份操作响应格式无效', path: path);
    }
    return value;
  }

  static void _validatePage(int page, int limit) {
    if (page < 1 || page > 100000 || limit < 1 || limit > 100) {
      throw ArgumentError('备份分页参数无效');
    }
  }

  static void _validateId(String jobId) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(jobId)) {
      throw ArgumentError('备份作业标识无效');
    }
  }

  static void _validateRequestId(String requestId) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId)) {
      throw ArgumentError('备份请求标识无效');
    }
  }

  static void _validateArchiveFilename(String filename) {
    final lower = filename.toLowerCase();
    if (filename.isEmpty ||
        filename.length > 255 ||
        filename != filename.trim() ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename.contains(':') ||
        filename.codeUnits.any((unit) => unit < 32 || unit == 127) ||
        !const ['.tar.gz', '.tgz', '.tar', '.zip'].any(lower.endsWith)) {
      throw ArgumentError('备份文件名或格式无效');
    }
  }
}
