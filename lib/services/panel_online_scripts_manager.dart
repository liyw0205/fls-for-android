import 'dart:math';

import '../models/panel_online_script.dart';
import 'panel_api_client.dart';

class PanelOnlineScriptsManager {
  const PanelOnlineScriptsManager(this._api);

  final PanelApiClient _api;

  Future<PanelOnlineScriptPage> fetchCatalog({
    String query = '',
    int page = 1,
    int limit = 20,
  }) async {
    final path = _queryPath('/api/online-scripts/catalog', {
      'q': query,
      'page': '$page',
      'limit': '$limit',
    });
    final payload = await _api.getJson(path);
    try {
      return PanelOnlineScriptPage.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(
        error.message,
        path: '/api/online-scripts/catalog',
      );
    }
  }

  Future<Map<String, dynamic>> fetchSourceCache() async {
    const path = '/api/online-scripts/source';
    return _readMap(await _api.getJson(path), path);
  }

  Future<Map<String, dynamic>> saveSourceCache({
    required String jsonText,
    required String cacheRevision,
  }) => _put('/api/online-scripts/source', {
    'json_text': jsonText,
    'cache_revision': cacheRevision,
  });

  Future<Map<String, dynamic>> fetchRefreshOptions() async {
    const path = '/api/online-scripts/refresh-options';
    return _readMap(await _api.getJson(path), path);
  }

  Future<Map<String, dynamic>> startRefresh({
    required String requestId,
    String proxyId = '',
  }) => _write('/api/online-scripts/refresh', {
    'request_id': requestId,
    'proxy_id': proxyId,
  });

  Future<Map<String, dynamic>> fetchRefreshState(String requestId) async {
    final path = '/api/online-scripts/refresh-status/${_segment(requestId)}';
    return _readMap(await _api.getJson(path), path);
  }

  Future<Map<String, dynamic>> fetchRefreshHistory({
    int limit = 10,
    int offset = 0,
    String? snapshot,
  }) async {
    final query = <String, String>{'limit': '$limit', 'offset': '$offset'};
    if (snapshot != null) query['snapshot'] = snapshot;
    final path = _queryPath('/api/online-scripts/refresh-history', query);
    return _readMap(await _api.getJson(path), path);
  }

  Future<String> fetchRefreshLog(String requestId) async {
    final path = '/api/online-scripts/refresh-log/${_segment(requestId)}';
    final payload = _readMap(await _api.getJson(path), path, requireOk: false);
    final log = payload['log'];
    if (log is! String) throw PanelApiException('刷新日志响应格式无效', path: path);
    return sanitizeDiagnostic(log);
  }

  static String sanitizeDiagnostic(String value) => value
      .replaceAllMapped(
        RegExp(r'(https?://)[^/\s:@]+(?::[^/\s@]*)?@', caseSensitive: false),
        (match) => '${match[1]}[已隐藏]@',
      )
      .replaceAllMapped(
        RegExp(
          r'''(["']?(?:access[_-]?token|refresh[_-]?token|token|api[_-]?key|key|secret|password|passwd|pwd|cookie)["']\s*:\s*["']?)([^"'\s,}]+)(["']?)''',
          caseSensitive: false,
        ),
        (match) => '${match[1]}[已隐藏]${match[3]}',
      )
      .replaceAllMapped(
        RegExp(
          r'''([?&](?:access[_-]?token|refresh[_-]?token|token|api[_-]?key|key|secret|password|passwd|pwd|authorization|cookie)=)[^&#\s<>"']+''',
          caseSensitive: false,
        ),
        (match) => '${match[1]}[已隐藏]',
      )
      .replaceAllMapped(
        RegExp(
          r'(authorization\s*:\s*bearer\s+)[A-Za-z0-9._~+/=-]+',
          caseSensitive: false,
        ),
        (match) => '${match[1]}[已隐藏]',
      )
      .replaceAllMapped(
        RegExp(
          r'''((?:access[_-]?token|refresh[_-]?token|token|api[_-]?key|key|secret|password|passwd|pwd|cookie)\s*[:=]\s*)[^\s,;&<>"']+''',
          caseSensitive: false,
        ),
        (match) => '${match[1]}[已隐藏]',
      );

  Future<Map<String, dynamic>> fetchRefreshTaskLinkFailures(
    String requestId, {
    int limit = 100,
    int offset = 0,
  }) async {
    final path = _queryPath(
      '/api/online-scripts/refresh-task-link-failures/${_segment(requestId)}',
      {'limit': '$limit', 'offset': '$offset'},
    );
    return _readMap(await _api.getJson(path), path);
  }

  Future<Map<String, dynamic>> recoverRefresh(String requestId) =>
      _write('/api/online-scripts/refresh-recover/${_segment(requestId)}');

  Future<Map<String, dynamic>> confirmRefresh(String requestId) =>
      _write('/api/online-scripts/refresh-confirm/${_segment(requestId)}');

