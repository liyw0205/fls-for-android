import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';

import '../models/panel_server.dart';
import 'operation_cancellation.dart';

typedef CookieHeaderLoader = Future<String> Function(Uri serverUri);

class RemoteDataSyncException implements Exception {
  const RemoteDataSyncException(this.message, {this.requiresLogin = false});

  final String message;
  final bool requiresLogin;

  @override
  String toString() => message;
}

class RemoteDataSyncManager {
  RemoteDataSyncManager({http.Client? client, this.cookieHeaderLoader})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final CookieHeaderLoader? cookieHeaderLoader;
  final bool _ownsClient;
  String? _csrfToken;
  String? _activeJobId;

  Future<File> downloadDataArchive({
    required PanelServer server,
    required Directory destination,
    required OperationCancellation cancellation,
    required ValueChanged<String> onStatus,
    required void Function(int received, int total) onProgress,
  }) async {
    final serverUri = Uri.parse(server.url);
    final cookieHeader = await _loadCookieHeader(serverUri);
    if (cookieHeader.isEmpty) {
      throw const RemoteDataSyncException(
        '请先登录此远程 FLS 面板，再重试同步。',
        requiresLogin: true,
      );
    }
    try {
      onStatus('检查远程面板登录状态');
      final csrf = await _loadCsrfToken(serverUri, cookieHeader, cancellation);
      _csrfToken = csrf;

      onStatus('请求服务器打包 data');
      final createResponse = await _sendCancellable(
        'POST',
        _endpoint(serverUri, 'api/backup/create'),
        cancellation,
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
          'Cookie': cookieHeader,
          'X-CSRF-Token': csrf,
        },
        body: 'items=data',
      );
      final createData = await _readJson(createResponse, cancellation);
      if (createData['ok'] != true || createData['job_id'] is! String) {
        throw RemoteDataSyncException(
          createData['msg']?.toString() ?? '远程服务器无法创建 data 备份',
        );
      }
      final jobId = createData['job_id'] as String;
      _activeJobId = jobId;

      onStatus('等待服务器完成 data 打包');
      final job = await _waitForBackup(
        serverUri,
        cookieHeader,
        jobId,
        cancellation,
        onStatus,
      );
      final filename = job['filename']?.toString() ?? '';
      final totalBytes = job['size'] is num ? (job['size'] as num).toInt() : 0;
      if (filename.isEmpty || p.basename(filename) != filename) {
        throw const FormatException('远程备份文件名无效');
      }

      await destination.create(recursive: true);
      final archive = File(
        p.join(
          destination.path,
          '.remote-data-${DateTime.now().millisecondsSinceEpoch}.tar.gz',
        ),
      );
      try {
        onStatus('下载服务器 data');
        await _downloadArchive(
          serverUri,
          cookieHeader,
          filename,
          archive,
          totalBytes,
          cancellation,
          onProgress,
        );
        return archive;
      } catch (_) {
        if (await archive.exists()) await archive.delete();
        rethrow;
      }
    } catch (_) {
      final jobId = _activeJobId;
      if (jobId != null) {
        await _cancelRemoteJob(serverUri, cookieHeader, jobId);
      }
      rethrow;
    } finally {
      _activeJobId = null;
      _csrfToken = null;
    }
  }

  Future<String> _loadCookieHeader(Uri serverUri) async {
    final injectedLoader = cookieHeaderLoader;
    if (injectedLoader != null) return injectedLoader(serverUri);
    final cookies = await WebViewCookieManager().getCookies(domain: serverUri);
    return cookies
        .where((cookie) => cookie.name.isNotEmpty)
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  Future<String> _loadCsrfToken(
    Uri serverUri,
    String cookieHeader,
    OperationCancellation cancellation,
  ) async {
    final response = await _sendCancellable(
      'GET',
      _endpoint(serverUri, 'backup'),
      cancellation,
      headers: {'Accept': 'text/html', 'Cookie': cookieHeader},
    );
    if (response.statusCode != HttpStatus.ok) {
      await _discardBody(response);
      _throwForStatus(response.statusCode);
    }
    final html = await _readText(response, cancellation);
    final match = RegExp(
      r'''<meta\s+name=["']csrf-token["']\s+content=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (match == null) {
      throw const RemoteDataSyncException(
        '远程面板未返回安全令牌，请先登录远程面板后重试。',
        requiresLogin: true,
      );
    }
    return match.group(1)!;
  }

  Future<Map<String, dynamic>> _waitForBackup(
    Uri serverUri,
    String cookieHeader,
    String jobId,
    OperationCancellation cancellation,
    ValueChanged<String> onStatus,
  ) async {
    for (var attempt = 0; attempt < 900; attempt++) {
      cancellation.throwIfCancelled();
      final response = await _sendCancellable(
        'GET',
        _endpoint(serverUri, 'api/backup/job/${Uri.encodeComponent(jobId)}'),
        cancellation,
        headers: {'Accept': 'application/json', 'Cookie': cookieHeader},
      );
      final job = await _readJson(response, cancellation);
      if (job['ok'] != true) {
        throw RemoteDataSyncException(job['msg']?.toString() ?? '读取远程备份任务失败');
      }
      if (job['running'] != true) {
        if (job['status'] != '已完成') {
          throw RemoteDataSyncException(
            job['error']?.toString().trim().isNotEmpty == true
                ? job['error'].toString()
                : '远程 data 备份${job['status'] ?? '失败'}',
          );
        }
        return job;
      }
      onStatus(job['status']?.toString() ?? '正在打包');
      await cancellation.delay(const Duration(seconds: 1));
    }
    throw const RemoteDataSyncException('等待远程 data 打包超时');
  }

  Future<void> _downloadArchive(
    Uri serverUri,
    String cookieHeader,
    String filename,
    File destination,
    int totalBytes,
    OperationCancellation cancellation,
    void Function(int received, int total) onProgress,
  ) async {
    final response = await _sendCancellable(
      'GET',
      _endpoint(serverUri, 'backup/download/${Uri.encodeComponent(filename)}'),
      cancellation,
      headers: {'Cookie': cookieHeader},
    );
    if (response.statusCode != HttpStatus.ok) {
      await _discardBody(response);
      _throwForStatus(response.statusCode);
    }

    final sink = destination.openWrite();
    final iterator = StreamIterator<List<int>>(response.stream);
    var received = 0;
    var reported = 0;
    try {
      while (await _moveNext(iterator, cancellation)) {
        final chunk = iterator.current;
        sink.add(chunk);
        received += chunk.length;
        if (received - reported >= 256 * 1024 || received == totalBytes) {
          reported = received;
          onProgress(received, totalBytes);
        }
      }
      await sink.flush();
    } catch (_) {
      cancellation.throwIfCancelled();
      rethrow;
    } finally {
      await iterator.cancel();
      await sink.close();
    }
    cancellation.throwIfCancelled();
    if (received == 0 || (totalBytes > 0 && received != totalBytes)) {
      throw const RemoteDataSyncException('服务器 data 备份下载不完整');
    }
    onProgress(received, totalBytes > 0 ? totalBytes : received);
  }

  Future<Map<String, dynamic>> _readJson(
    http.StreamedResponse response,
    OperationCancellation cancellation,
  ) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _discardBody(response);
      _throwForStatus(response.statusCode);
    }
    final body = await _readText(response, cancellation);
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('远程 FLS 返回了无效响应');
    }
    return value;
  }

  Future<void> _discardBody(http.StreamedResponse response) async {
    final iterator = StreamIterator<List<int>>(response.stream);
    await iterator.cancel();
  }

  Future<String> _readText(
    http.StreamedResponse response,
    OperationCancellation cancellation,
  ) async {
    final iterator = StreamIterator<List<int>>(response.stream);
    final bytes = BytesBuilder(copy: false);
    try {
      while (await _moveNext(iterator, cancellation)) {
        bytes.add(iterator.current);
        if (bytes.length > 8 * 1024 * 1024) {
          throw const RemoteDataSyncException('远程 FLS 响应过大');
        }
      }
      return utf8.decode(bytes.takeBytes());
    } catch (_) {
      cancellation.throwIfCancelled();
      rethrow;
    } finally {
      await iterator.cancel();
    }
  }

  Future<bool> _moveNext(
    StreamIterator<List<int>> iterator,
    OperationCancellation cancellation,
  ) {
    cancellation.throwIfCancelled();
    return Future.any([
      iterator.moveNext().timeout(
        const Duration(seconds: 60),
        onTimeout: () =>
            throw const RemoteDataSyncException('远程 FLS 响应长时间无数据，请检查网络后重试。'),
      ),
      cancellation.whenCancelled.then<bool>(
        (_) => throw const OperationCancelled(),
      ),
    ]);
  }

  Future<http.StreamedResponse> _sendCancellable(
    String method,
    Uri uri,
    OperationCancellation cancellation, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    cancellation.throwIfCancelled();
    final abortTrigger = Completer<void>();
    cancellation.whenCancelled.then((_) {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
    });
    final request =
        http.AbortableRequest(method, uri, abortTrigger: abortTrigger.future)
          ..followRedirects = false
          ..headers.addAll(headers);
    if (body != null) request.body = body;
    try {
      return await _client
          .send(request)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              if (!abortTrigger.isCompleted) abortTrigger.complete();
              throw const RemoteDataSyncException('远程 FLS 连接超时，请检查网络后重试。');
            },
          );
    } catch (_) {
      cancellation.throwIfCancelled();
      rethrow;
    }
  }

  Future<void> _cancelRemoteJob(
    Uri serverUri,
    String cookieHeader,
    String jobId,
  ) async {
    final csrf = _csrfToken;
    if (csrf == null) return;
    final request =
        http.Request(
            'POST',
            _endpoint(
              serverUri,
              'api/backup/cancel/${Uri.encodeComponent(jobId)}',
            ),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Accept': 'application/json',
            'Cookie': cookieHeader,
            'X-CSRF-Token': csrf,
          });
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 3));
      await _discardBody(response);
    } catch (_) {}
  }

  Uri _endpoint(Uri base, String relativePath) {
    final prefix = base.path.replaceFirst(RegExp(r'/+$'), '');
    return base.replace(
      path: '$prefix/$relativePath',
      query: null,
      fragment: null,
    );
  }

  Never _throwForStatus(int statusCode) {
    if (statusCode == HttpStatus.unauthorized ||
        statusCode == HttpStatus.forbidden ||
        (statusCode >= 300 && statusCode < 400)) {
      throw const RemoteDataSyncException(
        '远程登录已失效，请登录远程 FLS 后重试。',
        requiresLogin: true,
      );
    }
    throw RemoteDataSyncException('远程 FLS 请求失败：HTTP $statusCode');
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
