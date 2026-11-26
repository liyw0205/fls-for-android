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
            includeDependencyDetails: false,
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

  Future<Object?> deleteJson(String path, Object? body) =>
      _sendJson('DELETE', path, body: body);

  Future<Object?> postMultipartFile(
    String path, {
    required String filePath,
    required String filename,
    required Map<String, String> fields,
    required void Function(int sentBytes, int totalBytes) onProgress,
    Duration? timeout,
  }) async {
    final uri = _apiUri(path);
    final multipart = http.MultipartRequest('POST', uri)
      ..fields.addAll(fields)
      ..files.add(
        await http.MultipartFile.fromPath('file', filePath, filename: filename),
      );
    final cookie = _sessionCookie;
    final csrf = _csrfToken;
    final headers = <String, String>{
      'Accept': 'application/json',
      'X-Requested-With': 'FLS-APP',
    };
    if (cookie != null) headers['Cookie'] = cookie;
    if (csrf != null) headers['X-CSRF-Token'] = csrf;
    multipart.headers.addAll(headers);
    final body = multipart.finalize();
    final totalBytes = multipart.contentLength;
    final request = http.StreamedRequest('POST', uri)
      ..contentLength = totalBytes
      ..headers.addAll(multipart.headers);
    final responseFuture = _client
        .send(request)
        .timeout(timeout ?? requestTimeout * 60);
    var sentBytes = 0;
    try {
      await for (final chunk in body) {
        request.sink.add(chunk);
        sentBytes += chunk.length;
        onProgress(sentBytes, totalBytes);
      }
      request.sink.close();
    } catch (_) {
      request.sink.close();
      rethrow;
    }

    try {
      final response = await responseFuture;
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
        final redactValues = [if (cookie != null) cookie.split('=').last];
        throw PanelApiException(
          _errorMessage(
            decoded,
            response.statusCode,
            redactValues,
            redactPanelPaths: true,
          ),
          statusCode: response.statusCode,
          path: uri.path,
          data: _errorMetadata(
            decoded,
            redactValues,
            includeTaskActionDetails: false,
            includeOnlineScriptDetails: false,
            includeScriptFileDetails: true,
            includeDependencyDetails: false,
          ),
        );
      }
      if (text.isEmpty) {
        throw PanelApiException(
          '面板返回空响应',
          statusCode: response.statusCode,
          path: uri.path,
        );
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
          if (Uri.parse(path).path.startsWith('/api/config/') && body is Map)
            ..._configRedactValues(body),
          if (Uri.parse(path).path.startsWith('/api/proxy/') && body is Map)
            ..._proxyRedactValues(body),
          if (Uri.parse(path).path.startsWith('/api/notify/') &&
              body is Map &&
              body['credentials'] is Map)
            for (final intent in (body['credentials'] as Map).values)
              if (intent is Map && intent['value'] is String)
                intent['value'] as String,
          if (uri.path.startsWith('/api/env/') && body is Map)
            for (final key in ['value', 'env_text'])
              if (body[key] is String) body[key] as String,
          if (cookie != null) cookie.split('=').last,
        ];
        throw PanelApiException(
          _errorMessage(
            decoded,
            response.statusCode,
            errorRedactValues,
            redactPanelPaths: _isSensitivePanelPath(Uri.parse(path).path),
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
            includeDependencyDetails: _isDependencyPath(Uri.parse(path).path),
            includeEnvironmentDetails: uri.path.startsWith('/api/env/'),
            includeConfigDetails: Uri.parse(
              path,
            ).path.startsWith('/api/config/'),
            includeProxyDetails: Uri.parse(path).path.startsWith('/api/proxy/'),
            includeNotifyDetails: Uri.parse(
              path,
            ).path.startsWith('/api/notify/'),
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

  List<String> _proxyRedactValues(Map body) {
    final credentials = body['credentials'];
    final settings = body['settings'];
    return [
      if (body['draft'] is Map) ..._proxyRedactValues(body['draft'] as Map),
      if (credentials is Map)
        for (final key in const ['username', 'password'])
          if (credentials[key] is String) credentials[key] as String,
      if (settings is Map && settings['url'] is String)
        settings['url'] as String,
    ];
  }

  List<String> _configRedactValues(Map body) {
    final values = <String>[];
    final credentials = body['credentials'];
    if (credentials is Map) {
      for (final key in const ['admin_token', 'totp_secret', 'totp_code']) {
        final value = credentials[key];
        if (value is String && value.isNotEmpty) values.add(value);
      }
    }
    final settings = body['settings'];
    if (settings is Map) {
      final source = settings['online_script_source'];
      if (source is String && source.isNotEmpty) values.add(source);
    }
    return values;
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
    required bool includeDependencyDetails,
    bool includeEnvironmentDetails = false,
    bool includeConfigDetails = false,
    bool includeProxyDetails = false,
    bool includeNotifyDetails = false,
  }) {
    if (payload is! Map<String, dynamic>) return null;
    if (includeProxyDetails || includeNotifyDetails) {
      final result = <String, dynamic>{
        for (final key in const [
          'resolved',
          'conflict',
          'confirm_required',
          'accepted',
        ])
          if (payload[key] is bool) key: payload[key],
        if (payload.containsKey('saved') &&
            (payload['saved'] == null || payload['saved'] is bool))
          'saved': payload['saved'],
        if (payload['request_id'] is String &&
            RegExp(r'^[a-f0-9]{32}$').hasMatch(payload['request_id'] as String))
          'request_id': payload['request_id'],
        if (payload['reference_count'] is int &&
            (payload['reference_count'] as int) >= 0)
          'reference_count': payload['reference_count'],
      };
      final references = payload['references'];
      if (references is List) {
        result['references'] = [
          for (final item in references.take(50))
            if (item is Map &&
                item['id'] is String &&
                (item['id'] as String).length <= 200 &&
                item['name'] is String &&
                (item['name'] as String).length <= 200)
              {
                'id': item['id'],
                'name': _redactText(item['name'] as String, redactValues),
              },
        ];
      }
      return result;
    }
    final metadata = <String, dynamic>{};
    final keys = <String>['saved', 'reload_required'];
    if (includeConfigDetails) {
      keys.addAll(const [
        'request_id',
        'conflict',
        'reauth_required',
        'apply_status',
        'state',
        'revision',
      ]);
    }
    if (includeEnvironmentDetails) {
      keys.addAll(const [
        'resolved',
        'request_id',
        'action',
        'conflict',
        'confirm_required',
        'changed_count',
        'skipped_count',
      ]);
    }
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
      keys.addAll(const ['code', 'msg', 'replayed']);
    }
    if (includeDependencyDetails) {
      keys.addAll(const [
        'ok',
        'request_id',
        'install_id',
        'original_id',
        'kind',
        'operation',
        'package',
        'retry_of',
        'retried_by',
        'status',
        'status_label',
        'running',
        'returncode',
        'error',
        'msg',
        'receipt_pending',
        'retry_confirmation_required',
        'retry_available',
        'recovery_available',
        'confirmation_required',
        'cancel_status',
        'cancel_status_label',
        'cancel_request_id',
        'cancel_error',
      ]);
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
            !const {
              'revision_conflict',
              'references_ack_required',
              'script_busy_or_recovery_required',
              'delete_result_unknown',
              'too_many_references',
              'not_file',
              'rename_revision_conflict',
              'rename_recovery_required',
              'rename_conflict',
              'rename_result_unknown',
              'operation_conflict',
              'rename_failed',
              'invalid_url',
              'invalid_request_id',
              'invalid_file_count',
              'invalid_fields',
              'missing_file',
              'upload_staging_failed',
              'worker_start_failed',
              'invalid_path',
              'invalid_parent',
              'invalid_proxy',
              'target_exists',
              'request_id_conflict',
              'too_many_active_jobs',
              'history_unavailable',
              'job_persistence_failed',
              'invalid_job_id',
              'not_found',
              'invalid_limit',
              'too_large',
              'path_changed',
              'download_failed',
              'worker_interrupted',
              'state_unknown',
              'not_cancellable',
            }.contains(value)) {
          continue;
        }
        if (includeDependencyDetails && value is String) {
          if (const {
                'request_id',
                'install_id',
                'original_id',
                'retry_of',
                'retried_by',
                'cancel_request_id',
              }.contains(key) &&
              !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(value)) {
            continue;
          }
          if (key == 'kind' &&
              !const {'dependency', 'runtime'}.contains(value)) {
            continue;
          }
          if (key == 'operation' &&
              !const {'install', 'uninstall'}.contains(value)) {
            continue;
          }
          if (key == 'status' &&
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
              }.contains(value)) {
            continue;
          }
          if (key == 'cancel_status' &&
              !const {
                '',
                'requested',
                'cancelled',
                'completed',
                'failed',
                'unknown',
              }.contains(value)) {
            continue;
          }
        }
        var safeValue = value;
        if (value is String &&
            const {
              'msg',
              'status',
              'phase',
              'error',
              'status_label',
              'cancel_status_label',
              'cancel_error',
              'package',
            }.contains(key)) {
          safeValue = _redactText(value, redactValues);
          if (includeOnlineScriptDetails && key == 'msg') {
            safeValue = _redactPanelPaths(safeValue as String);
          }
          if (includeDependencyDetails &&
              const {'msg', 'error', 'cancel_error'}.contains(key)) {
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
    if (includeScriptFileDetails) {
      final preview = payload['preview'];
      if (preview is Map<String, dynamic> &&
          _safeRenamePath(preview['source']) &&
          _safeRenamePath(preview['destination']) &&
          preview['revision'] is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(preview['revision'] as String)) {
        final references = preview['references'];
        if (references is List && references.length <= 200) {
          final safeReferences = <Map<String, dynamic>>[];
          var valid = true;
          for (final reference in references) {
            if (reference is! Map<String, dynamic> ||
                reference['id'] is! String ||
                reference['name'] is! String ||
                reference['manual'] is! bool ||
                !_safeRenameValues(reference['before']) ||
                !_safeRenameValues(reference['after'])) {
              valid = false;
              break;
            }
            safeReferences.add({
              'id': reference['id'],
              'name': _redactText(reference['name'] as String, redactValues),
              'manual': reference['manual'],
              'before': _safeRenameValueMap(
                reference['before'] as Map<String, dynamic>,
                redactValues,
              ),
              'after': _safeRenameValueMap(
                reference['after'] as Map<String, dynamic>,
                redactValues,
              ),
            });
          }
          if (valid) {
            metadata['preview'] = {
              'source': preview['source'],
              'destination': preview['destination'],
              'revision': preview['revision'],
              'references': List.unmodifiable(safeReferences),
            };
          }
        }
      }
      if (preview is Map<String, dynamic> &&
          _safeRenamePath(preview['path']) &&
          preview['kind'] == 'file' &&
          preview['revision'] is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(preview['revision'] as String) &&
          preview['size_bytes'] is num &&
          (preview['size_bytes'] as num) >= 0 &&
          preview['modified_at'] is String &&
          preview['references'] is List &&
          (preview['references'] as List).length <= 200) {
        final references = <Map<String, dynamic>>[];
        var valid = true;
        for (final reference in preview['references'] as List) {
          if (reference is! Map<String, dynamic> ||
              reference['task_id'] is! String ||
              (reference['task_id'] as String).length > 128 ||
              reference['task_name'] is! String ||
              (reference['task_name'] as String).length > 160 ||
              reference['fields'] is! List) {
            valid = false;
            break;
          }
          final fields = (reference['fields'] as List).cast<Object?>();
          if (fields.isEmpty ||
              fields.any(
                (field) =>
                    field is! String ||
                    !const {'command', 'config_path'}.contains(field),
              )) {
            valid = false;
            break;
          }
          references.add({
            'task_id': reference['task_id'],
            'task_name': _redactText(
              reference['task_name'] as String,
              redactValues,
            ),
            'fields': List<String>.unmodifiable(fields.cast<String>()),
          });
        }
        if (valid) {
          metadata['preview'] = {
            'path': preview['path'],
            'kind': 'file',
            'revision': preview['revision'],
            'size_bytes': preview['size_bytes'],
            'modified_at': preview['modified_at'],
            'references': List.unmodifiable(references),
          };
        }
      }
      final operation = payload['operation'];
      if (operation is Map<String, dynamic> &&
          operation['id'] is String &&
          RegExp(r'^[0-9a-f]{32}$').hasMatch(operation['id'] as String) &&
          _safeRenamePath(operation['source']) &&
          _safeRenamePath(operation['destination']) &&
          operation['status'] is String &&
          operation['finished'] is bool) {
        final actual = operation['actual'];
        if (actual is Map<String, dynamic> &&
            actual['source_exists'] is bool &&
            actual['destination_exists'] is bool &&
            actual['tasks'] is List &&
            (actual['tasks'] as List).length <= 200) {
          final safeTasks = <Map<String, String>>[];
          var valid = true;
          for (final task in actual['tasks'] as List) {
            if (task is! Map<String, dynamic> ||
                task['task_id'] is! String ||
                task['state'] is! String ||
                !const {
                  'missing',
                  'updated',
                  'unchanged',
                  'conflict',
                }.contains(task['state'])) {
              valid = false;
              break;
            }
            safeTasks.add({
              'task_id': task['task_id'] as String,
              'state': task['state'] as String,
            });
          }
          if (valid) {
            metadata['operation'] = {
              'id': operation['id'],
              'source': operation['source'],
              'destination': operation['destination'],
              'status': operation['status'],
              'finished': operation['finished'],
              'actual': {
                'source_exists': actual['source_exists'],
                'destination_exists': actual['destination_exists'],
                'tasks': List.unmodifiable(safeTasks),
              },
            };
          }
        }
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

  bool _isDependencyPath(String path) =>
      path.startsWith('/api/deps/') ||
      path.startsWith('/api/runtime/') ||
      path.startsWith('/api/install/runtime/');

  bool _isSensitivePanelPath(String path) =>
      _isOnlineScriptPath(path) ||
      _isScriptFilePath(path) ||
      _isDependencyPath(path) ||
      path.startsWith('/api/notify/');

  bool _isScriptFilePath(String path) =>
      path == '/api/scripts/file' ||
      path.startsWith('/api/scripts/pull') ||
      path.startsWith('/api/scripts/import') ||
      path.startsWith('/api/scripts/repo-pull') ||
      path.startsWith('/api/scripts/debug') ||
      path.startsWith('/api/scripts/rename') ||
      path.startsWith('/api/scripts/delete/');

  bool _safeRenamePath(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      !value.startsWith('/') &&
      !value.contains('\\') &&
      !value.contains('\u0000') &&
      value
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');

  bool _safeRenameValues(Object? value) =>
      value is Map<String, dynamic> &&
      value.length == 2 &&
      value['command'] is String &&
      value['config_path'] is String &&
      (value['command'] as String).length <= 64 * 1024 &&
      (value['config_path'] as String).length <= 4096;

  Map<String, String> _safeRenameValueMap(
    Map<String, dynamic> value,
    List<String> redactValues,
  ) => {
    'command': _redactPanelPaths(
      _redactText(value['command'] as String, redactValues),
    ),
    'config_path': _redactPanelPaths(
      _redactText(value['config_path'] as String, redactValues),
    ),
  };

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
