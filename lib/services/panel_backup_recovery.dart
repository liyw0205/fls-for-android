import '../models/panel_backup.dart';

class PanelBackupOperation {
  PanelBackupOperation._({
    required this.requestId,
    required this.kind,
    this.items = const [],
    this.filename,
    this.version,
    this.rootRequestId,
    this.preflightId,
    this.archiveSha256,
    this.restoreDependencies,
    this.directoriesRestored,
  });

  final String requestId;
  final String kind;
  final List<String> items;
  final String? filename;
  final String? version;
  final String? rootRequestId;
  final String? preflightId;
  final String? archiveSha256;
  final bool? restoreDependencies;
  final bool? directoriesRestored;
  PanelBackupRequest? _result;
  String? _status;
  bool _terminal = false;
  bool _cleanupRequired = false;
  int _observation = 0;

  String get key => '$kind:$requestId';
  String get rootId => rootRequestId ?? requestId;
  PanelBackupRequest? get result => _result;
  String? get status => _result?.status ?? _status;
  bool get canReview => _result?.terminal ?? _terminal;
  bool get canRetryFollowup =>
      canReview || status == 'unknown' && !_cleanupRequired;
  bool get isPreflight => kind == 'preflight' || kind == 'preflight-cancel';
  bool get isFileRequest => kind == 'create' || kind == 'delete';

  int beginObservation() => ++_observation;

  void accept(PanelBackupRequest value, int observation) {
    if (value.requestId != requestId ||
        value.kind != kind ||
        value.items.length != items.length ||
        value.items.any((item) => !items.contains(item)) ||
        value.filename != filename ||
        value.version != version) {
      throw const FormatException('备份响应与原请求意图不一致');
    }
    if (observation == _observation) _result = value;
  }

  void validatePreflight(PanelBackupPreflight value) {
    if (value.requestId != rootId ||
        (filename != null && value.filename != filename)) {
      throw const FormatException('预检查响应与原请求不一致');
    }
  }

  void acceptPreflight(PanelBackupPreflight value, int observation) {
    validatePreflight(value);
    if (observation != _observation) return;
    _status = value.status;
    _terminal = const {
      'ready',
      'failed',
      'cancelled',
      'expired',
    }.contains(_status);
  }

  void validateRestore(PanelBackupRestore value) {
    if (value.requestId != rootId ||
        (preflightId != null &&
            (value.preflightId != preflightId ||
                value.filename != filename ||
                value.archiveSha256 != archiveSha256 ||
                value.restoreDependencies != restoreDependencies ||
                value.items.length != items.length ||
                value.items.any((item) => !items.contains(item)))) ||
        (kind == 'scheduler' && value.scheduler.operationId != requestId) ||
        (const {'dependencies', 'dependency-cleanup'}.contains(kind) &&
            value.dependencies.operationId != requestId)) {
      throw const FormatException('恢复响应与原操作身份或意图不一致');
    }
  }

  void acceptRestore(PanelBackupRestore value, int observation) {
    validateRestore(value);
    if (observation != _observation) return;
    if (kind == 'scheduler' || kind == 'dependencies') {
      final followup = kind == 'scheduler'
          ? value.scheduler
          : value.dependencies;
      _status = followup.state;
      _cleanupRequired = followup.cleanupRequired;
      _terminal =
          const {'succeeded', 'failed'}.contains(_status) &&
          !followup.cleanupRequired;
    } else if (kind == 'dependency-cleanup') {
      _terminal =
          !value.dependencies.cleanupRequired &&
          value.dependencies.state != 'running';
      _status = _terminal ? 'resources_cleaned' : 'unknown';
    } else {
      _status = value.state;
      _terminal =
          !value.active &&
          !value.restoreOutcomeUnknown &&
          !value.directoryRecoveryRequired;
    }
  }

  void acceptJob(PanelBackupJob value, int observation) {
    if (value.id != rootId) throw const FormatException('取消响应不属于原备份作业');
    if (observation != _observation) return;
    _status = value.status;
    _terminal =
        !value.active &&
        const {'succeeded', 'failed', 'cancelled'}.contains(value.status);
  }
}

class PanelBackupRecovery {
  PanelBackupRecovery(this.panelId);

  static const maxOperations = 32;
  final String panelId;
  final _operations = <String, PanelBackupOperation>{};
  int _generation = 0;

  int get generation => _generation;

  List<PanelBackupOperation> get operations =>
      List.unmodifiable(_operations.values.toList().reversed);

  PanelBackupOperation? find(String requestId, {String? kind}) {
    if (kind != null) return _operations['$kind:$requestId'];
    for (final operation in _operations.values) {
      if (operation.requestId == requestId) return operation;
    }
    return null;
  }

  void invalidateObservations() {
    _generation++;
    for (final operation in _operations.values) {
      operation.beginObservation();
    }
  }

