class PanelDependency {
  const PanelDependency({required this.name, required this.version});

  final String name;
  final String version;

  factory PanelDependency.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['name'] is! String ||
        value['version'] is! String ||
        (value['name'] as String).isEmpty ||
        (value['name'] as String).length > 200 ||
        (value['version'] as String).length > 200) {
      throw const FormatException('依赖包记录格式无效');
    }
    return PanelDependency(
      name: value['name'] as String,
      version: value['version'] as String,
    );
  }
}

class PanelDependencyPage {
  const PanelDependencyPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelDependency> items;
  final int page;
  final int pages;
  final int total;

  factory PanelDependencyPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        (value['items'] as List).length > 100) {
      throw const FormatException('依赖分页响应格式无效');
    }
    return PanelDependencyPage(
      items: (value['items'] as List)
          .map(PanelDependency.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelRuntime {
  const PanelRuntime({
    required this.key,
    required this.name,
    required this.suffix,
    required this.status,
    required this.version,
    required this.detail,
    required this.installable,
    required this.installError,
  });

  final String key;
  final String name;
  final String suffix;
  final String status;
  final String version;
  final String detail;
  final bool installable;
  final String installError;

  factory PanelRuntime.fromJson(Object? value) {
    const statuses = {'available', 'missing', 'error', 'timeout'};
    if (value is! Map<String, dynamic> ||
        value['key'] is! String ||
        !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(value['key'] as String) ||
        value['name'] is! String ||
        value['suffix'] is! String ||
        !statuses.contains(value['status']) ||
        value['installable'] is! bool) {
      throw const FormatException('运行时状态格式无效');
    }
    return PanelRuntime(
      key: value['key'] as String,
      name: value['name'] as String,
      suffix: value['suffix'] as String,
      status: value['status'] as String,
      version: value['version']?.toString() ?? '',
      detail: value['detail']?.toString() ?? '',
      installable: value['installable'] as bool,
      installError: value['install_error']?.toString() ?? '',
    );
  }
}

class PanelDependencyChecks {
  const PanelDependencyChecks({required this.time, required this.packages});

  final String time;
  final Map<String, String> packages;

  factory PanelDependencyChecks.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['packages'] is! Map) {
      throw const FormatException('核心依赖检测响应格式无效');
    }
    final rawPackages = value['packages'] as Map;
    if (rawPackages.length > 100 ||
        !rawPackages.keys.every((key) => key is String) ||
        !rawPackages.values.every((item) => item is String)) {
      throw const FormatException('核心依赖检测项目格式无效');
    }
    return PanelDependencyChecks(
      time: value['time']?.toString() ?? '',
      packages: Map<String, String>.unmodifiable(
        rawPackages.cast<String, String>(),
      ),
    );
  }
}

class PanelInstallJob {
  const PanelInstallJob({
    required this.id,
    required this.kind,
    required this.operation,
    required this.package,
    required this.status,
    required this.statusLabel,
    required this.running,
    required this.returnCode,
    required this.error,
    required this.log,
    required this.updatedAt,
    required this.retryConfirmationRequired,
    required this.retryAvailable,
    required this.recoveryAvailable,
    required this.cancelStatus,
    required this.cancelStatusLabel,
    required this.cancelError,
    required this.cancelRequestId,
    required this.retryOf,
    required this.retriedBy,
    required this.receiptPending,
  });

  final String id;
  final String kind;
  final String operation;
  final String package;
  final String status;
  final String statusLabel;
  final bool running;
  final int? returnCode;
  final String error;
  final String log;
  final String updatedAt;
  final bool retryConfirmationRequired;
  final bool retryAvailable;
  final bool recoveryAvailable;
  final String cancelStatus;
  final String cancelStatusLabel;
  final String cancelError;
  final String cancelRequestId;
  final String retryOf;
  final String retriedBy;
  final bool receiptPending;

  bool get canRetry =>
      !running &&
      !receiptPending &&
      !retryConfirmationRequired &&
      recoveryAvailable &&
      retryAvailable &&
      retriedBy.isEmpty &&
      const {'failed', 'unknown', 'cancelled', 'start_failed'}.contains(status);

  factory PanelInstallJob.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('安装作业响应格式无效');
    }
    final id =
        (value['install_id'] ?? value['id'] ?? value['request_id'])
            ?.toString() ??
        '';
    final kind = value['kind']?.toString() ?? 'dependency';
    final operation = value['operation']?.toString() ?? 'install';
    final status = value['status']?.toString() ?? 'unknown';
    final running =
        value['running'] == true ||
        const {'prepared', 'running'}.contains(status);
    final retryConfirmationRequired =
        value['retry_confirmation_required'] == true ||
        value['confirmation_required'] == true;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(id) ||
        !const {'dependency', 'runtime'}.contains(kind) ||
        !const {'install', 'uninstall'}.contains(operation) ||
        (kind == 'runtime' && operation != 'install') ||
        !const {
          'prepared',
          'running',
          'succeeded',
          'failed',
          'unknown',
          'cancelled',
          'missing',
          'start_failed',
          'unreadable',
          'original_running',
          'not_started',
        }.contains(status) ||
        (value['running'] != null && value['running'] is! bool) ||
        (value['returncode'] != null && value['returncode'] is! int)) {
      throw const FormatException('安装作业字段无效');
    }
    final log = value['log']?.toString() ?? '';
    if (log.length > 1024 * 1024) {
      throw const FormatException('安装日志超过大小限制');
    }
    return PanelInstallJob(
      id: id,
      kind: kind,
      operation: operation,
      package: value['package']?.toString() ?? '',
      status: status,
      statusLabel: value['status_label']?.toString() ?? status,
      running: running,
      returnCode: value['returncode'] as int?,
      error:
          (value['diagnostic'] ?? value['error'] ?? value['msg'])?.toString() ??
          '',
      log: log,
      updatedAt: value['updated_at']?.toString() ?? '',
      retryConfirmationRequired: retryConfirmationRequired,
      retryAvailable:
          value['retry_available'] == true ||
          (value['retry_available'] == null &&
              !running &&
              !retryConfirmationRequired &&
              const {
                'failed',
                'unknown',
                'cancelled',
                'start_failed',
              }.contains(status)),
      recoveryAvailable: value['recovery_available'] != false,
      cancelStatus: value['cancel_status']?.toString() ?? '',
      cancelStatusLabel: value['cancel_status_label']?.toString() ?? '',
      cancelError: value['cancel_error']?.toString() ?? '',
      cancelRequestId: value['cancel_request_id']?.toString() ?? '',
      retryOf: value['retry_of']?.toString() ?? '',
      retriedBy: value['retried_by']?.toString() ?? '',
      receiptPending: value['receipt_pending'] == true,
    );
  }
}

class PanelInstallHistory {
  const PanelInstallHistory(this.items);

  final List<PanelInstallJob> items;

  factory PanelInstallHistory.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        (value['items'] as List).length > 100) {
      throw const FormatException('安装历史响应格式无效');
    }
    return PanelInstallHistory(
      (value['items'] as List)
          .map(PanelInstallJob.fromJson)
          .toList(growable: false),
    );
  }
}

int _integer(Object? value) {
  if (value is int && value >= 0) return value;
  throw const FormatException('分页数字格式无效');
}
