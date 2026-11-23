import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import '../models/panel_server.dart';

typedef OnlineScriptsCookieLoader = Future<String> Function(Uri serverUri);
typedef OnlineScriptsStatusCallback = void Function(String status);
typedef OnlineScriptsLogCallback = void Function(String log);

class OnlineScript {
  const OnlineScript({
    required this.id,
    required this.name,
    required this.type,
    required this.link,
    required this.linkName,
    required this.installCommand,
    this.docLink,
  });

  final String id;
  final String name;
  final String type;
  final Uri link;
  final String linkName;
  final String installCommand;
  final Uri? docLink;

  factory OnlineScript.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    final type = json['type']?.toString().trim() ?? '';
    final link = _httpsUri(json['link']);
    final docLink = _httpsUri(json['doc_link'], required: false);
    if (!RegExp(r'^[A-Za-z0-9._-]{1,120}$').hasMatch(id) ||
        name.isEmpty ||
        !{'raw', 'repo'}.contains(type) ||
        link == null ||
        (json['doc_link'] != null && docLink == null)) {
      throw const FormatException('在线脚本条目无效');
    }
    return OnlineScript(
      id: id,
      name: name,
      type: type,
      link: link,
      linkName: json['link_name']?.toString().trim().isNotEmpty == true
          ? json['link_name'].toString().trim()
          : name,
      installCommand: json['install']?.toString() ?? '',
      docLink: docLink,
    );
  }

  static Uri? _httpsUri(Object? value, {bool required = true}) {
    if (value == null && !required) return null;
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }
}

class OnlineScriptInstallStatus {
  const OnlineScriptInstallStatus({
    required this.installId,
    required this.running,
    required this.status,
    required this.log,
    this.error = '',
  });

  final String installId;
  final bool running;
  final String status;
  final String log;
  final String error;

  factory OnlineScriptInstallStatus.fromJson(Map<String, dynamic> json) {
    final installId = json['install_id']?.toString() ?? '';
    if (installId.isEmpty || json['running'] is! bool) {
      throw const FormatException('在线脚本安装状态无效');
    }
    return OnlineScriptInstallStatus(
      installId: installId,
      running: json['running'] as bool,
      status: json['status']?.toString() ?? '状态未知',
      log: json['log']?.toString() ?? '',
      error: (json['install_error'] ?? json['error'])?.toString() ?? '',
    );
  }
}

class OnlineScriptInstallConfirmation implements Exception {
  const OnlineScriptInstallConfirmation(this.message);

  final String message;

  @override
  String toString() => message;
}

class OnlineScriptsManager {
  OnlineScriptsManager({
    http.Client? client,
    this.cookieLoader,
    Uri? catalogUri,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       catalogUri = catalogUri ?? defaultCatalogUri;

  static final Uri defaultCatalogUri = Uri.parse(
    'https://cdn.jsdelivr.net/gh/liyw0205/fls-scripts@main/index.json',
  );

  final http.Client _client;
  final OnlineScriptsCookieLoader? cookieLoader;
  final Uri catalogUri;
  final bool _ownsClient;

  Future<List<OnlineScript>> fetchCatalog() async {
    final body = await _fetchText(
      catalogUri,
      headers: const {'Accept': 'application/json'},
      maximumBytes: 5 * 1024 * 1024,
      errorLabel: '在线脚本目录',
    );
    final value = jsonDecode(body);
    if (value is! List) throw const FormatException('在线脚本目录格式无效');
    final items = <OnlineScript>[];
    final ids = <String>{};
    for (final item in value) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final script = OnlineScript.fromJson(item);
        if (ids.add(script.id)) items.add(script);
      } on FormatException {
        continue;
      }
    }
    return items;
  }

  Future<String> fetchDocument(OnlineScript script) async {
    final uri = script.docLink;
    if (uri == null) return '';
    return _fetchText(
      uri,
      headers: const {'Accept': 'text/plain, text/markdown, */*'},
      maximumBytes: 1024 * 1024,
      errorLabel: '脚本文档',
    );
  }

