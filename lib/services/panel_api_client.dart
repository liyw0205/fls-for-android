import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'panel_credential_store.dart';

class PanelApiException implements Exception {
  const PanelApiException(
    this.message, {
    this.statusCode,
    this.path,
    this.data,
  });

  final String message;
  final int? statusCode;
  final String? path;
  final Map<String, dynamic>? data;

  @override
  String toString() => message;
}

class PanelAuthenticationResult {
  const PanelAuthenticationResult({
    required this.authenticated,
    required this.requiresVerification,
    required this.verificationType,
  });

  final bool authenticated;
  final bool requiresVerification;
  final String? verificationType;
}

class PanelApiClient {
  PanelApiClient({
    required String baseUrl,
    PanelSessionCredentials? credentials,
    bool allowInsecureHttp = false,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
    this.maxResponseBytes = 8 * 1024 * 1024,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _baseUri = _parseBaseUrl(baseUrl),
       _sessionCookie = credentials?.cookie,
       _csrfToken = credentials?.csrfToken {
    if (_baseUri.scheme == 'http' && !allowInsecureHttp) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        '通过 HTTP 发送面板会话前需要明确确认网络可信',
      );
    }
  }

  final Uri _baseUri;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  final int maxResponseBytes;
  String? _sessionCookie;
  String? _csrfToken;

  bool get hasSession => _sessionCookie != null && _csrfToken != null;

  PanelSessionCredentials get sessionCredentials {
    final cookie = _sessionCookie;
    final csrf = _csrfToken;
    if (cookie == null || csrf == null) {
      throw StateError('面板会话尚未完成认证');
    }
    return PanelSessionCredentials(cookie: cookie, csrfToken: csrf);
  }

  Future<PanelAuthenticationResult> authenticate(
    String token, {
    bool remember = true,
  }) async {
    final inputToken = token.trim();
    if (inputToken.isEmpty || inputToken.length > 4096) {
      throw const PanelApiException('Token 无效');
    }
    _sessionCookie = null;
    _csrfToken = null;

    final payload = await _sendJson(
      'POST',
      '/api/auth/session',
      body: {'token': inputToken, 'remember': remember},
      sendCsrf: false,
      redactValues: [inputToken],
    );
    if (payload is! Map<String, dynamic> || payload['ok'] != true) {
      throw const PanelApiException('面板登录响应格式无效');
    }
    if (!hasSession) {
      throw const PanelApiException('面板未建立安全会话，请更新 FLS 面板后重试');
    }

    final requiresVerification = payload['requires_verification'] == true;
    final authenticated = payload['authenticated'] == true;
    if (!requiresVerification && !authenticated) {
      throw const PanelApiException('面板登录未完成');
    }
    return PanelAuthenticationResult(
      authenticated: authenticated,
      requiresVerification: requiresVerification,
      verificationType: payload['verification_type']?.toString(),
    );
  }

  Future<void> verifySecondFactor(String code) async {
    final payload = await postJson('/api/auth/verify', {'code': code.trim()});
    if (payload is! Map<String, dynamic> ||
        payload['ok'] != true ||
        payload['authenticated'] != true) {
      throw const PanelApiException('面板安全验证未完成');
    }
  }

  Future<void> resendVerificationCode() async {
    final payload = await postJson('/api/auth/resend-code', const {});
    if (payload is! Map<String, dynamic> || payload['ok'] != true) {
      throw const PanelApiException('验证码重发失败');
    }
  }

  Future<void> logout() async {
    try {
      if (hasSession) await postJson('/api/auth/logout', const {});
    } finally {
      _sessionCookie = null;
      _csrfToken = null;
    }
  }

  Future<Object?> getJson(String path) => _sendJson('GET', path);

  Future<Object?> postJson(String path, Object? body) =>
      _sendJson('POST', path, body: body);

  Future<Object?> putJson(String path, Object? body) =>
      _sendJson('PUT', path, body: body);

