class PanelOnlineScript {
  const PanelOnlineScript({
    required this.id,
    required this.name,
    required this.type,
    required this.sourceName,
    required this.sourceUrl,
    required this.docUrl,
    required this.description,
    required this.version,
    required this.author,
    required this.category,
    required this.tags,
    required this.hasInstall,
    required this.hasDoc,
    required this.hasTasks,
    required this.taskCount,
  });

  final String id;
  final String name;
  final String type;
  final String sourceName;
  final String sourceUrl;
  final String docUrl;
  final String description;
  final String version;
  final String author;
  final String category;
  final List<String> tags;
  final bool hasInstall;
  final bool hasDoc;
  final bool hasTasks;
  final int taskCount;

  factory PanelOnlineScript.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('在线脚本数据格式无效');
    }
    final id = value['id']?.toString().trim() ?? '';
    final name = value['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('在线脚本缺少标识或名称');
    }
    final rawTags = value['tags'];
    return PanelOnlineScript(
      id: id,
      name: name,
      type: value['type']?.toString() ?? 'unknown',
      sourceName: value['link_name']?.toString() ?? '',
      sourceUrl: value['source_url']?.toString() ?? '',
      docUrl: value['doc_url']?.toString() ?? '',
      description: value['description']?.toString() ?? '',
      version: value['version']?.toString() ?? '',
      author: value['author']?.toString() ?? '',
      category: value['category']?.toString() ?? '',
      tags: rawTags is List
          ? rawTags.map((tag) => tag.toString()).toList(growable: false)
          : const [],
      hasInstall: value['has_install'] == true,
      hasDoc: value['has_doc'] == true,
      hasTasks: value['has_tasks'] == true,
      taskCount: _integer(value['task_count']),
    );
  }
}

class PanelOnlineScriptPage {
  const PanelOnlineScriptPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelOnlineScript> items;
  final int page;
  final int pages;
  final int total;

  factory PanelOnlineScriptPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('在线脚本目录响应格式无效');
    }
    return PanelOnlineScriptPage(
      items: (value['items'] as List)
          .map(PanelOnlineScript.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelOnlineScriptTask {
  const PanelOnlineScriptTask({
    required this.index,
    required this.name,
    required this.cron,
    required this.command,
    required this.remark,
    required this.configPath,
    required this.enabled,
    required this.variableNames,
    required this.sensitiveVariables,
    required this.valid,
    required this.validationError,
  });

  final int index;
  final String name;
  final String cron;
  final String command;
  final String remark;
  final String configPath;
  final bool enabled;
  final List<String> variableNames;
  final List<String> sensitiveVariables;
  final bool valid;
  final String validationError;

  factory PanelOnlineScriptTask.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('在线脚本任务选项格式无效');
    }
    return PanelOnlineScriptTask(
      index: _integer(value['index']),
      name: value['name']?.toString() ?? '',
      cron: value['cron']?.toString() ?? '',
      command: value['command']?.toString() ?? '',
      remark: value['remark']?.toString() ?? '',
      configPath: value['config_path']?.toString() ?? '',
      enabled: value['enabled'] == true,
      variableNames: _strings(value['variable_names']),
      sensitiveVariables: _strings(value['sensitive_variables']),
      valid: value['valid'] == true,
      validationError: value['validation_error']?.toString() ?? '',
    );
  }
}

class PanelOnlineScriptProxy {
  const PanelOnlineScriptProxy({
    required this.id,
    required this.name,
    required this.type,
  });

  final String id;
  final String name;
  final String type;

  factory PanelOnlineScriptProxy.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('代理选项格式无效');
    }
    final id = value['id']?.toString() ?? '';
    if (id.isEmpty) throw const FormatException('代理选项缺少标识');
    return PanelOnlineScriptProxy(
      id: id,
      name: value['name']?.toString() ?? '',
      type: value['type']?.toString() ?? '',
    );
  }
}

class PanelOnlineScriptInstallOptions {
  const PanelOnlineScriptInstallOptions({
    required this.scriptId,
    required this.tasks,
    required this.proxies,
    required this.page,
    required this.pages,
    required this.total,
  });

  final String scriptId;
  final List<PanelOnlineScriptTask> tasks;
  final List<PanelOnlineScriptProxy> proxies;
  final int page;
  final int pages;
  final int total;

  factory PanelOnlineScriptInstallOptions.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        value['proxies'] is! List) {
      throw const FormatException('安装选项响应格式无效');
    }
    return PanelOnlineScriptInstallOptions(
      scriptId: value['script_id']?.toString() ?? '',
      tasks: (value['items'] as List)
          .map(PanelOnlineScriptTask.fromJson)
          .toList(growable: false),
      proxies: (value['proxies'] as List)
          .map(PanelOnlineScriptProxy.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelOnlineScriptDocument {
  const PanelOnlineScriptDocument({
    required this.format,
    required this.content,
    required this.sourceUrl,
    required this.sizeBytes,
  });

  final String format;
  final String content;
  final String sourceUrl;
  final int sizeBytes;

  factory PanelOnlineScriptDocument.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['format'] is! String ||
        value['content'] is! String) {
      throw const FormatException('在线脚本文档响应格式无效');
    }
    return PanelOnlineScriptDocument(
      format: value['format'] as String,
      content: value['content'] as String,
      sourceUrl: value['source_url']?.toString() ?? '',
      sizeBytes: _integer(value['size_bytes']),
    );
  }
}

