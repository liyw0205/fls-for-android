import 'dart:convert';
import 'dart:io';

import 'panel_test_http.dart';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('streams a download to disk and reports byte progress', () async {
    final directory = await Directory.systemTemp.createTemp('fls-download-');
    addTearDown(() => directory.delete(recursive: true));
    final destination = '${directory.path}/backup.tar.gz';
    late http.BaseRequest captured;
    final progress = <(int, int?)>[];
    final client = PanelApiClient(
      baseUrl: 'https://fls.example/panel',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=stream-session',
        csrfToken: 'csrf-token',
      ),
      client: _StreamingClient((request) async {
        captured = request;
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            utf8.encode('archive-'),
            utf8.encode('bytes'),
          ]),
          200,
          contentLength: 13,
        );
      }),
    );
    addTearDown(client.close);

    final received = await client.downloadFile(
      '/api/backup/native/files/archive.tar.gz/download?version=${'a' * 64}',
      destinationPath: destination,
      onProgress: (bytes, total) => progress.add((bytes, total)),
    );

    expect(received, 13);
    expect(await File(destination).readAsString(), 'archive-bytes');
    expect(progress.first, (0, 13));
    expect(progress.last, (13, 13));
    expect(
      captured.url.path,
      '/panel/api/backup/native/files/archive.tar.gz/download',
    );
    expect(captured.url.queryParameters['version'], 'a' * 64);
    expect(captured.headers['cookie'], 'fls_native_session=stream-session');
    expect(captured.headers['x-csrf-token'], isNull);
  });

  test('removes a partial download after a length mismatch', () async {
    final directory = await Directory.systemTemp.createTemp('fls-download-');
    addTearDown(() => directory.delete(recursive: true));
    final destination = '${directory.path}/partial.tar.gz';
    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      client: _StreamingClient(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('short')),
          200,
          contentLength: 10,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.downloadFile(
        '/api/backup/native/files/partial.tar.gz/download?version=${'b' * 64}',
        destinationPath: destination,
        onProgress: (_, _) {},
      ),
      throwsA(isA<PanelApiException>()),
    );
    expect(await File(destination).exists(), isFalse);
  });

  test('submits the admin token once, then uses the session cookie', () async {
    final requests = <http.Request>[];
    final client = PanelApiClient(
      baseUrl: 'https://fls.example/panel',
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/panel/api/auth/session') {
          return utf8Response(
            '{"ok":true,"authenticated":true,"requires_verification":false,"csrf_token":"csrf-1"}',
            200,
            headers: {
              'set-cookie':
                  'fls_native_session=opaque-session; HttpOnly; Path=/',
            },
          );
        }
        return utf8Response('[{"id":"1","name":"Daily"}]', 200);
      }),
    );
    addTearDown(client.close);

    final auth = await client.authenticate('secret-token');
    final result = await client.getJson('/api/status?fresh=1');

    expect(auth.authenticated, isTrue);
    expect(auth.requiresVerification, isFalse);
    expect(requests.first.headers['x-token'], isNull);
    expect(jsonDecode(requests.first.body), {
      'token': 'secret-token',
      'remember': true,
    });
    expect(
      requests.last.url.toString(),
      'https://fls.example/panel/api/status?fresh=1',
    );
    expect(
      requests.last.headers['cookie'],
      'fls_native_session=opaque-session',
    );
    expect(requests.last.headers['x-token'], isNull);
    expect(result, [
      <String, dynamic>{'id': '1', 'name': 'Daily'},
    ]);
    expect(
      client.sessionCredentials.cookie,
      'fls_native_session=opaque-session',
    );
    expect(client.sessionCredentials.csrfToken, 'csrf-1');
  });

  test(
    'keeps pending sessions in memory until the second factor succeeds',
    () async {
      final requests = <http.Request>[];
      final client = PanelApiClient(
        baseUrl: 'https://fls.example',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/session')) {
            return utf8Response(
              '{"ok":true,"authenticated":false,"requires_verification":true,"verification_type":"totp","csrf_token":"csrf-pending"}',
              202,
              headers: {'set-cookie': 'fls_native_session=pending; HttpOnly'},
            );
          }
          return utf8Response(
            '{"ok":true,"authenticated":true,"csrf_token":"csrf-ready"}',
            200,
          );
        }),
      );
      addTearDown(client.close);

      final auth = await client.authenticate('admin-token');
      expect(auth.requiresVerification, isTrue);
      expect(client.sessionCredentials.csrfToken, 'csrf-pending');

      await client.verifySecondFactor('123456');

      expect(requests.last.url.path, '/api/auth/verify');
      expect(requests.last.headers['cookie'], 'fls_native_session=pending');
      expect(requests.last.headers['x-csrf-token'], 'csrf-pending');
      expect(requests.last.body, '{"code":"123456"}');
      expect(client.sessionCredentials.csrfToken, 'csrf-ready');
    },
  );

  test('protects writes with session cookie and CSRF token', () async {
    late http.Request captured;
    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=signed-cookie',
        csrfToken: 'csrf-token',
      ),
      client: MockClient((request) async {
        captured = request;
        return utf8Response('{"ok":true}', 200);
      }),
    );
    addTearDown(client.close);

    await client.postJson('/api/task/action/run/1', {'request_id': 'r1'});

    expect(captured.method, 'POST');
    expect(captured.headers['cookie'], 'fls_native_session=signed-cookie');
    expect(captured.headers['x-csrf-token'], 'csrf-token');
    expect(captured.headers['x-token'], isNull);
    expect(captured.headers['content-type'], contains('application/json'));
    expect(jsonDecode(captured.body), {'request_id': 'r1'});
  });

  test('rejects paths that could send session credentials elsewhere', () {
    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=signed-cookie',
        csrfToken: 'csrf-token',
      ),
      client: MockClient((_) async => utf8Response('{}', 200)),
    );
    addTearDown(client.close);

    expect(
      client.getJson('https://other.example/api/status'),
      throwsArgumentError,
    );
    expect(client.getJson('/dashboard'), throwsArgumentError);
    expect(client.getJson('/api/../login'), throwsArgumentError);
  });

  test('requires explicit consent before sending a session over HTTP', () {
    expect(
      () => PanelApiClient(baseUrl: 'http://192.168.1.2:5700'),
      throwsArgumentError,
    );
    expect(
      () => PanelApiClient(
        baseUrl: 'http://192.168.1.2:5700',
        allowInsecureHttp: true,
      ),
      returnsNormally,
    );
  });

  test('redacts the transient admin token from login errors', () async {
    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      client: MockClient(
        (_) async => utf8Response(
          jsonEncode({'ok': false, 'msg': 'Rejected secret-token'}),
          403,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.authenticate('secret-token'),
      throwsA(
        isA<PanelApiException>()
            .having((error) => error.statusCode, 'statusCode', 403)
            .having((error) => error.message, 'message', 'Rejected [已隐藏]'),
      ),
    );
  });

  test('keeps only safe recovery flags from an API error response', () async {
    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=signed-cookie',
        csrfToken: 'csrf-token',
      ),
      client: MockClient(
        (_) async => utf8Response(
          '{"ok":false,"saved":true,"reload_required":true,"secret":"do-not-retain","msg":"任务已保存"}',
          503,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.postJson('/api/tasks', const {}),
      throwsA(
        isA<PanelApiException>()
            .having((error) => error.data, 'data', {
              'saved': true,
              'reload_required': true,
            })
            .having((error) => error.message, 'message', '任务已保存'),
      ),
    );
  });

  test(
    'keeps online install recovery flags but never an install target path',
    () async {
      final client = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=signed-cookie',
          csrfToken: 'csrf-token',
        ),
        client: MockClient(
          (_) async => utf8Response(
            '{"ok":false,"confirm_required":true,"target_exists":true,"target":"/srv/fls/scripts/demo.sh","request_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","retry_allowed":true,"msg":"请确认覆盖：/srv/fls/scripts/demo.sh"}',
            409,
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.postJson('/api/online-scripts/install/demo', const {}),
        throwsA(
          isA<PanelApiException>()
              .having((error) => error.data, 'data', {
                'confirm_required': true,
                'target_exists': true,
                'request_id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'retry_allowed': true,
                'msg': '请确认覆盖：[面板路径]',
              })
              .having((error) => error.message, 'message', '请确认覆盖：[面板路径]'),
        ),
      );
    },
  );

  test('redacts credentials embedded in online script error messages', () async {
    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=signed-cookie',
        csrfToken: 'csrf-token',
      ),
      client: MockClient(
        (_) async => utf8Response(
          jsonEncode({
            'ok': false,
            'msg':
                'fetch https://source.example/x?token=url-secret and {"api_key":"json-secret"}',
          }),
          502,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.postJson('/api/online-scripts/refresh', const {}),
      throwsA(
        isA<PanelApiException>()
            .having(
              (error) => error.message,
              'message',
              allOf(contains('token=[已隐藏]'), contains('"api_key":"[已隐藏]"')),
            )
            .having(
              (error) => error.data?['msg'],
              'safe msg',
              contains('token=[已隐藏]'),
            ),
      ),
    );
  });

  test('keeps dependency recovery metadata and redacts panel paths', () async {
    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=signed-cookie',
        csrfToken: 'csrf-token',
      ),
      client: MockClient(
        (_) async => utf8Response(
          jsonEncode({
            'ok': false,
            'install_id': 'a' * 32,
            'kind': 'dependency',
            'operation': 'uninstall',
            'package': 'requests',
            'status': 'unknown',
            'retry_confirmation_required': true,
            'error': 'log /srv/fls/log/deps-uninstall.log',
            'private_field': '/srv/fls/private',
          }),
          503,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.getJson('/api/deps/install-log/${'a' * 32}'),
      throwsA(
        isA<PanelApiException>().having((error) => error.data, 'data', {
          'ok': false,
          'install_id': 'a' * 32,
          'kind': 'dependency',
          'operation': 'uninstall',
          'package': 'requests',
          'status': 'unknown',
          'retry_confirmation_required': true,
          'error': 'log [面板路径]',
        }),
      ),
    );
  });

  test(
    'retains safe task action recovery details on mounted panel paths',
    () async {
      final client = PanelApiClient(
        baseUrl: 'https://fls.example/panel',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=signed-cookie',
          csrfToken: 'csrf-token',
        ),
        client: MockClient(
          (_) async => utf8Response(
            '{"ok":false,"action":"delete","request_id":"request-1","msg":"检查结果","unknown_ids":["task-1"],"results":[{"task_id":"task-1","status":"unknown","msg":"待确认","env":"must-drop"}]}',
            409,
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.postJson('/api/task/bulk-action', const {}),
        throwsA(
          isA<PanelApiException>().having((error) => error.data, 'data', {
            'action': 'delete',
            'request_id': 'request-1',
            'msg': '检查结果',
            'unknown_ids': ['task-1'],
            'results': [
              {'task_id': 'task-1', 'status': 'unknown', 'msg': '待确认'},
            ],
          }),
        ),
      );
    },
  );

  test('limits JSON response size', () async {
    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      maxResponseBytes: 4,
      client: MockClient((_) async => utf8Response('{"large":true}', 200)),
    );
    addTearDown(client.close);

    await expectLater(
      client.getJson('/api/status'),
      throwsA(
        isA<PanelApiException>().having(
          (error) => error.message,
          'message',
          contains('超过'),
        ),
      ),
    );
  });

  test(
    'downloads bounded file bytes through the authenticated panel session',
    () async {
      final client = PanelApiClient(
        baseUrl: 'https://fls.example/panel',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=download-session',
          csrfToken: 'download-csrf',
        ),
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/panel/api/history/export');
          expect(
            request.headers['cookie'],
            'fls_native_session=download-session',
          );
          expect(request.headers['x-token'], isNull);
          expect(request.headers['accept'], contains('text/csv'));
          return http.Response.bytes([0xef, 0xbb, 0xbf, 65, 44, 66], 200);
        }),
      );
      addTearDown(client.close);

      final bytes = await client.getBytes(
        '/api/history/export',
        maxBytes: 1024,
      );

      expect(bytes, [0xef, 0xbb, 0xbf, 65, 44, 66]);
    },
  );

  test('rejects oversized downloads and parses JSON download errors', () async {
    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      maxResponseBytes: 64,
      client: MockClient((request) async {
        if (request.url.queryParameters['retry'] == '1') {
          return utf8Response('{"ok":false,"msg":"文件超过限制"}', 413);
        }
        return http.Response.bytes(List<int>.filled(65, 0), 200);
      }),
    );
    addTearDown(client.close);

    await expectLater(
      client.getBytes('/api/logfile/large.log/download'),
      throwsA(
        isA<PanelApiException>().having(
          (error) => error.message,
          'message',
          contains('超过'),
        ),
      ),
    );
    await expectLater(
      client.getBytes('/api/logfile/large.log/download?retry=1'),
      throwsA(
        isA<PanelApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          413,
        ),
      ),
    );
  });
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