  Future<Object?> _sendJson(
    String method,
    String path, {
    Object? body,
    bool sendCsrf = true,
    List<String> redactValues = const [],
  }) async {
    final uri = _apiUri(path);
    final request = http.Request(method, uri)
      ..headers.addAll({
        'Accept': 'application/json',
        'X-Requested-With': 'FLS-APP',
      });
    final cookie = _sessionCookie;
    final csrf = _csrfToken;
    if (cookie != null) request.headers['Cookie'] = cookie;
    if (method != 'GET' && sendCsrf && csrf != null) {
      request.headers['X-CSRF-Token'] = csrf;
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }

    try {
      final response = await _client.send(request).timeout(requestTimeout);
      final newCookie = _sessionCookieFromHeader(
        response.headers['set-cookie'],
      );
      if (newCookie != null) _sessionCookie = newCookie;

      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(requestTimeout)) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw PanelApiException(
            '面板响应超过 ${maxResponseBytes ~/ (1024 * 1024)} MB 限制',
            statusCode: response.statusCode,
            path: uri.path,
          );
        }
        bytes.addAll(chunk);
      }

      final text = utf8.decode(bytes, allowMalformed: true).trim();
      final decoded = text.isEmpty
          ? null
          : _decodeJson(text, response.statusCode, uri.path);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PanelApiException(
          _errorMessage(decoded, response.statusCode, [
            ...redactValues,
            if (cookie != null) cookie.split('=').last,
          ]),
          statusCode: response.statusCode,
          path: uri.path,
          data: _errorMetadata(decoded),
        );
      }
      if (text.isEmpty && response.statusCode != 204) {
        throw PanelApiException(
          '面板返回空响应',
          statusCode: response.statusCode,
          path: uri.path,
        );
      }
      if (decoded is Map<String, dynamic> &&
          decoded['csrf_token'] is String &&
          (decoded['csrf_token'] as String).isNotEmpty) {
        _csrfToken = decoded['csrf_token'] as String;
      }
      return decoded;
    } on TimeoutException {
      throw PanelApiException('连接面板超时', path: uri.path);
    } on SocketException {
      throw PanelApiException('无法连接到面板，请检查地址和网络', path: uri.path);
    } on http.ClientException {
      throw PanelApiException('面板连接失败，请检查地址和网络', path: uri.path);
    }
  }

  String? _sessionCookieFromHeader(String? header) {
    if (header == null || header.isEmpty) return null;
    final pair = header.split(';').first.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]+=[^;\r\n]+$').hasMatch(pair)) return null;
    return pair;
  }

  Object? _decodeJson(String text, int statusCode, String path) {
    try {
      return jsonDecode(text);
    } on FormatException {
      if (statusCode < 200 || statusCode >= 300) return null;
      throw PanelApiException(
        '面板返回了无效 JSON',
        statusCode: statusCode,
        path: path,
      );
    }
  }

  String _errorMessage(
    Object? payload,
    int statusCode,
    List<String> redactValues,
  ) {
    if (payload is Map<String, dynamic>) {
      final rawMessage =
          (payload['msg'] ?? payload['error'] ?? payload['message'])
              ?.toString()
              .trim();
      if (rawMessage != null && rawMessage.isNotEmpty) {
        var message = rawMessage;
        for (final value in redactValues.where((value) => value.isNotEmpty)) {
          message = message.replaceAll(value, '[已隐藏]');
        }
        return message.length <= 500
            ? message
            : '${message.substring(0, 500)}…';
      }
    }
    return switch (statusCode) {
      401 => '面板会话已过期或需要安全验证',
      403 => '面板拒绝了此请求，请检查账号权限',
      _ => '面板请求失败：HTTP $statusCode',
    };
  }

  Map<String, dynamic>? _errorMetadata(Object? payload) {
    if (payload is! Map<String, dynamic>) return null;
    final metadata = <String, dynamic>{};
    for (final key in const ['saved', 'reload_required']) {
      final value = payload[key];
      if (value is bool) metadata[key] = value;
    }
    return metadata.isEmpty ? null : metadata;
  }

  Uri _apiUri(String path) {
    final relative = Uri.tryParse(path);
    if (relative == null ||
        relative.hasScheme ||
        relative.hasAuthority ||
        relative.hasFragment ||
        !relative.path.startsWith('/api/') ||
        relative.pathSegments.contains('..')) {
      throw ArgumentError.value(path, 'path', '只允许请求同一面板的 /api/ 接口');
    }
    final basePath = _baseUri.path.replaceFirst(RegExp(r'/+$'), '');
    return _baseUri.replace(
      path: '$basePath${relative.path}',
      query: relative.hasQuery ? relative.query : null,
      fragment: null,
    );
  }

  static Uri _parseBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError.value(value, 'baseUrl', '面板地址无效');
    }
    return uri;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
