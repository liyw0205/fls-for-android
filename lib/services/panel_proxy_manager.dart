import 'dart:math';

import '../models/panel_proxy.dart';
import '../models/panel_proxy_check.dart';
import 'panel_api_client.dart';

class PanelProxyManager {
  const PanelProxyManager(this._api);
  final PanelApiClient _api;

  static String newRequestId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  Future<T> _decode<T>(
    String path,
    Future<Object?> Function() request,
    T Function(Object?) parse,
  ) async {
    try {
      return parse(await request());
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelProxyPage> fetchPage({
    String query = '',
    String type = '',
    bool? enabled,
    int page = 1,
  }) {
    final path = Uri(
      path: '/api/proxy/settings',
      queryParameters: {
        'q': query,
        'type': type,
        'enabled': enabled == null
            ? ''
            : enabled
            ? '1'
            : '0',
        'page': '$page',
        'limit': '50',
      },
    ).toString();
    return _decode(path, () => _api.getJson(path), PanelProxyPage.fromJson);
  }

  Future<PanelProxy> fetch(String id) {
    final path = '/api/proxy/settings/${Uri.encodeComponent(id)}';
    return _decode(path, () => _api.getJson(path), (value) {
      if (value is! Map<String, dynamic> || value['ok'] != true) {
        throw const FormatException('代理详情响应格式无效');
      }
      final proxy = PanelProxy.fromJson(value['proxy']);
      if (proxy.id != id) throw const FormatException('代理详情标识不匹配');
      return proxy;
    });
  }

  Future<PanelProxyResult> submit(Map<String, Object?> body) {
    final id = body['request_id'];
    _validateId(id);
    if (!const ['new', 'edit', 'toggle', 'delete'].contains(body['action'])) {
      throw ArgumentError('代理操作无效');
    }
    if (body['action'] != 'new' &&
        (body['version'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(body['version'] as String))) {
      throw ArgumentError('代理版本无效');
    }
    const path = '/api/proxy/settings';
    return _decode(
      path,
      () => _api.postJson(path, body),
      (value) => PanelProxyResult.fromJson(value, expectedId: id as String),
    );
  }

  Future<PanelProxyResult> status(String requestId) {
    _validateId(requestId);
    final path = '/api/proxy/requests/$requestId';
    return _decode(
      path,
      () => _api.getJson(path),
      (value) =>
          PanelProxyResult.fromJson(value, expectedId: requestId, query: true),
    );
  }

  Future<PanelProxyCheck> startCheck(Map<String, Object?> body) {
    _validateId(body['request_id']);
    const path = '/api/proxy/checks';
    return _decode(
      path,
      () => _api.postJson(path, body),
      (value) => _check(value, body['request_id'] as String),
    );
  }

  Future<PanelProxyCheck> check(String id) {
    if (!validProxyCheckId(id)) throw ArgumentError('检测标识无效');
    final path = '/api/proxy/checks/$id';
    return _decode(
      path,
      () => _api.getJson(path),
      (value) => _check(value, id),
    );
  }

  Future<PanelProxyCheck> retryCheck(
    String oldId, {
    required String requestId,
    required String version,
  }) {
    if (!validProxyCheckId(oldId)) throw ArgumentError('检测标识无效');
    _validateId(requestId);
    final path = '/api/proxy/checks/$oldId/retry';
    return _decode(
      path,
      () => _api.postJson(path, {'request_id': requestId, 'version': version}),
      (value) => _check(value, requestId),
    );
  }

  Future<PanelProxyCheckPage> checkHistory({
    int page = 1,
    String proxyId = '',
    String kind = '',
    String status = '',
  }) {
    final path = Uri(
      path: '/api/proxy/checks',
      queryParameters: {
        'page': '$page',
        'limit': '25',
        'proxy_id': proxyId,
        'kind': kind,
        'status': status,
      },
    ).toString();
    return _decode(
      path,
      () => _api.getJson(path),
      PanelProxyCheckPage.fromJson,
    );
  }

  PanelProxyCheck _check(Object? value, String id) {
    if (value is! Map<String, dynamic> || value['ok'] != true) {
      throw const FormatException('代理检测响应无效');
    }
    final check = PanelProxyCheck.fromJson(value['check']);
    if (check.id != id) throw const FormatException('代理检测标识不匹配');
    return check;
  }

  void _validateId(Object? id) {
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw ArgumentError('代理提交标识无效');
    }
  }
}
