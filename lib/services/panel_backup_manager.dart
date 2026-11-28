import 'dart:io';
import 'dart:math';

import '../models/panel_backup.dart';
import '../models/panel_directory_maintenance.dart';
import '../models/panel_dependency_maintenance.dart';
import 'panel_api_client.dart';
import 'panel_backup_recovery.dart';

class PanelBackupManager {
  PanelBackupManager(this._api, {PanelBackupRecovery? recovery})
    : recovery = recovery ?? PanelBackupRecovery(_api.panelId) {
    if (this.recovery.panelId != _api.panelId) {
      throw ArgumentError('备份原请求记录不属于当前面板');
    }
  }

  final PanelApiClient _api;
  final PanelBackupRecovery recovery;

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
    final operation = recovery.find(jobId, kind: 'job-cancel');
    final observation = operation?.beginObservation();
    final value = await _api.getJson(path);
    if (value is! Map<String, dynamic> || value['ok'] != true) {
      throw PanelApiException('备份作业响应格式无效', path: path);
    }
    try {
      final result = PanelBackupJob.fromJson(value['job']);
      if (result.id != jobId) throw const FormatException('备份作业响应不属于原请求');
      operation?.acceptJob(result, observation!);
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRequest> requestStatus(String requestId) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/requests/$requestId';
    final operation = recovery.find(requestId);
    final observation = operation?.beginObservation();
    try {
      final result = PanelBackupRequest.fromJson(await _api.getJson(path));
      if (result.requestId != requestId) {
        throw const FormatException('备份响应与原请求标识不一致');
      }
      if (operation != null) operation.accept(result, observation!);
      return result;
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
    final generation = recovery.generation;
    final file = File(filePath);
    final size = await file.length();
    if (size < 1 || size > maxBytes) {
      throw PanelApiException('备份文件超过面板有效上传上限', statusCode: 413);
    }
    const path = '/api/backup/native/preflights';
    late PanelBackupOperation operation;
    late int observation;
    try {
      final result = _parsePreflight(
        await _api.postMultipartFile(
          path,
          filePath: filePath,
          filename: filename,
          fields: {'preflight_id': requestId},
          onProgress: onProgress,
          timeout: const Duration(minutes: 30),
          beforeSend: () {
            if (generation != recovery.generation) {
              throw const PanelApiException('备份页面状态已改变，请重新选择文件');
            }
            // File preparation can outlive the page that requested the upload.
            operation = recovery.admitPreflight(requestId, filename);
            observation = operation.beginObservation();
          },
        ),
        requestId,
      );
      operation.acceptPreflight(result, observation);
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupPreflight> fetchPreflight(String requestId) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/preflights/$requestId';
    final observations = _observations(requestId, preflight: true);
    try {
      final result = _parsePreflight(await _api.getJson(path), requestId);
      for (final (operation, observation) in observations) {
        operation.acceptPreflight(result, observation);
      }
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupPreflight> cancelPreflight(String requestId) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/preflights/$requestId/cancel';
    final operation = recovery.admitAction(
      kind: 'preflight-cancel',
      rootId: requestId,
    );
    final observation = operation.beginObservation();
    try {
      final result = _parsePreflight(
        await _api.postJson(path, const {}),
        requestId,
      );
      operation.acceptPreflight(result, observation);
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  PanelBackupPreflight _parsePreflight(Object? value, String requestId) {
    final result = PanelBackupPreflight.fromJson(value);
    if (result.requestId != requestId) {
      throw const FormatException('预检查响应与原请求标识不一致');
    }
    recovery.find(requestId, kind: 'preflight')?.validatePreflight(result);
    return result;
  }

  List<(PanelBackupOperation, int)> _observations(
    String rootId, {
    bool preflight = false,
  }) => [
    for (final operation in recovery.operations)
      if (operation.rootId == rootId &&
          !operation.isFileRequest &&
          operation.kind != 'job-cancel' &&
          operation.isPreflight == preflight)
        (operation, operation.beginObservation()),
  ];

  Future<Object> queryOperation(PanelBackupOperation operation) async {
    if (!identical(
      recovery.find(operation.requestId, kind: operation.kind),
      operation,
    )) {
      throw ArgumentError('原请求记录不属于当前面板');
    }
    if (operation.isFileRequest) return requestStatus(operation.requestId);
    if (operation.kind == 'job-cancel') return fetchJob(operation.rootId);
    if (operation.isPreflight) return fetchPreflight(operation.rootId);
    return fetchRestore(
      operation.rootId,
      expectedSchedulerOperationId: operation.kind == 'scheduler'
          ? operation.requestId
          : null,
      expectedDependencyOperationId:
          const {'dependencies', 'dependency-cleanup'}.contains(operation.kind)
          ? operation.requestId
          : null,
    );
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
    final operation = recovery.admitRestore(
      requestId: requestId,
      preflight: preflight,
      items: items,
      restoreDependencies: restoreDependencies,
    );
    final observation = operation.beginObservation();
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
      operation.acceptRestore(result, observation);
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRestore> fetchRestore(
    String requestId, {
    String? expectedDependencyOperationId,
    String? expectedSchedulerOperationId,
  }) async {
    _validateRequestId(requestId);
    if (expectedDependencyOperationId != null) {
      _validateRequestId(expectedDependencyOperationId);
    }
    if (expectedSchedulerOperationId != null) {
      _validateRequestId(expectedSchedulerOperationId);
    }
    final path = '/api/backup/native/restores/$requestId';
    final observations = _observations(requestId);
    try {
      final result = _parseRestore(await _api.getJson(path), requestId);
      if (expectedDependencyOperationId != null &&
          result.dependencies.operationId != expectedDependencyOperationId) {
        throw const FormatException('依赖查询响应不属于原操作');
      }
      if (expectedSchedulerOperationId != null &&
          result.scheduler.operationId != expectedSchedulerOperationId) {
        throw const FormatException('调度器查询响应不属于原操作');
      }
      for (final (operation, observation) in observations) {
        if (operation.kind == 'scheduler' &&
            result.scheduler.operationId != operation.requestId) {
          continue;
        }
        if (const {
              'dependencies',
              'dependency-cleanup',
            }.contains(operation.kind) &&
            result.dependencies.operationId != operation.requestId) {
          continue;
        }
        operation.acceptRestore(result, observation);
      }
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRestore> resolveRestore({
    required String requestId,
    required bool restored,
    PanelBackupRestore? expectedRestore,
  }) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/restores/$requestId/resolve';
    final operation = recovery.admitAction(
      kind: 'restore-resolve',
      rootId: requestId,
      restore: expectedRestore,
      directoriesRestored: restored,
    );
    final observation = operation.beginObservation();
    try {
      final result = _parseRestore(
        await _api.postJson(path, {
          'outcome': restored ? 'restored' : 'not_applied',
          'confirm': true,
        }),
        requestId,
      );
      operation.acceptRestore(result, observation);
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRestore> recoverRestoreDirectories(
    String requestId, {
    PanelBackupRestore? expectedRestore,
  }) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/restores/$requestId/recover-directories';
    final operation = recovery.admitAction(
      kind: 'directory-recovery',
      rootId: requestId,
      restore: expectedRestore,
    );
    final observation = operation.beginObservation();
    try {
      final result = _parseRestore(
        await _api.postJson(path, {'confirm': true}),
        requestId,
      );
      operation.acceptRestore(result, observation);
      return result;
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

  Future<PanelDependencyMaintenancePage> fetchDependencyMaintenance({
    int offset = 0,
    int limit = 25,
  }) async {
    if (offset < 0 || offset > 100000 || limit < 1 || limit > 100) {
      throw ArgumentError('依赖现场分页参数无效');
    }
    const path = '/api/backup/native/dependency-maintenance';
    try {
      final page = PanelDependencyMaintenancePage.fromJson(
        await _api.getJson('$path?offset=$offset&limit=$limit'),
      );
      if (page.offset != offset || page.limit != limit) {
        throw const FormatException('依赖现场响应不属于原分页请求');
      }
      return page;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelDependencyMaintenance> fetchDependencyEvidence(
    String requestId,
    String operationId,
  ) async {
    _validateRequestId(requestId);
    _validateRequestId(operationId);
    final path =
        '/api/backup/native/dependency-maintenance/$requestId/$operationId';
    return _parseDependencyEvidence(
      await _api.getJson(path),
      requestId,
      operationId,
      path,
    );
  }

  Future<PanelDependencyMaintenance> cleanupOrphanDependency(
    PanelDependencyMaintenance evidence,
  ) async {
    _validateRequestId(evidence.requestId);
    _validateRequestId(evidence.operationId);
    if (!evidence.cleanupAllowed ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(evidence.version)) {
      throw ArgumentError('此依赖现场不能清理');
    }
    final path =
        '/api/backup/native/dependency-maintenance/${evidence.identity}/cleanup';
    return _parseDependencyEvidence(
      await _api.postJson(path, {'confirm': true, 'version': evidence.version}),
      evidence.requestId,
      evidence.operationId,
      path,
    );
  }

  PanelDependencyMaintenance _parseDependencyEvidence(
    Object? value,
    String requestId,
    String operationId,
    String path,
  ) {
    try {
      if (value is! Map<String, dynamic> || value['ok'] != true) {
        throw const FormatException('依赖现场响应无效');
      }
      final row = PanelDependencyMaintenance.fromJson(value['dependency']);
      if (row.requestId != requestId || row.operationId != operationId) {
        throw const FormatException('依赖现场响应不属于原操作');
      }
      return row;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelDirectoryMaintenancePage> fetchDirectoryMaintenance({
    int offset = 0,
    int limit = 25,
    bool includeFinalized = false,
  }) async {
    if (offset < 0 || offset > 100000 || limit < 1 || limit > 100) {
      throw ArgumentError('目录现场分页参数无效');
    }
    const path = '/api/backup/native/directory-maintenance';
    try {
      final result = PanelDirectoryMaintenancePage.fromJson(
        await _api.getJson(
          '$path?offset=$offset&limit=$limit'
          '${includeFinalized ? '&include_finalized=1' : ''}',
        ),
      );
      if (result.offset != offset || result.limit != limit) {
        throw const FormatException('目录现场响应不属于原分页请求');
      }
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelDirectoryMaintenance> fetchDirectoryEvidence(
    String requestId,
  ) async {
    _validateRequestId(requestId);
    final path = '/api/backup/native/directory-maintenance/$requestId';
    return _parseDirectoryEvidence(await _api.getJson(path), requestId, path);
  }

  Future<PanelDirectoryMaintenance> recoverOrphanDirectory(
    PanelDirectoryMaintenance evidence,
  ) async {
    _validateRequestId(evidence.requestId);
    if (!evidence.recoverAllowed ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(evidence.version)) {
      throw ArgumentError('此目录现场不能恢复');
    }
    final path =
        '/api/backup/native/directory-maintenance/${evidence.requestId}/recover';
    final result = _parseDirectoryEvidence(
      await _api.postJson(path, {'confirm': true, 'version': evidence.version}),
      evidence.requestId,
      path,
    );
    if (!const {'restored', 'not_applied'}.contains(result.outcome) ||
        result.restoreItems.join(',') != evidence.restoreItems.join(',')) {
      throw PanelApiException('目录恢复响应尚未确认原现场结果', path: path);
    }
    return result;
  }

  PanelDirectoryMaintenance _parseDirectoryEvidence(
    Object? value,
    String requestId,
    String path,
  ) {
    try {
      if (value is! Map<String, dynamic> || value['ok'] != true) {
        throw const FormatException('目录现场响应无效');
      }
      final result = PanelDirectoryMaintenance.fromJson(value['directory']);
      if (result.requestId != requestId) {
        throw const FormatException('目录现场响应不属于原请求');
      }
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelDirectoryMaintenance> finalizeOrphanDirectory(
    PanelDirectoryMaintenance evidence,
  ) async {
    _validateRequestId(evidence.requestId);
    if (!evidence.finalizeAllowed ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(evidence.version)) {
      throw ArgumentError('此目录现场不能结束维护');
    }
    final path =
        '/api/backup/native/directory-maintenance/${evidence.requestId}/finalize';
    final result = _parseDirectoryEvidence(
      await _api.postJson(path, {'confirm': true, 'version': evidence.version}),
      evidence.requestId,
      path,
    );
    if (result.state != 'finalized' ||
        result.outcome != evidence.outcome ||
        result.restoreItems.join(',') != evidence.restoreItems.join(',')) {
      throw PanelApiException('现场结束响应尚未确认原目录结果', path: path);
    }
    return result;
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
    PanelBackupRestore? expectedRestore,
  }) => _postRestoreFollowup(
    requestId,
    'scheduler-reload',
    operationId,
    confirmRetry,
    expectedRestore,
  );

  Future<PanelBackupRestore> installRestoreDependencies({
    required String requestId,
    required String operationId,
    bool confirmRetry = false,
    PanelBackupRestore? expectedRestore,
  }) => _postRestoreFollowup(
    requestId,
    'dependencies',
    operationId,
    confirmRetry,
    expectedRestore,
  );

  Future<PanelBackupRestore> cleanupRestoreDependencies({
    required String requestId,
    required String operationId,
    PanelBackupRestore? expectedRestore,
  }) async {
    _validateRequestId(requestId);
    _validateRequestId(operationId);
    final path = '/api/backup/native/restores/$requestId/dependencies/cleanup';
    final operation = recovery.admitAction(
      kind: 'dependency-cleanup',
      rootId: requestId,
      operationId: operationId,
      restore: expectedRestore,
    );
    final observation = operation.beginObservation();
    try {
      final result = _parseRestore(
        await _api.postJson(path, {'operation_id': operationId}),
        requestId,
      );
      if (result.dependencies.operationId != operationId) {
        throw const FormatException('依赖清理响应不属于原操作');
      }
      operation.acceptRestore(result, observation);
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
    PanelBackupRestore? expectedRestore,
  ) async {
    _validateRequestId(requestId);
    _validateRequestId(operationId);
    final path = '/api/backup/native/restores/$requestId/$operation';
    final record = recovery.admitAction(
      kind: operation == 'scheduler-reload' ? 'scheduler' : 'dependencies',
      rootId: requestId,
      operationId: operationId,
      confirmRetry: confirmRetry,
      restore: expectedRestore,
    );
    final observation = record.beginObservation();
    try {
      final result = _parseRestore(
        await _api.postJson(path, {
          'operation_id': operationId,
          'confirm_retry': confirmRetry,
        }),
        requestId,
      );
      record.acceptRestore(result, observation);
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  PanelBackupRestore _parseRestore(Object? value, String requestId) {
    final result = PanelBackupRestore.fromJson(value);
    if (result.requestId != requestId) {
      throw const FormatException('恢复响应与原请求标识不一致');
    }
    recovery.find(requestId, kind: 'restore')?.validateRestore(result);
    return result;
  }

  Future<PanelBackupRequest> create({
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
    final operation = recovery.admitCreate(requestId, items);
    final observation = operation.beginObservation();
    const path = '/api/backup/native/jobs';
    try {
      final value = await _api.postJson(path, {
        'request_id': requestId,
        'items': operation.items,
        if (confirmRetry) 'confirm_retry': true,
      });
      if (value is! Map<String, dynamic> ||
          value['ok'] != true ||
          value['accepted'] != true ||
          value['request_id'] != requestId ||
          (value['job'] != null && value['job'] is! Map<String, dynamic>)) {
        throw const FormatException('备份受理响应与原请求不一致');
      }
      final job = value['job'] as Map<String, dynamic>?;
      if (job != null && (job['id'] != requestId || job['active'] is! bool)) {
        throw const FormatException('备份作业不属于原请求');
      }
      final result = PanelBackupRequest.fromJson({
        'ok': true,
        'request': {
          'request_id': requestId,
          'kind': 'create',
          'status': job?['status'] ?? 'unknown',
          'active': job?['active'] ?? false,
          'accepted': true,
          'items': job == null ? operation.items : job['items'],
        },
      });
      operation.accept(result, observation);
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<Map<String, dynamic>> cancel(String jobId) async {
    _validateId(jobId);
    final path = '/api/backup/native/jobs/$jobId/cancel';
    final operation = recovery.admitAction(kind: 'job-cancel', rootId: jobId);
    final observation = operation.beginObservation();
    try {
      final result = _responseMap(await _api.postJson(path, const {}), path);
      if (result['job_id'] != jobId) {
        throw const FormatException('取消响应不属于原备份作业');
      }
      if (result['job'] != null) {
        operation.acceptJob(
          PanelBackupJob.fromJson(result['job']),
          observation,
        );
      }
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelBackupRequest> deleteFile({
    required String requestId,
    required PanelBackupFile file,
  }) async {
    _validateRequestId(requestId);
    _validateArchiveFilename(file.name);
    _validateDigest(file.version);
    const path = '/api/backup/native/files/delete';
    final operation = recovery.admitDelete(requestId, file);
    final observation = operation.beginObservation();
    try {
      final value = await _api.postJson(path, {
        'request_id': requestId,
        'filename': operation.filename,
        'version': operation.version,
      });
      if (value is! Map<String, dynamic> ||
          value['ok'] != true ||
          value['accepted'] != true ||
          value['deleted'] != true ||
          value['status'] != 'deleted') {
        throw const FormatException('备份删除响应未确认结果');
      }
      final result = PanelBackupRequest.fromJson({
        'ok': true,
        'request': {
          'request_id': value['request_id'],
          'kind': 'delete',
          'status': 'succeeded',
          'active': false,
          'accepted': value['accepted'],
          'deleted': value['deleted'],
          'filename': value['filename'],
          'version': value['version'],
        },
      });
      operation.accept(result, observation);
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
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
