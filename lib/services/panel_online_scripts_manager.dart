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