  Future<String> _fetchText(
    Uri uri, {
    required Map<String, String> headers,
    required int maximumBytes,
    required String errorLabel,
  }) async {
    final request = http.Request('GET', uri)..headers.addAll(headers);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw StateError('读取$errorLabel失败：HTTP ${response.statusCode}');
    }
    if ((response.contentLength ?? 0) > maximumBytes) {
      await response.stream.drain<void>();
      throw FormatException(
        '$errorLabel超过 ${maximumBytes ~/ (1024 * 1024)} MB',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw FormatException(
          '$errorLabel超过 ${maximumBytes ~/ (1024 * 1024)} MB',
        );
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Future<String> _cookieHeader(Uri serverUri) async {
    final loader = cookieLoader;
    if (loader != null) return loader(serverUri);
    final cookies = await WebViewCookieManager().getCookies(domain: serverUri);
    return cookies
        .where((cookie) => cookie.name.isNotEmpty)
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  Future<String> _csrfToken(Uri serverUri, String cookieHeader) async {
    final response = await _client
        .get(
          _endpoint(serverUri, 'online-scripts'),
          headers: {'Accept': 'text/html', 'Cookie': cookieHeader},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 401 ||
        response.statusCode == 403 ||
        (response.statusCode >= 300 && response.statusCode < 400)) {
      throw StateError('本机面板登录已失效，请先打开本机面板并登录。');
    }
    if (response.statusCode != 200) {
      throw StateError('读取本机面板安全令牌失败：HTTP ${response.statusCode}');
    }
    final match = RegExp(
      r'''<meta\s+name=["']csrf-token["']\s+content=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(response.body);
    if (match == null) throw StateError('本机面板未返回安全令牌，请重新登录。');
    return match.group(1)!;
  }

  Future<String> installOrUpdate({
    required PanelServer server,
    required OnlineScript script,
    required OnlineScriptsStatusCallback onStatus,
    OnlineScriptsLogCallback? onLog,
    bool overwriteExisting = false,
  }) async {
    final serverUri = Uri.parse(server.url);
    final cookieHeader = await _cookieHeader(serverUri);
    if (cookieHeader.isEmpty) {
      throw StateError('请先打开本机面板并登录，再安装在线脚本。');
    }
    final csrf = await _csrfToken(serverUri, cookieHeader);
    await _refreshSource(serverUri, cookieHeader, csrf, onStatus);

    final requestId = _requestId();
    final response = await _client
        .post(
          _endpoint(
            serverUri,
            'api/online-scripts/install/${Uri.encodeComponent(script.id)}',
          ),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Cookie': cookieHeader,
            'X-CSRF-Token': csrf,
          },
          body: jsonEncode({
            'request_id': requestId,
            'import_task': false,
            'enable_task': false,
            'force': overwriteExisting,
          }),
        )
        .timeout(const Duration(seconds: 30));
    final payload = _jsonMap(response.body);
    if (response.statusCode == 409 && payload['confirm_required'] == true) {
      throw OnlineScriptInstallConfirmation(
        payload['msg']?.toString() ?? '目标脚本已存在，确认后会覆盖并更新。',
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw StateError('本机面板登录已失效，请重新登录后重试。');
    }
    final installId = (payload['install_id'] ?? payload['request_id'])
        ?.toString();
    if ((response.statusCode < 200 || response.statusCode >= 300) ||
        payload['ok'] != true ||
        installId == null ||
        installId.isEmpty) {
      throw StateError(payload['msg']?.toString() ?? '本机面板未接受安装请求');
    }

    onStatus('安装任务已受理');
    for (var attempt = 0; attempt < 1860; attempt++) {
      final statusResponse = await _client
          .get(
            _endpoint(
              serverUri,
              'api/online-scripts/log/${Uri.encodeComponent(installId)}',
            ).replace(queryParameters: const {'lines': '300'}),
            headers: {'Accept': 'application/json', 'Cookie': cookieHeader},
          )
          .timeout(const Duration(seconds: 30));
      if (statusResponse.statusCode == 401 ||
          statusResponse.statusCode == 403) {
        throw StateError('查询安装状态时登录已失效。');
      }
      final state = _jsonMap(statusResponse.body);
      if (statusResponse.statusCode >= 400 && state['ok'] != true) {
        throw StateError(state['error']?.toString() ?? '读取在线脚本安装状态失败');
      }
      final current = OnlineScriptInstallStatus.fromJson(state);
      onStatus(current.status);
      onLog?.call(current.log);
      if (!current.running) {
        if (current.error.isNotEmpty || current.status != '已完成') {
          throw StateError(
            current.error.isNotEmpty
                ? current.error
                : '在线脚本安装${current.status}',
          );
        }
        return installId;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw StateError('在线脚本安装仍在后台运行，稍后可在本机面板日志中查看。');
  }

  Future<void> _refreshSource(
    Uri serverUri,
    String cookieHeader,
    String csrf,
    OnlineScriptsStatusCallback onStatus,
  ) async {
    final requestId = _requestId();
    onStatus('同步本机在线脚本目录');
    final response = await _client
        .post(
          _endpoint(serverUri, 'api/online-scripts/refresh'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Cookie': cookieHeader,
            'X-CSRF-Token': csrf,
          },
          body: jsonEncode({'request_id': requestId, 'proxy_id': ''}),
        )
        .timeout(const Duration(seconds: 30));
    final payload = _jsonMap(response.body);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw StateError('同步脚本目录时本机面板登录已失效。');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        payload['ok'] != true) {
      throw StateError(payload['error']?.toString() ?? '本机在线脚本目录同步未启动');
    }
    for (var attempt = 0; attempt < 300; attempt++) {
      final statusResponse = await _client
          .get(
            _endpoint(
              serverUri,
              'api/online-scripts/refresh-status/${Uri.encodeComponent(requestId)}',
            ),
            headers: {'Accept': 'application/json', 'Cookie': cookieHeader},
          )
          .timeout(const Duration(seconds: 30));
      final state = _jsonMap(statusResponse.body);
      if (statusResponse.statusCode >= 400 || state['ok'] == false) {
        throw StateError(state['error']?.toString() ?? '读取脚本目录同步状态失败');
      }
      final running = state['running'] == true;
      final status = state['status']?.toString() ?? '同步中';
      onStatus(status);
      if (!running) {
        if (status != '已完成' && status != '部分完成') {
          throw StateError(
            state['error']?.toString().trim().isNotEmpty == true
                ? state['error'].toString()
                : '本机在线脚本目录同步$status',
          );
        }
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw StateError('同步本机在线脚本目录超时');
  }

  String _requestId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  Map<String, dynamic> _jsonMap(String body) {
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('本机 FLS 返回了无效 JSON');
    }
    return value;
  }

  Uri _endpoint(Uri base, String relativePath) {
    final prefix = base.path.replaceFirst(RegExp(r'/+$'), '');
    return base.replace(
      path: '$prefix/$relativePath',
      query: null,
      fragment: null,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