  Future<Map<String, dynamic>> retryRefresh({
    required String requestId,
    required String retryRequestId,
    String proxyId = '',
  }) => _write('/api/online-scripts/refresh-retry/${_segment(requestId)}', {
    'request_id': retryRequestId,
    'proxy_id': proxyId,
  });

  Future<Map<String, dynamic>> importTasks({
    required String scriptId,
    required String requestId,
    required List<int> taskIndexes,
    bool enableTasks = false,
  }) {
    if (taskIndexes.isEmpty) throw ArgumentError('请选择至少一个任务');
    return _write('/api/online-scripts/import-tasks/${_segment(scriptId)}', {
      'request_id': requestId,
      'task_indexes': taskIndexes.map((index) => '$index').toList(),
      'enable_task': enableTasks,
    });
  }

  Future<Map<String, dynamic>> fetchTaskImportState(String requestId) async {
    final path =
        '/api/online-scripts/import-tasks-status/${_segment(requestId)}';
    return _readMap(await _api.getJson(path), path);
  }

  Future<Map<String, dynamic>> fetchTaskImportHistory({
    int limit = 25,
    int offset = 0,
    bool recoveryOnly = false,
    String scriptId = '',
  }) async {
    final path = _queryPath('/api/online-scripts/import-tasks-history', {
      'limit': '$limit',
      'offset': '$offset',
      'recovery': recoveryOnly ? '1' : '0',
      'script_id': scriptId,
    });
    return _readMap(await _api.getJson(path), path);
  }

  Future<Map<String, dynamic>> confirmTaskImport(String requestId) =>
      _write('/api/online-scripts/import-tasks-confirm/${_segment(requestId)}');

  Future<Map<String, dynamic>> reloadTaskImportScheduler(String requestId) =>
      _write('/api/online-scripts/import-tasks-reload/${_segment(requestId)}');

  Future<Map<String, dynamic>> archiveTaskImport(String requestId) => _write(
    '/api/online-scripts/import-tasks-archive/${_segment(requestId)}',
    {'acknowledge': 'archive'},
  );

  Future<Map<String, dynamic>> linkTasks({
    required String scriptId,
    required String requestId,
    String proxyId = '',
    String refreshRequestId = '',
  }) {
    final path = refreshRequestId.isEmpty
        ? '/api/online-scripts/task-link/${_segment(scriptId)}'
        : '/api/online-scripts/refresh-task-link/${_segment(refreshRequestId)}/task-link/${_segment(scriptId)}';
    return _write(path, {'request_id': requestId, 'proxy_id': proxyId});
  }

  Future<Map<String, dynamic>> fetchTaskLinkState(String requestId) async {
    final path = '/api/online-scripts/task-link-status/${_segment(requestId)}';
    return _readMap(await _api.getJson(path), path);
  }

  Future<Map<String, dynamic>> fetchTaskLinkHistory({
    int limit = 25,
    int offset = 0,
    bool recoveryOnly = false,
    String scriptId = '',
  }) async {
    final path = _queryPath('/api/online-scripts/task-link-history', {
      'limit': '$limit',
      'offset': '$offset',
      'recovery': recoveryOnly ? '1' : '0',
      'script_id': scriptId,
    });
    return _readMap(await _api.getJson(path), path);
  }

  Future<Map<String, dynamic>> confirmTaskLink(String requestId) =>
      _write('/api/online-scripts/task-link-confirm/${_segment(requestId)}');

  Future<Map<String, dynamic>> archiveTaskLink(String requestId) => _write(
    '/api/online-scripts/task-link-archive/${_segment(requestId)}',
    {'acknowledge': 'archive'},
  );

