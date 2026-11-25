import 'dart:convert';
import 'dart:io';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_script_import_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=import-session',
    csrfToken: 'import-csrf',
  );

  test('uploads multipart bytes with session and reports progress', () async {
    final temp = await Directory.systemTemp.createTemp('fls-import-test-');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}/bundle.zip');
    await source.writeAsBytes(utf8.encode('archive bytes'));
    final progress = <(int, int)>[];
    final api = PanelApiClient(
      baseUrl: 'https://panel.example/prefix',
      credentials: session,
      client: panelMockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/prefix/api/scripts/import');
        expect(request.headers['cookie'], session.cookie);
        expect(request.headers['x-csrf-token'], session.csrfToken);
        expect(
          request.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
        );
        final body = utf8.decode(request.bodyBytes);
        expect(body, contains('name="path"'));
        expect(body, contains('scripts/imported'));
        expect(body, contains('name="request_id"'));
        expect(body, contains('a' * 32));
        expect(body, contains('filename="bundle.zip"'));
        expect(body, contains('archive bytes'));
        return _jsonResponse({
          'ok': true,
          'job': _job(status: 'processing'),
        }, 202);
      }),
    );
    addTearDown(api.close);

    final manager = PanelScriptImportManager(api);
    final job = await manager.submit(
      filePath: source.path,
      filename: 'bundle.zip',
      path: 'scripts/imported',
      requestId: 'a' * 32,
      onProgress: (sent, total) => progress.add((sent, total)),
    );

    expect(job.kind, 'zip');
    expect(job.isActive, isTrue);
    expect(progress, isNotEmpty);
    expect(progress.last.$1, progress.last.$2);
  });

  test('fetches history, status, and cancellation using job ids', () async {
    final requests = <String>[];
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        requests.add(
          '${request.method} ${request.url.path}${request.url.hasQuery ? '?${request.url.query}' : ''}',
        );
        if (request.url.path.endsWith('/import-history')) {
          return _jsonResponse({
            'ok': true,
            'items': [_job()],
          });
        }
        if (request.url.path.endsWith('/import/${'b' * 32}/cancel')) {
          expect(request.headers['x-csrf-token'], session.csrfToken);
          return _jsonResponse({
            'ok': true,
            'job': _job(status: 'cancelling'),
          }, 202);
        }
        return _jsonResponse({'ok': true, 'job': _job()});
      }),
    );
    addTearDown(api.close);
    final manager = PanelScriptImportManager(api);

    final history = await manager.fetchHistory(limit: 8);
    final current = await manager.fetchJob('b' * 32);
    final cancelled = await manager.cancel('b' * 32);

    expect(history.items.single.kind, 'zip');
    expect(current.isComplete, isTrue);
    expect(cancelled.status, 'cancelling');
    expect(requests, [
      'GET /api/scripts/import-history?limit=8',
      'GET /api/scripts/import/${'b' * 32}',
      'POST /api/scripts/import/${'b' * 32}/cancel',
    ]);
  });

  test(
    'validates local target paths, request ids, and response progress',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient(
          (request) async => _jsonResponse({
            'ok': true,
            'job': {
              ..._job(),
              'progress': {
                ..._job()['progress'] as Map<String, dynamic>,
                'processed_bytes': -1,
              },
            },
          }),
        ),
      );
      addTearDown(api.close);
      final manager = PanelScriptImportManager(api);
      final temp = await Directory.systemTemp.createTemp('fls-import-invalid-');
      addTearDown(() => temp.delete(recursive: true));
      final source = File('${temp.path}/demo.py');
      await source.writeAsString('print(1)');

      await expectLater(
        manager.submit(
          filePath: source.path,
          filename: 'demo.py',
          path: '../escape.py',
          requestId: 'a' * 32,
          onProgress: (_, _) {},
        ),
        throwsArgumentError,
      );
      await expectLater(manager.fetchJob('../bad'), throwsArgumentError);
      await expectLater(
        manager.submit(
          filePath: source.path,
          filename: 'demo.py',
          path: 'demo.py',
          requestId: 'bad',
          onProgress: (_, _) {},
        ),
        throwsArgumentError,
      );
      await expectLater(
        manager.submit(
          filePath: source.path,
          filename: 'demo.py',
          path: 'demo.py',
          requestId: 'c' * 32,
          onProgress: (_, _) {},
        ),
        throwsA(isA<PanelApiException>()),
      );
    },
  );
}

Map<String, dynamic> _job({String status = 'complete'}) => {
  'id': 'b' * 32,
  'request_id': 'a' * 32,
  'kind': 'zip',
  'path': 'scripts/imported',
  'source_host': 'local-upload',
  'status': status,
  'progress': {
    'phase': status,
    'uploaded_bytes': 20,
    'processed_bytes': 13,
    'total_bytes': 20,
    'total_files': 1,
  },
  'error_code': '',
  'created_at': '2026-11-26 01:00:00',
  'updated_at': '2026-11-26 01:00:01',
  'replayed': false,
};

http.Response _jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);
