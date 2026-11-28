import '../models/panel_backup.dart';

class PanelBackupOperation {
  PanelBackupOperation._({
    required this.requestId,
    required this.kind,
    this.items = const [],
    this.filename,
    this.version,
  });

  final String requestId;
  final String kind;
  final List<String> items;
  final String? filename;
  final String? version;
  PanelBackupRequest? _result;
  int _observation = 0;

  PanelBackupRequest? get result => _result;
  bool get canReview => _result?.terminal == true;

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
}

class PanelBackupRecovery {
  PanelBackupRecovery(this.panelId);

  static const maxOperations = 32;
  final String panelId;
  final _operations = <String, PanelBackupOperation>{};

  List<PanelBackupOperation> get operations =>
      List.unmodifiable(_operations.values.toList().reversed);

  PanelBackupOperation? find(String requestId) => _operations[requestId];

  void invalidateObservations() {
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

  PanelBackupOperation _admit(PanelBackupOperation operation) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(operation.requestId) ||
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
    if (_operations.containsKey(operation.requestId) ||
        _operations.values.any(
          (prior) =>
              prior.kind == operation.kind &&
              prior.filename == operation.filename &&
              prior.version == operation.version &&
              prior.items.length == operation.items.length &&
              prior.items.every(operation.items.contains),
        )) {
      throw StateError('该操作已有原请求，请先查询并核对结果');
    }
    _operations[operation.requestId] = operation;
    return operation;
  }

  void review(PanelBackupOperation operation) {
    if (!identical(_operations[operation.requestId], operation) ||
        !operation.canReview) {
      throw StateError('原请求尚未确认终态，不能移除');
    }
    _operations.remove(operation.requestId);
  }
}
