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

  Future<List<int>> getBytes(String path, {int? maxBytes}) async {
    final uri = _apiUri(path);
    final limit = maxBytes == null || maxBytes > maxResponseBytes
        ? maxResponseBytes
        : maxBytes;
    if (limit < 1) throw ArgumentError.value(maxBytes, 'maxBytes');
    final request = http.Request('GET', uri)
      ..headers.addAll({
        'Accept': 'text/csv, application/octet-stream, application/json',
        'X-Requested-With': 'FLS-APP',
      });
    final cookie = _sessionCookie;
    if (cookie != null) request.headers['Cookie'] = cookie;

    try {
      final response = await _client.send(request).timeout(requestTimeout);
      final newCookie = _sessionCookieFromHeader(
        response.headers['set-cookie'],
      );
      if (newCookie != null) _sessionCookie = newCookie;
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(requestTimeout)) {
        if (bytes.length + chunk.length > limit) {
          throw PanelApiException(
            '面板文件超过 ${limit ~/ (1024 * 1024)} MB 限制',
            statusCode: response.statusCode,
            path: uri.path,
          );
        }
        bytes.addAll(chunk);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = utf8.decode(bytes, allowMalformed: true).trim();
        final decoded = text.isEmpty
            ? null
            : _decodeJson(text, response.statusCode, uri.path);
        final redactValues = [if (cookie != null) cookie.split('=').last];
        throw PanelApiException(
          _errorMessage(
            decoded,
            response.statusCode,
            redactValues,
            redactPanelPaths: false,
          ),
          statusCode: response.statusCode,
          path: uri.path,
          data: _errorMetadata(
            decoded,
            redactValues,
            includeTaskActionDetails: false,
            includeOnlineScriptDetails: false,
            includeScriptFileDetails: false,
          ),
        );
      }
      return List<int>.unmodifiable(bytes);
    } on TimeoutException {
      throw PanelApiException('连接面板超时', path: uri.path);
    } on SocketException {
      throw PanelApiException('无法连接到面板，请检查地址和网络', path: uri.path);
    } on http.ClientException {
      throw PanelApiException('面板连接失败，请检查地址和网络', path: uri.path);
    }
  }

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
        final errorRedactValues = [
          ...redactValues,
          if (cookie != null) cookie.split('=').last,
        ];
        throw PanelApiException(
          _errorMessage(
            decoded,
            response.statusCode,
            errorRedactValues,
            redactPanelPaths:
                _isOnlineScriptPath(Uri.parse(path).path) ||
                _isScriptFilePath(Uri.parse(path).path),
          ),
          statusCode: response.statusCode,
          path: uri.path,
          data: _errorMetadata(
            decoded,
            errorRedactValues,
            includeTaskActionDetails: _isTaskActionPath(Uri.parse(path).path),
            includeOnlineScriptDetails: _isOnlineScriptPath(
              Uri.parse(path).path,
            ),
            includeScriptFileDetails: _isScriptFilePath(Uri.parse(path).path),
          ),
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
    List<String> redactValues, {
    required bool redactPanelPaths,
  }) {
    if (payload is Map<String, dynamic>) {
      final rawMessage =
          (payload['msg'] ?? payload['error'] ?? payload['message'])
              ?.toString()
              .trim();
      if (rawMessage != null && rawMessage.isNotEmpty) {
        var message = _redactText(rawMessage, redactValues);
        if (redactPanelPaths) message = _redactPanelPaths(message);
        return message;
      }
    }
    return switch (statusCode) {
      401 => '面板会话已过期或需要安全验证',
      403 => '面板拒绝了此请求，请检查账号权限',
      _ => '面板请求失败：HTTP $statusCode',
    };
  }

  Map<String, dynamic>? _errorMetadata(
    Object? payload,
    List<String> redactValues, {
    required bool includeTaskActionDetails,
    required bool includeOnlineScriptDetails,
    required bool includeScriptFileDetails,
  }) {
    if (payload is! Map<String, dynamic>) return null;
    final metadata = <String, dynamic>{};
    final keys = <String>['saved', 'reload_required'];
    if (includeTaskActionDetails) {
      keys.addAll(const [
        'action',
        'request_id',
        'msg',
        'count',
        'updated_count',
        'deleted_count',
        'submitted_count',
        'stopped_count',
        'failed_count',
        'skipped_count',
        'copied_count',
        'target_collection',
      ]);
    }
    if (includeOnlineScriptDetails) {
      keys.addAll(const [
        'confirm_required',
        'target_exists',
        'request_id',
        'install_id',
        'running',
        'accepted',
        'retry_allowed',
        'active',
        'receipt_missing',
        'receipt_confirmation_required',
        'scheduler_reload_required',
        'confirmation_stale',
        'cache_published',
        'replayed',
        'code',
        'state',
        'status',
        'phase',
        'msg',
      ]);
    }
    if (includeScriptFileDetails) {
      keys.addAll(const ['code', 'msg']);
    }
    for (final key in keys) {
      final value = payload[key];
      if (value is bool || value is String || value is num) {
        if (includeOnlineScriptDetails &&
            value is String &&
            const {'request_id', 'install_id'}.contains(key) &&
            !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(value)) {
          continue;
        }
        if (includeOnlineScriptDetails &&
            value is String &&
            key == 'state' &&
            !const {
              'prepared',
              'running',
              'failed',
              'unknown',
              'completed',
              'scheduler_pending',
            }.contains(value)) {
          continue;
        }
        if (includeOnlineScriptDetails &&
            value is String &&
            key == 'code' &&
            !const {
              'revision_conflict',
              'snapshot_changed',
              'offset_out_of_range',
            }.contains(value)) {
          continue;
        }
        if (includeScriptFileDetails &&
            value is String &&
            key == 'code' &&
            value != 'revision_conflict') {
          continue;
        }
        var safeValue = value;
        if (value is String && const {'msg', 'status', 'phase'}.contains(key)) {
          safeValue = _redactText(value, redactValues);
          if (includeOnlineScriptDetails && key == 'msg') {
            safeValue = _redactPanelPaths(safeValue as String);
          }
        }
        metadata[key] = safeValue;
      }
    }
    final expectedCollections = payload['expected_collections'];
    if (includeTaskActionDetails &&
        expectedCollections is Map &&
        expectedCollections.keys.every((key) => key is String) &&
        expectedCollections.values.every((value) => value is String)) {
      metadata['expected_collections'] = Map<String, String>.unmodifiable(
        expectedCollections.cast<String, String>(),
      );
    }
    final currentFile = payload['current'];
    if (includeScriptFileDetails &&
        currentFile is Map<String, dynamic> &&
        currentFile['path'] is String &&
        currentFile['name'] is String &&
        currentFile['content'] is String &&
        currentFile['revision'] is String &&
        utf8.encode(currentFile['content'] as String).length <=
            2 * 1024 * 1024 &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(currentFile['revision'] as String)) {
      final relativePath = currentFile['path'] as String;
      if (relativePath.isNotEmpty &&
          !relativePath.startsWith('/') &&
          !relativePath.contains('\\') &&
          !relativePath.contains('\u0000') &&
          relativePath.split('/').last == currentFile['name'] &&
          !relativePath
              .split('/')
              .any((part) => part == '.' || part == '..' || part.isEmpty)) {
        metadata['current'] = Map<String, dynamic>.unmodifiable({
          'path': relativePath,
          if (currentFile['name'] is String) 'name': currentFile['name'],
          'content': currentFile['content'],
          'revision': currentFile['revision'],
          if (currentFile['size_bytes'] is num)
            'size_bytes': currentFile['size_bytes'],
          if (currentFile['modified_at'] is String)
            'modified_at': currentFile['modified_at'],
        });
      }
    }
    for (final key
        in includeTaskActionDetails
            ? const [
                'completed_ids',
                'retry_ids',
                'unknown_ids',
                'created_ids',
                'stopped_ids',
                'missing_ids',
              ]
            : const <String>[]) {
      final value = payload[key];
      if (value is List && value.every((item) => item is String)) {
        metadata[key] = List<String>.unmodifiable(value.cast<String>());
      }
    }
    final results = payload['results'];
    if (includeTaskActionDetails &&
        results is List &&
        results.every((item) => item is Map)) {
      metadata['results'] = results
          .whereType<Map>()
          .map((item) {
            final row = Map<String, dynamic>.from(item);
            return Map<String, dynamic>.fromEntries(
              row.entries
                  .where(
                    (entry) =>
                        const {'task_id', 'status', 'msg'}.contains(entry.key),
                  )
                  .map(
                    (entry) => MapEntry(
                      entry.key,
                      entry.key == 'msg' && entry.value is String
                          ? _redactText(entry.value as String, redactValues)
                          : entry.value,
                    ),
                  ),
            );
          })
          .toList(growable: false);
    }
    return metadata.isEmpty ? null : metadata;
  }

  bool _isTaskActionPath(String path) =>
      path == '/api/task/bulk-action' ||
      path.startsWith('/api/task/action/') ||
      path.startsWith('/api/collection/add-task/');

  bool _isOnlineScriptPath(String path) =>
      path.startsWith('/api/online-scripts/');

  bool _isScriptFilePath(String path) => path == '/api/scripts/file';

  String _redactText(String text, List<String> values) {
    var result = text;
    for (final value in values.where((value) => value.isNotEmpty)) {
      result = result.replaceAll(value, '[已隐藏]');
    }
    result = result
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
    return result.length <= 500 ? result : '${result.substring(0, 500)}…';
  }

  String _redactPanelPaths(String text) => text
      .replaceAll(
        RegExp(r'/(?:data|home|srv|opt|var|tmp|root|storage|mnt)/[^\s,，。;；]+'),
        '[面板路径]',
      )
      .replaceAll(RegExp(r'[A-Za-z]:\\[^\s,，。;；]+'), '[面板路径]');

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