class PanelOnlineInstallState {
  const PanelOnlineInstallState({
    required this.installId,
    required this.running,
    required this.status,
    required this.phase,
    required this.error,
    required this.log,
    required this.downloadKind,
    required this.downloadState,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.percent,
    required this.schedulerReloadPending,
    required this.confirmTasksAvailable,
    required this.retryTasksAvailable,
    required this.reloadSchedulerAvailable,
    required this.retryAvailable,
    required this.startRetryAvailable,
  });

  final String installId;
  final bool running;
  final String status;
  final String phase;
  final String error;
  final String log;
  final String downloadKind;
  final String downloadState;
  final int? downloadedBytes;
  final int? totalBytes;
  final int? percent;
  final bool schedulerReloadPending;
  final bool confirmTasksAvailable;
  final bool retryTasksAvailable;
  final bool reloadSchedulerAvailable;
  final bool retryAvailable;
  final bool startRetryAvailable;

  factory PanelOnlineInstallState.fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['ok'] != true) {
      throw const FormatException('安装状态响应格式无效');
    }
    final installId = value['install_id']?.toString() ?? '';
    if (installId.isEmpty) throw const FormatException('安装状态缺少任务标识');
    final progress = value['download_progress'];
    final recovery = value['recovery'];
    final download = progress is Map<String, dynamic> ? progress : const {};
    final recoveryInfo = recovery is Map<String, dynamic>
        ? recovery
        : const <String, dynamic>{};
    final apiAction = recoveryInfo['api_action']?.toString() ?? '';
    bool actionIs(String action) => apiAction.endsWith('/$action/$installId');
    return PanelOnlineInstallState(
      installId: installId,
      running: value['running'] == true,
      status: value['status']?.toString() ?? '未知',
      phase: value['phase']?.toString() ?? 'unknown',
      error: (value['install_error'] ?? value['error'])?.toString() ?? '',
      log: value['log']?.toString() ?? '',
      downloadKind: download['kind']?.toString() ?? 'unknown',
      downloadState: download['state']?.toString() ?? 'unknown',
      downloadedBytes: _nullableInteger(download['downloaded_bytes']),
      totalBytes: _nullableInteger(download['total_bytes']),
      percent: _percentage(download['percent']),
      schedulerReloadPending: value['scheduler_reload_pending'] == true,
      confirmTasksAvailable: actionIs('install-task-confirm'),
      retryTasksAvailable: actionIs('install-task-retry'),
      reloadSchedulerAvailable: actionIs('install-reload'),
      retryAvailable: actionIs('install-retry'),
      startRetryAvailable: actionIs('install-start-retry'),
    );
  }
}

class PanelOnlineInstallHistoryItem {
  const PanelOnlineInstallHistoryItem({
    required this.installId,
    required this.scriptId,
    required this.scriptName,
    required this.status,
    required this.running,
    required this.startedAt,
  });

  final String installId;
  final String scriptId;
  final String scriptName;
  final String status;
  final bool running;
  final String startedAt;

  factory PanelOnlineInstallHistoryItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('安装历史记录格式无效');
    }
    final installId = value['id']?.toString() ?? '';
    if (installId.isEmpty) throw const FormatException('安装历史记录缺少标识');
    return PanelOnlineInstallHistoryItem(
      installId: installId,
      scriptId: value['script_id']?.toString() ?? '',
      scriptName: value['script_name']?.toString() ?? '',
      status: value['status']?.toString() ?? '未知',
      running: value['running'] == true,
      startedAt: value['start_time']?.toString() ?? '',
    );
  }
}

class PanelOnlineInstallHistoryPage {
  const PanelOnlineInstallHistoryPage({
    required this.items,
    required this.total,
    required this.offset,
    required this.limit,
    required this.hasMore,
    required this.snapshot,
  });

  final List<PanelOnlineInstallHistoryItem> items;
  final int total;
  final int offset;
  final int limit;
  final bool hasMore;
  final String snapshot;

  factory PanelOnlineInstallHistoryPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        value['snapshot'] is! String) {
      throw const FormatException('安装历史分页响应格式无效');
    }
    return PanelOnlineInstallHistoryPage(
      items: (value['items'] as List)
          .map(PanelOnlineInstallHistoryItem.fromJson)
          .toList(growable: false),
      total: _integer(value['total']),
      offset: _integer(value['offset']),
      limit: _integer(value['limit']),
      hasMore: value['has_more'] == true,
      snapshot: value['snapshot'] as String,
    );
  }
}

List<String> _strings(Object? value) => value is List
    ? value.map((item) => item.toString()).toList(growable: false)
    : const [];

int _integer(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

int? _nullableInteger(Object? value) {
  final parsed = switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text),
    _ => null,
  };
  return parsed != null && parsed >= 0 ? parsed : null;
}

int? _percentage(Object? value) {
  final parsed = _nullableInteger(value);
  return parsed != null && parsed <= 100 ? parsed : null;
}
