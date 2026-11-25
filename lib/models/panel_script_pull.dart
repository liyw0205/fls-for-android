class PanelScriptProxyOption {
  const PanelScriptProxyOption({
    required this.id,
    required this.name,
    required this.type,
  });

  final String id;
  final String name;
  final String type;

  factory PanelScriptProxyOption.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['name'] is! String ||
        value['type'] is! String) {
      throw const FormatException('代理选项响应格式无效');
    }
    return PanelScriptProxyOption(
      id: value['id'] as String,
      name: value['name'] as String,
      type: value['type'] as String,
    );
  }
}

class PanelScriptPullProgress {
  const PanelScriptPullProgress({
    required this.state,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.percent,
  });

  final String state;
  final int downloadedBytes;
  final int? totalBytes;
  final int? percent;

  factory PanelScriptPullProgress.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['state'] is! String ||
        value['downloaded_bytes'] is! int ||
        (value['total_bytes'] != null && value['total_bytes'] is! int) ||
        (value['percent'] != null && value['percent'] is! int)) {
      throw const FormatException('脚本拉取进度格式无效');
    }
    final downloaded = value['downloaded_bytes'] as int;
    final total = value['total_bytes'] as int?;
    final percent = value['percent'] as int?;
    if (downloaded < 0 ||
        (total != null && total < 0) ||
        (percent != null && (percent < 0 || percent > 100)) ||
        (percent != null &&
            (total == null || total == 0 || downloaded > total))) {
      throw const FormatException('脚本拉取进度数值无效');
    }
    return PanelScriptPullProgress(
      state: value['state'] as String,
      downloadedBytes: downloaded,
      totalBytes: total,
      percent: percent,
    );
  }
}

class PanelScriptPullJob {
  const PanelScriptPullJob({
    required this.id,
    required this.requestId,
    required this.path,
    required this.sourceHost,
    required this.status,
    required this.progress,
    required this.errorCode,
    required this.createdAt,
    required this.updatedAt,
    required this.replayed,
  });

  final String id;
  final String requestId;
  final String path;
  final String sourceHost;
  final String status;
  final PanelScriptPullProgress progress;
  final String errorCode;
  final String createdAt;
  final String updatedAt;
  final bool replayed;

  bool get isActive => const {
    'pending',
    'downloading',
    'publishing',
    'cancelling',
  }.contains(status);

  bool get isComplete => status == 'complete';

  factory PanelScriptPullJob.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(value['id'] as String) ||
        value['request_id'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(value['request_id'] as String) ||
        value['kind'] != 'file' ||
        value['path'] is! String ||
        !_validScriptPath(value['path'] as String) ||
        value['source_host'] is! String ||
        value['status'] is! String ||
        !const {
          'pending',
          'downloading',
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
      throw const FormatException('脚本拉取作业响应格式无效');
    }
    return PanelScriptPullJob(
      id: value['id'] as String,
      requestId: value['request_id'] as String,
      path: value['path'] as String,
      sourceHost: value['source_host'] as String,
      status: value['status'] as String,
      progress: PanelScriptPullProgress.fromJson(value['progress']),
      errorCode: value['error_code'] as String,
      createdAt: value['created_at'] as String,
      updatedAt: value['updated_at'] as String,
      replayed: value['replayed'] as bool,
    );
  }
}

class PanelScriptPullHistory {
  const PanelScriptPullHistory(this.items);

  final List<PanelScriptPullJob> items;

  factory PanelScriptPullHistory.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        (value['items'] as List).length > 100) {
      throw const FormatException('脚本拉取历史响应格式无效');
    }
    return PanelScriptPullHistory(
      (value['items'] as List)
          .map(PanelScriptPullJob.fromJson)
          .toList(growable: false),
    );
  }
}

class PanelScriptPullOptions {
  const PanelScriptPullOptions(this.proxies);

  final List<PanelScriptProxyOption> proxies;

  factory PanelScriptPullOptions.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['proxies'] is! List ||
        (value['proxies'] as List).length > 100) {
      throw const FormatException('脚本拉取选项响应格式无效');
    }
    return PanelScriptPullOptions(
      (value['proxies'] as List)
          .map(PanelScriptProxyOption.fromJson)
          .toList(growable: false),
    );
  }
}

bool _validScriptPath(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains('\\') &&
    !path.contains('\u0000') &&
    !path.split('/').any((part) => part.isEmpty || part == '.' || part == '..');
