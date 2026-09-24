import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fls_for_android/models/panel_server.dart';
import 'package:fls_for_android/services/operation_cancellation.dart';
import 'package:fls_for_android/services/remote_data_sync_manager.dart';

void main() {
  test('downloads a data-only backup using the WebView session', () async {
    final backupBytes = List<int>.generate(48, (index) => index);
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      expect(request.headers['cookie'], 'session=webview-session');
      switch ('${request.method} ${request.url.path}') {
        case 'GET /fls/backup':
          return http.Response(
            '<meta name="csrf-token" content="csrf-fixture">',
            200,
          );
        case 'POST /fls/api/backup/create':
          expect(request.headers['x-csrf-token'], 'csrf-fixture');
          expect(request.body, 'items=data');
          return http.Response(
            jsonEncode({'ok': true, 'job_id': 'job-1'}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        case 'GET /fls/api/backup/job/job-1':
          return http.Response(
            jsonEncode({
              'ok': true,
              'running': false,
              'status': '已完成',
              'filename': 'fls-backup-config-fixture.tar.gz',
              'size': backupBytes.length,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        case 'GET /fls/backup/download/fls-backup-config-fixture.tar.gz':
          return http.Response.bytes(backupBytes, 200);
      }
      return http.Response('unexpected request', 500);
    });
    final temporary = await Directory.systemTemp.createTemp(
      'fls-remote-data-sync-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final manager = RemoteDataSyncManager(
      client: client,
      cookieHeaderLoader: (_) async => 'session=webview-session',
    );
    addTearDown(manager.close);

    final progress = <int>[];
    final file = await manager.downloadDataArchive(
      server: const PanelServer(name: 'Home', url: 'https://example.test/fls'),
      destination: temporary,
      cancellation: OperationCancellation(),
      onStatus: (_) {},
      onProgress: (received, _) => progress.add(received),
    );

    expect(await file.readAsBytes(), backupBytes);
    expect(requests, [
      'GET /fls/backup',
      'POST /fls/api/backup/create',
      'GET /fls/api/backup/job/job-1',
      'GET /fls/backup/download/fls-backup-config-fixture.tar.gz',
    ]);
    expect(progress.last, backupBytes.length);
  });

  test('cancels while a remote response body is stalled', () async {
    final client = _StallingClient();
    addTearDown(client.close);
    final manager = RemoteDataSyncManager(
      client: client,
      cookieHeaderLoader: (_) async => 'session=webview-session',
    );
    addTearDown(manager.close);
    final temporary = await Directory.systemTemp.createTemp(
      'fls-remote-data-sync-cancel-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final cancellation = OperationCancellation();
    final operation = manager.downloadDataArchive(
      server: const PanelServer(name: 'Home', url: 'https://example.test'),
      destination: temporary,
      cancellation: cancellation,
      onStatus: (_) {},
      onProgress: (_, _) {},
    );

    await client.responseStarted.future;
    cancellation.cancel();

    await expectLater(operation, throwsA(isA<OperationCancelled>()));
  });
}

class _StallingClient extends http.BaseClient {
  final responseStarted = Completer<void>();
  final controller = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    responseStarted.complete();
    return http.StreamedResponse(controller.stream, 200);
  }

  @override
  void close() {
    controller.close();
  }
}