  PanelBackupOperation admitCreate(String requestId, List<String> items) =>
      _admit(
        PanelBackupOperation._(
          requestId: requestId,
          kind: 'create',
          items: List.unmodifiable(items),
        ),
      );

  PanelBackupOperation admitDelete(String requestId, PanelBackupFile file) =>
      _admit(
        PanelBackupOperation._(
          requestId: requestId,
          kind: 'delete',
          filename: file.name,
          version: file.version,
        ),
      );

  PanelBackupOperation admitPreflight(String requestId, String filename) =>
      _admit(
        PanelBackupOperation._(
          requestId: requestId,
          kind: 'preflight',
          filename: filename,
        ),
      );

  PanelBackupOperation admitRestore({
    required String requestId,
    required PanelBackupPreflight preflight,
    required List<String> items,
    required bool restoreDependencies,
  }) => _admit(
    PanelBackupOperation._(
      requestId: requestId,
      kind: 'restore',
      preflightId: preflight.requestId,
      filename: preflight.filename,
      archiveSha256: preflight.archiveSha256,
      items: List.unmodifiable(items),
      restoreDependencies: restoreDependencies,
    ),
  );

  PanelBackupOperation admitAction({
    required String kind,
    required String rootId,
    String? operationId,
    bool confirmRetry = false,
    PanelBackupRestore? restore,
    bool? directoriesRestored,
  }) {
    if (!const {
      'preflight-cancel',
      'scheduler',
      'dependencies',
      'dependency-cleanup',
      'restore-resolve',
      'directory-recovery',
      'job-cancel',
    }.contains(kind)) {
      throw ArgumentError('备份后续操作类型无效');
    }
    if (restore != null && restore.requestId != rootId) {
      throw ArgumentError('恢复记录不属于原请求');
    }
    final root = find(rootId, kind: 'restore');
    final operation = PanelBackupOperation._(
      requestId: operationId ?? rootId,
      rootRequestId: rootId,
      kind: kind,
      filename: kind == 'preflight-cancel'
          ? find(rootId, kind: 'preflight')?.filename
          : restore?.filename ?? root?.filename,
      preflightId: restore?.preflightId ?? root?.preflightId,
      archiveSha256: restore?.archiveSha256 ?? root?.archiveSha256,
      items: restore != null
          ? List.unmodifiable(restore.items)
          : root?.items ?? const [],
      restoreDependencies:
          restore?.restoreDependencies ?? root?.restoreDependencies,
      directoriesRestored: directoriesRestored,
    );
    final existing = _operations[operation.key];
    if (existing != null &&
        existing.rootId == rootId &&
        kind != 'scheduler' &&
        kind != 'dependencies') {
      if (existing.directoriesRestored != directoriesRestored) {
        throw StateError('原核对请求尚未移除，不能更改核对结论');
      }
      return existing;
    }
    return _admit(operation, confirmRetry: confirmRetry);
  }

  PanelBackupOperation _admit(
    PanelBackupOperation operation, {
    bool confirmRetry = false,
  }) {
    final idPattern = operation.kind == 'job-cancel'
        ? RegExp(r'^[A-Za-z0-9_-]{1,128}$')
        : RegExp(r'^[a-f0-9]{32}$');
    if (!idPattern.hasMatch(operation.requestId) ||
        !idPattern.hasMatch(operation.rootId) ||
        (operation.kind == 'create' &&
            (operation.items.isEmpty ||
                operation.items.length > 2 ||
                operation.items.toSet().length != operation.items.length ||
                operation.items.any(
                  (item) => !const {'data', 'scripts'}.contains(item),
                )))) {
      throw ArgumentError('备份原请求标识或范围无效');
    }
    if (operation.kind == 'delete') {
      PanelBackupFile.fromJson({
        'name': operation.filename,
        'version': operation.version,
        'size_bytes': 0,
        'modified_at': '',
      });
    }
    if (_operations.length >= maxOperations) {
      throw StateError('原请求记录已满，请先查询并移除已核对的终态记录');
    }
    if (_operations.containsKey(operation.key) ||
        _operations.values.any(
          (prior) =>
              prior.kind == operation.kind &&
              prior.rootRequestId == operation.rootRequestId &&
              prior.preflightId == operation.preflightId &&
              prior.archiveSha256 == operation.archiveSha256 &&
              prior.restoreDependencies == operation.restoreDependencies &&
              prior.filename == operation.filename &&
              prior.version == operation.version &&
              prior.items.length == operation.items.length &&
              prior.items.every(operation.items.contains) &&
              !(confirmRetry && prior.canRetryFollowup),
        )) {
      throw StateError('该操作已有原请求，请先查询并核对结果');
    }
    _operations[operation.key] = operation;
    return operation;
  }

  void review(PanelBackupOperation operation) {
    if (!identical(_operations[operation.key], operation) ||
        !operation.canReview) {
      throw StateError('原请求尚未确认终态，不能移除');
    }
    _operations.remove(operation.key);
  }
}
