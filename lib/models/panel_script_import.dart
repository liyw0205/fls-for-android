class PanelScriptImportProgress {
  const PanelScriptImportProgress({
    required this.phase,
    required this.uploadedBytes,
    required this.processedBytes,
    required this.totalBytes,
    required this.totalFiles,
  });

  final String phase;
  final int uploadedBytes;
  final int processedBytes;
  final int? totalBytes;
  final int? totalFiles;

  factory PanelScriptImportProgress.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['phase'] is! String ||
        value['uploaded_bytes'] is! int ||
        value['processed_bytes'] is! int ||
        (value['total_bytes'] != null && value['total_bytes'] is! int) ||
        (value['total_files'] != null && value['total_files'] is! int)) {
      throw const FormatException('脚本导入进度格式无效');
    }
    final uploaded = value['uploaded_bytes'] as int;
    final processed = value['processed_bytes'] as int;
    final total = value['total_bytes'] as int?;
    final files = value['total_files'] as int?;
    if (uploaded < 0 ||
        processed < 0 ||
        (total != null && total < 0) ||
        (files != null && files < 0)) {
      throw const FormatException('脚本导入进度数值无效');
    }
    return PanelScriptImportProgress(
      phase: value['phase'] as String,
      uploadedBytes: uploaded,
      processedBytes: processed,
      totalBytes: total,
      totalFiles: files,
    );
  }
}

class PanelScriptImportJob {
  const PanelScriptImportJob({
    required this.id,
    required this.requestId,
    required this.kind,
    required this.path,
    required this.status,
    required this.progress,
    required this.errorCode,
    required this.createdAt,
    required this.updatedAt,
    required this.replayed,
  });

  final String id;
  final String requestId;
  final String kind;
  final String path;
  final String status;
  final PanelScriptImportProgress progress;
  final String errorCode;
  final String createdAt;
  final String updatedAt;
  final bool replayed;

  bool get isActive => const {
    'pending',
    'processing',
    'publishing',
    'cancelling',
  }.contains(status);

  bool get isCancellable => const {'pending', 'processing'}.contains(status);

  bool get isComplete => status == 'complete';

  factory PanelScriptImportJob.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_validId(value['id']) ||
        !_validId(value['request_id']) ||
        !const {'file', 'zip', 'tar', 'tar.gz'}.contains(value['kind']) ||
        value['path'] is! String ||
        !_validScriptPath(value['path'] as String) ||
        value['source_host'] != 'local-upload' ||
        !const {
          'pending',
          'processing',
          'publishing',
          'cancelling',
          'complete',
          'failed',
          'cancelled',
          'unknown',
        }.contains(value['status']) ||
        value['error_code'] is! String ||
        value['created_at'] is! String ||
        value['updated_at'] is! String ||
        value['replayed'] is! bool) {
      throw const FormatException('脚本导入作业响应格式无效');
    }
    return PanelScriptImportJob(
      id: value['id'] as String,
      requestId: value['request_id'] as String,
      kind: value['kind'] as String,
      path: value['path'] as String,
      status: value['status'] as String,
      progress: PanelScriptImportProgress.fromJson(value['progress']),
      errorCode: value['error_code'] as String,
      createdAt: value['created_at'] as String,
      updatedAt: value['updated_at'] as String,
      replayed: value['replayed'] as bool,
    );
  }
}

class PanelScriptImportHistory {
  const PanelScriptImportHistory(this.items);

  final List<PanelScriptImportJob> items;

  factory PanelScriptImportHistory.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        (value['items'] as List).length > 100) {
      throw const FormatException('脚本导入历史响应格式无效');
    }
    return PanelScriptImportHistory(
      (value['items'] as List)
          .map(PanelScriptImportJob.fromJson)
          .toList(growable: false),
    );
  }
}

bool _validId(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

bool _validScriptPath(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains('\\') &&
    !path.contains('\u0000') &&
    !path.split('/').any((part) => part.isEmpty || part == '.' || part == '..');
