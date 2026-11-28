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

  Future<PanelBackupRestore> createRestore({
    required String requestId,
    required PanelBackupPreflight preflight,
    required List<String> items,
    required bool restoreDependencies,
    required bool confirmDataImpact,
  }) async {
    _validateRequestId(requestId);
    _validateRequestId(preflight.requestId);
    _validateDigest(preflight.archiveSha256);
    if (items.isEmpty ||
        items.any((item) => !preflight.items.contains(item)) ||
        items.toSet().length != items.length ||
        (items.contains('data') && !confirmDataImpact) ||
        (restoreDependencies && preflight.dependencyFiles.isEmpty)) {
      throw ArgumentError('恢复范围或确认无效');
    }
    const path = '/api/backup/native/restores';
    try {
      final result = _parseRestore(
        await _api.postJson(path, {
          'request_id': requestId,
          'preflight_id': preflight.requestId,
          'archive_sha256': preflight.archiveSha256,
          'restore_items': items,
          'restore_dependencies': restoreDependencies,
          'confirm_data_impact': confirmDataImpact,
        }),
        requestId,
      );
      if (result.preflightId != preflight.requestId ||
          result.archiveSha256 != preflight.archiveSha256 ||
          result.items.length != items.length ||
          result.items.any((item) => !items.contains(item)) ||
          result.restoreDependencies != restoreDependencies) {
        throw const FormatException('恢复响应与原提交意图不一致');
      }
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRestore> fetchRestore(
    String requestId, {
    String? expectedDependencyOperationId,
  }) async {
    _validateRequestId(requestId);
    if (expectedDependencyOperationId != null) {
      _validateRequestId(expectedDependencyOperationId);
    }
    final path = '/api/backup/native/restores/$requestId';
    try {
      final result = _parseRestore(await _api.getJson(path), requestId);
      if (expectedDependencyOperationId != null &&
          result.dependencies.operationId != expectedDependencyOperationId) {
        throw const FormatException('依赖查询响应不属于原操作');
      }
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRestore> resolveRestore({
    required String requestId,
    required bool restored,
  }) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/restores/$requestId/resolve';
    try {
      return _parseRestore(
        await _api.postJson(path, {
          'outcome': restored ? 'restored' : 'not_applied',
          'confirm': true,
        }),
        requestId,
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRestore> recoverRestoreDirectories(String requestId) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/restores/$requestId/recover-directories';
    try {
      return _parseRestore(
        await _api.postJson(path, {'confirm': true}),
        requestId,
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRestoresPage> fetchRestores({
    int limit = 25,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > 100 || offset < 0 || offset > 100000) {
      throw ArgumentError('恢复历史分页参数无效');
    }
    const path = '/api/backup/native/restores';
    final query = Uri(
      queryParameters: {'limit': '$limit', 'offset': '$offset'},
    );
    try {
      return PanelBackupRestoresPage.fromJson(
        await _api.getJson('$path?${query.query}'),
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupMaintenance> fetchRestoreMaintenance() async {
    const path = '/api/backup/native/restore-maintenance';
    try {
      return PanelBackupMaintenance.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupMaintenance> acknowledgeRestoreMaintenance(
    String eventId,
  ) async {
    _validateRequestId(eventId);
    final path = '/api/backup/native/restore-maintenance/$eventId/ack';
    try {
      return PanelBackupMaintenance.fromJson(
        await _api.postJson(path, const {}),
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRestore> reloadScheduler({
    required String requestId,
    required String operationId,
    bool confirmRetry = false,
  }) => _postRestoreFollowup(
    requestId,
    'scheduler-reload',
    operationId,
    confirmRetry,
  );

  Future<PanelBackupRestore> installRestoreDependencies({
    required String requestId,
    required String operationId,
    bool confirmRetry = false,
  }) => _postRestoreFollowup(
    requestId,
    'dependencies',
    operationId,
    confirmRetry,
  );

  Future<PanelBackupRestore> cleanupRestoreDependencies({
    required String requestId,
    required String operationId,
  }) async {
    _validateRequestId(requestId);
    _validateRequestId(operationId);
    final path = '/api/backup/native/restores/$requestId/dependencies/cleanup';
    try {
      final result = _parseRestore(
        await _api.postJson(path, {'operation_id': operationId}),
        requestId,
      );
      if (result.dependencies.operationId != operationId) {
        throw const FormatException('依赖清理响应不属于原操作');
      }
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRestore> _postRestoreFollowup(
    String requestId,
    String operation,
    String operationId,
    bool confirmRetry,
  ) async {
    _validateRequestId(requestId);
    _validateRequestId(operationId);
    final path = '/api/backup/native/restores/$requestId/$operation';
    try {
      return _parseRestore(
        await _api.postJson(path, {
          'operation_id': operationId,
          'confirm_retry': confirmRetry,
        }),
        requestId,
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  PanelBackupRestore _parseRestore(Object? value, String requestId) {
    final result = PanelBackupRestore.fromJson(value);
    if (result.requestId != requestId) {
      throw const FormatException('恢复响应与原请求标识不一致');
    }
    return result;
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

  static void _validateDigest(String digest) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw ArgumentError('归档摘要无效');
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
