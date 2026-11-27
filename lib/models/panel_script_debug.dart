class PanelScriptDebugRun {
  const PanelScriptDebugRun({
    required this.id,
    required this.path,
    required this.status,
    required this.running,
    required this.returnCode,
    required this.error,
    required this.createdAt,
    required this.updatedAt,
    this.replayed = false,
    this.requestId,
    this.active,
  });

  final String id;
  final String path;
  final String status;
  final bool running;
  final int? returnCode;
  final String error;
  final String createdAt;
  final String updatedAt;
  final bool replayed;
  final String? requestId;
  final bool? active;

  factory PanelScriptDebugRun.fromJson(Object? value, {bool replayed = false}) {
    if (value is! Map<String, dynamic> ||
        !_validId(value['id']) ||
        value['path'] is! String ||
        !_validScriptPath(value['path'] as String) ||
        !const {
          'starting',
          'running',
          'stopping',
          'succeeded',
          'failed',
          'stopped',
          'unknown',
        }.contains(value['status']) ||
        value['running'] is! bool ||
        (value.containsKey('active') && value['active'] is! bool) ||
        (value.containsKey('request_id') && !_validId(value['request_id'])) ||
        (value['returncode'] != null && value['returncode'] is! int) ||
        value['error'] is! String ||
        value['created_at'] is! String ||
        value['updated_at'] is! String) {
      throw const FormatException('脚本调试作业响应格式无效');
    }
    final status = value['status'] as String;
    final active = const {'starting', 'running', 'stopping'}.contains(status);
    if (value['running'] != active) {
      throw const FormatException('脚本调试作业状态不一致');
    }
    return PanelScriptDebugRun(
      id: value['id'] as String,
      path: value['path'] as String,
      status: status,
      running: active,
      returnCode: value['returncode'] as int?,
      error: value['error'] as String,
      createdAt: value['created_at'] as String,
      updatedAt: value['updated_at'] as String,
      replayed: replayed,
      requestId: value['request_id'] as String?,
      active: value['active'] as bool?,
    );
  }

  bool get isActive => running || active == true;
}

class PanelScriptDebugDetail {
  const PanelScriptDebugDetail({required this.run, required this.log});

  final PanelScriptDebugRun run;
  final String log;

  factory PanelScriptDebugDetail.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['log'] is! String ||
        (value['log'] as String).length > 1200 * 1024) {
      throw const FormatException('脚本调试日志响应格式无效');
    }
    return PanelScriptDebugDetail(
      run: PanelScriptDebugRun.fromJson(value['run']),
      log: value['log'] as String,
    );
  }
}

class PanelScriptDebugHistory {
  const PanelScriptDebugHistory(this.runs);

  final List<PanelScriptDebugRun> runs;

  factory PanelScriptDebugHistory.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['runs'] is! List ||
        (value['runs'] as List).length > 100) {
      throw const FormatException('脚本调试历史响应格式无效');
    }
    return PanelScriptDebugHistory(
      (value['runs'] as List)
          .map((item) => PanelScriptDebugRun.fromJson(item))
          .toList(growable: false),
    );
  }
}

bool _validId(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

bool _validScriptPath(String value) =>
    value.isNotEmpty &&
    !value.startsWith('/') &&
    !value.contains('\\') &&
    !value.contains('\u0000') &&
    value
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');
