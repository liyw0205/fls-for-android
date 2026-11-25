class PanelHistoryItem {
  const PanelHistoryItem({
    required this.id,
    required this.taskId,
    required this.taskName,
    required this.command,
    required this.status,
    required this.startAt,
    required this.endAt,
    required this.durationSeconds,
    required this.returnCode,
    required this.source,
    required this.retryAttempt,
    required this.maxRetries,
    required this.message,
  });

  final String id;
  final String taskId;
  final String taskName;
  final String command;
  final String status;
  final String startAt;
  final String endAt;
  final int durationSeconds;
  final int? returnCode;
  final String source;
  final int retryAttempt;
  final int maxRetries;
  final String message;

  factory PanelHistoryItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('运行历史记录格式无效');
    }
    final id = value['id']?.toString() ?? '';
    if (id.isEmpty) throw const FormatException('运行历史记录缺少 ID');
    return PanelHistoryItem(
      id: id,
      taskId: value['task_id']?.toString() ?? '',
      taskName: value['task_name']?.toString() ?? '',
      command: value['command']?.toString() ?? '',
      status: value['status']?.toString() ?? 'unknown',
      startAt: value['start_at']?.toString() ?? '',
      endAt: value['end_at']?.toString() ?? '',
      durationSeconds: _integer(value['duration_seconds']),
      returnCode: value['return_code'] == null
          ? null
          : _integer(value['return_code']),
      source: value['source']?.toString() ?? '',
      retryAttempt: _integer(value['retry_attempt']),
      maxRetries: _integer(value['max_retries']),
      message: value['message']?.toString() ?? '',
    );
  }
}

class PanelHistoryPage {
  const PanelHistoryPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelHistoryItem> items;
  final int page;
  final int pages;
  final int total;

  factory PanelHistoryPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('运行历史分页响应格式无效');
    }
    return PanelHistoryPage(
      items: (value['items'] as List)
          .map(PanelHistoryItem.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelLogFile {
  const PanelLogFile({
    required this.filename,
    required this.group,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String filename;
  final String group;
  final int sizeBytes;
  final String modifiedAt;

  factory PanelLogFile.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('日志文件记录格式无效');
    }
    final filename = value['filename']?.toString() ?? '';
    if (filename.isEmpty || filename.contains('/') || filename.contains('\\')) {
      throw const FormatException('日志文件名无效');
    }
    return PanelLogFile(
      filename: filename,
      group: value['group']?.toString() ?? '',
      sizeBytes: _integer(value['size_bytes']),
      modifiedAt: value['modified_at']?.toString() ?? '',
    );
  }
}

class PanelLogFilePage {
  const PanelLogFilePage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelLogFile> items;
  final int page;
  final int pages;
  final int total;

  factory PanelLogFilePage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('日志文件分页响应格式无效');
    }
    return PanelLogFilePage(
      items: (value['items'] as List)
          .map(PanelLogFile.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelLogFileContent {
  const PanelLogFileContent({
    required this.filename,
    required this.lines,
    required this.text,
  });

  final String filename;
  final int lines;
  final String text;

  factory PanelLogFileContent.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['filename'] is! String ||
        value['log'] is! String) {
      throw const FormatException('日志内容响应格式无效');
    }
    return PanelLogFileContent(
      filename: value['filename'] as String,
      lines: _integer(value['lines']),
      text: value['log'] as String,
    );
  }
}

int _integer(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};