  Future<PanelOnlineScript> fetchDetail(String scriptId) async {
    final path = '/api/online-scripts/detail/${_segment(scriptId)}';
    final payload = await _api.getJson(path);
    if (payload is! Map<String, dynamic> ||
        payload['ok'] != true ||
        payload['item'] is! Map<String, dynamic>) {
      throw PanelApiException('在线脚本详情响应格式无效', path: path);
    }
    try {
      return PanelOnlineScript.fromJson(payload['item']);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelOnlineScriptInstallOptions> fetchInstallOptions(
    String scriptId, {
    String query = '',
    int page = 1,
    int limit = 20,
  }) async {
    final path = _queryPath(
      '/api/online-scripts/install-options/${_segment(scriptId)}',
      {'q': query, 'page': '$page', 'limit': '$limit'},
    );
    final payload = await _api.getJson(path);
    try {
      return PanelOnlineScriptInstallOptions.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelOnlineScriptDocument> fetchDocument(
    String scriptId, {
    String proxyId = '',
  }) async {
    final path = _queryPath('/api/online-scripts/doc/${_segment(scriptId)}', {
      'proxy_id': proxyId,
    });
    final payload = await _api.getJson(path);
    try {
      return PanelOnlineScriptDocument.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<Map<String, dynamic>> startInstall({
    required String scriptId,
    required String requestId,
    String proxyId = '',
    bool importTasks = false,
    bool enableTasks = false,
    bool force = false,
    List<int> taskIndexes = const [],
  }) async {
    if (enableTasks && !importTasks) {
      throw ArgumentError('未启用任务导入时不能启用导入任务');
    }
    if (!importTasks && taskIndexes.isNotEmpty) {
      throw ArgumentError('未启用任务导入时不能选择任务');
    }
    final path = '/api/online-scripts/install/${_segment(scriptId)}';
    final payload = await _api.postJson(path, {
      'request_id': requestId,
      'proxy_id': proxyId,
      'import_task': importTasks,
      'enable_task': enableTasks,
      'force': force,
      'task_indexes': taskIndexes.map((index) => '$index').toList(),
    });
    return _writePayload(payload, path);
  }

  Future<PanelOnlineInstallState> fetchInstallState(
    String installId, {
    bool includeLog = false,
  }) async {
    final path = _queryPath(
      '/api/online-scripts/log/${_segment(installId)}',
      includeLog ? {'lines': '300'} : {'state_only': '1'},
    );
    final payload = await _api.getJson(path);
    try {
      return PanelOnlineInstallState.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<String> fetchInstallLog(String installId) async {
    final path = _queryPath('/api/online-scripts/log/${_segment(installId)}', {
      'lines': '300',
    });
    final payload = await _api.getJson(path);
    if (payload is! Map<String, dynamic> || payload['log'] is! String) {
      throw PanelApiException('安装日志响应格式无效', path: path);
    }
    return payload['log'] as String;
  }

  Future<PanelOnlineInstallHistoryPage> fetchInstallHistory({
    String scriptId = '',
    String status = '',
    int limit = 30,
    int offset = 0,
    String? snapshot,
  }) async {
    final parameters = <String, String>{
      'script_id': scriptId,
      'status': status,
      'limit': '$limit',
      'offset': '$offset',
    };
    if (snapshot != null) parameters['snapshot'] = snapshot;
    final path = _queryPath('/api/online-scripts/install-history', parameters);
    final payload = await _api.getJson(path);
    try {
      return PanelOnlineInstallHistoryPage.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<Map<String, dynamic>> stopInstall(String installId) =>
      _write('/api/online-scripts/install-stop/${_segment(installId)}');

  Future<Map<String, dynamic>> retryInstall(
    String installId, {
    bool force = false,
  }) => _write('/api/online-scripts/install-retry/${_segment(installId)}', {
    'force': force,
  });

  Future<Map<String, dynamic>> retryInstallStart(String installId) =>
      _write('/api/online-scripts/install-start-retry/${_segment(installId)}');

  Future<Map<String, dynamic>> confirmImportedTasks(String installId) =>
      _write('/api/online-scripts/install-task-confirm/${_segment(installId)}');

  Future<Map<String, dynamic>> retryImportedTasks(String installId) =>
      _write('/api/online-scripts/install-task-retry/${_segment(installId)}');

  Future<Map<String, dynamic>> reloadScheduler(String installId) =>
      _write('/api/online-scripts/install-reload/${_segment(installId)}');

  static String newRequestId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Map<String, dynamic>> _write(
    String path, [
    Map<String, Object?> body = const {},
  ]) async {
    final payload = await _api.postJson(path, body);
    return _writePayload(payload, path);
  }

  Future<Map<String, dynamic>> _put(
    String path,
    Map<String, Object?> body,
  ) async {
    final payload = await _api.putJson(path, body);
    return _writePayload(payload, path);
  }

  Map<String, dynamic> _readMap(
    Object? payload,
    String path, {
    bool requireOk = true,
  }) {
    if (payload is! Map<String, dynamic> ||
        (requireOk && payload['ok'] != true)) {
      throw PanelApiException('在线脚本响应格式无效', path: path);
    }
    return Map<String, dynamic>.unmodifiable(payload);
  }

  Map<String, dynamic> _writePayload(Object? payload, String path) {
    if (payload is! Map<String, dynamic>) {
      throw PanelApiException('在线脚本操作响应格式无效', path: path);
    }
    return Map<String, dynamic>.unmodifiable(payload);
  }

  String _segment(String value) {
    final input = value.trim();
    if (input.isEmpty ||
        input.length > 200 ||
        input.contains('/') ||
        input.contains('\\')) {
      throw ArgumentError.value(value, 'value', '在线脚本标识无效');
    }
    return Uri.encodeComponent(input);
  }

  String _queryPath(String path, Map<String, String> values) {
    final parameters = Map<String, String>.fromEntries(
      values.entries.where((entry) => entry.value.isNotEmpty),
    );
    if (parameters.isEmpty) return path;
    return '$path?${Uri(queryParameters: parameters).query}';
  }
}
