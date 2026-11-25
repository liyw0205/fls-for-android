import 'dart:math';

import '../models/panel_environment.dart';
import 'panel_api_client.dart';

class PanelRuntimeDepsManager {
  const PanelRuntimeDepsManager(this._api);

  final PanelApiClient _api;

  static String newRequestId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<PanelDependencyPage> fetchPackages({
    String query = '',
    int page = 1,
    int limit = 50,
  }) async {
    if (query.length > 200 || page < 1 || limit < 1 || limit > 100) {
      throw ArgumentError('依赖搜索或分页参数无效');
    }
    final params = Uri(
      queryParameters: {'q': query, 'page': '$page', 'limit': '$limit'},
    ).query;
    final path = '/api/deps/packages?$params';
    try {
      return PanelDependencyPage.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/deps/packages');
    }
  }

  Future<PanelDependencyChecks> refreshCoreDependencies() async {
    const path = '/api/deps/refresh';
    try {
      return PanelDependencyChecks.fromJson(
        await _api.postJson(path, const {}),
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<List<PanelRuntime>> fetchRuntimes() async {
    const path = '/api/runtime/status';
    final payload = await _api.getJson(path);
    if (payload is! Map<String, dynamic> ||
        payload['ok'] != true ||
        payload['items'] is! List ||
        (payload['items'] as List).length > 100) {
      throw const PanelApiException('运行时列表响应格式无效', path: path);
    }
    try {
      return (payload['items'] as List)
          .map(PanelRuntime.fromJson)
          .toList(growable: false);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelInstallJob> installDependency(
    String name, {
    required String requestId,
  }) => _start('/api/deps/install', {
    'name': _validatePackage(name),
    'request_id': _validateId(requestId),
  });

  Future<PanelInstallJob> uninstallDependency(
    String name, {
    required String requestId,
  }) => _start('/api/deps/uninstall', {
    'name': _validatePackage(name),
    'request_id': _validateId(requestId),
  });

  Future<PanelInstallJob> installRuntime(
    String runtime, {
    required String requestId,
  }) {
    if (!RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(runtime)) {
      throw ArgumentError.value(runtime, 'runtime');
    }
    return _start('/api/install/runtime/${Uri.encodeComponent(runtime)}', {
      'request_id': _validateId(requestId),
    });
  }

  Future<PanelInstallJob> fetchInstall(
    String installId, {
    int lines = 600,
  }) async {
    _validateId(installId);
    if (lines < 1 || lines > 1200) throw ArgumentError.value(lines, 'lines');
    final path = '/api/deps/install-log/${_segment(installId)}?lines=$lines';
    try {
      return PanelInstallJob.fromJson(await _api.getJson(path));
    } on PanelApiException catch (error) {
      final payload = error.data;
      if (error.statusCode == 503 && payload != null) {
        return PanelInstallJob.fromJson(payload);
      }
      rethrow;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/deps/install-log');
    }
  }

  Future<PanelInstallHistory> fetchHistory({
    int limit = 50,
    String kind = '',
  }) async {
    if (limit < 1 ||
        limit > 100 ||
        (kind.isNotEmpty && !const {'dependency', 'runtime'}.contains(kind))) {
      throw ArgumentError('安装历史筛选参数无效');
    }
    final params = Uri(
      queryParameters: {'limit': '$limit', 'kind': kind},
    ).query;
    const base = '/api/deps/install-history';
    try {
      return PanelInstallHistory.fromJson(await _api.getJson('$base?$params'));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: base);
    }
  }

  Future<PanelInstallJob> cancel(String installId, String requestId) async {
    await _writeJob('/api/deps/install-cancel/${_segment(installId)}', {
      'request_id': _validateId(requestId),
    });
    return fetchInstall(installId);
  }

  Future<PanelInstallJob> fetchCancelStatus(
    String installId,
    String requestId,
  ) => _readJob(
    '/api/deps/install-cancel/${_segment(installId)}/${_segment(requestId)}',
  );

  Future<PanelInstallJob> retry(String installId, String requestId) =>
      _writeJob('/api/deps/install-retry/${_segment(installId)}', {
        'request_id': _validateId(requestId),
      });

  Future<PanelInstallJob> fetchRetryStatus(
    String installId,
    String requestId,
  ) async {
    final path =
        '/api/deps/install-retry/${_segment(installId)}/${_segment(requestId)}';
    Object? payload;
    try {
      payload = await _api.getJson(path);
    } on PanelApiException catch (error) {
      payload = error.data;
      if (payload == null) rethrow;
    }
    if (payload is Map<String, dynamic> &&
        payload['install_id'] is! String &&
        payload['original_id'] == installId) {
      return fetchInstall(installId);
    }
    try {
      return PanelInstallJob.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelInstallJob> confirmRetrySafety(String installId) async {
    final id = _validateId(installId);
    await _writeJob('/api/deps/install-recovery-confirm/${_segment(id)}', {
      'request_id': id,
      'confirm_not_running': true,
    });
    return fetchInstall(id);
  }

  Future<PanelInstallJob> _start(String path, Map<String, Object?> body) =>
      _writeJob(path, body);

  Future<PanelInstallJob> _writeJob(
    String path,
    Map<String, Object?> body,
  ) async {
    try {
      return PanelInstallJob.fromJson(await _api.postJson(path, body));
    } on PanelApiException catch (error) {
      final payload = error.data;
      if (payload != null &&
          (payload['install_id'] is String || payload['status'] is String)) {
        return PanelInstallJob.fromJson(payload);
      }
      rethrow;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelInstallJob> _readJob(String path) async {
    try {
      return PanelInstallJob.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(
        error.message,
        path: path.split('/').take(4).join('/'),
      );
    }
  }

  static String _validatePackage(String value) {
    final name = value.trim();
    if (name.isEmpty ||
        name.length > 200 ||
        name.startsWith('-') ||
        name.codeUnits.any((unit) => unit < 32 || unit == 127)) {
      throw ArgumentError.value(value, 'name', '依赖包名无效');
    }
    return name;
  }

  static String _validateId(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(value)) {
      throw ArgumentError.value(value, 'requestId');
    }
    return value;
  }

  static String _segment(String value) =>
      Uri.encodeComponent(_validateId(value));
}
