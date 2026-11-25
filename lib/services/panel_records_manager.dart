import '../models/panel_records.dart';
import 'panel_api_client.dart';

class PanelRecordsManager {
  const PanelRecordsManager(this._api);

  final PanelApiClient _api;

  Future<PanelHistoryPage> fetchHistory({
    String query = '',
    String status = '',
    int page = 1,
    int limit = 30,
  }) async {
    if (query.length > 200 || page < 1 || limit < 1 || limit > 100) {
      throw ArgumentError('运行历史筛选或分页参数无效');
    }
    const path = '/api/history';
    final queryString = Uri(
      queryParameters: {
        'q': query,
        'status': status,
        'page': '$page',
        'limit': '$limit',
      },
    ).query;
    final payload = await _api.getJson('$path?$queryString');
    try {
      return PanelHistoryPage.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelLogFilePage> fetchLogFiles({
    String query = '',
    int page = 1,
    int limit = 30,
  }) async {
    if (query.length > 200 || page < 1 || limit < 1 || limit > 100) {
      throw ArgumentError('日志筛选或分页参数无效');
    }
    const path = '/api/logs';
    final queryString = Uri(
      queryParameters: {'q': query, 'page': '$page', 'limit': '$limit'},
    ).query;
    final payload = await _api.getJson('$path?$queryString');
    try {
      return PanelLogFilePage.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelLogFileContent> fetchLogFile(
    String filename, {
    int lines = 1500,
  }) async {
    if (filename.isEmpty ||
        filename.contains('/') ||
        filename.contains('\\') ||
        lines < 1 ||
        lines > 5000) {
      throw ArgumentError('日志文件或行数无效');
    }
    final path = '/api/logfile/${Uri.encodeComponent(filename)}';
    final query = Uri(queryParameters: {'lines': '$lines', 'format': 'json'});
    final payload = await _api.getJson('$path?${query.query}');
    try {
      return PanelLogFileContent.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<List<int>> downloadLogFile(String filename) {
    if (filename.isEmpty || filename.contains('/') || filename.contains('\\')) {
      throw ArgumentError('日志文件名无效');
    }
    final path = '/api/logfile/${Uri.encodeComponent(filename)}/download';
    return _api.getBytes(path);
  }

  Future<List<int>> exportHistory({String query = '', String status = ''}) {
    if (query.length > 200) throw ArgumentError('运行历史筛选参数无效');
    final queryString = Uri(
      queryParameters: {'q': query, 'status': status},
    ).query;
    return _api.getBytes('/api/history/export?$queryString');
  }

  static String csvFromHistory(Iterable<PanelHistoryItem> items) {
    const header = [
      '任务名',
      '任务 ID',
      '命令',
      '状态',
      '开始时间',
      '结束时间',
      '耗时（秒）',
      '退出码',
      '来源',
      '重试次数',
      '最大重试次数',
      '说明',
    ];
    final rows = <List<Object?>>[
      header,
      for (final item in items)
        [
          item.taskName,
          item.taskId,
          item.command,
          item.status,
          item.startAt,
          item.endAt,
          item.durationSeconds,
          item.returnCode ?? '',
          item.source,
          item.retryAttempt,
          item.maxRetries,
          item.message,
        ],
    ];
    return '\uFEFF${rows.map((row) => row.map(_csvCell).join(',')).join('\r\n')}\r\n';
  }

  static String _csvCell(Object? value) {
    var text = value?.toString() ?? '';
    if (text.isNotEmpty && RegExp(r'^\s*[=+\-@\t\r]').hasMatch(text)) {
      text = "'$text";
    }
    return '"${text.replaceAll('"', '""')}"';
  }
}
