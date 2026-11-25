import 'dart:convert';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_script_pull_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=pull-session',
    csrfToken: 'pull-csrf',
  );

  test(
    'uses whitelisted options and the idempotent pull job contract',
    () async {
      final requests = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/prefix',
        credentials: session,
        client: panelMockClient((request) async {
          requests.add('${request.method} ${request.url}');
          expect(request.headers['cookie'], session.cookie);
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/scripts/pull-options')) {
            return _jsonResponse({
              'ok': true,
              'proxies': [
                {'id': 'p1', 'name': 'Local relay', 'type': 'http'},
              ],
            });
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/api/scripts/pull')) {
            expect(request.headers['x-csrf-token'], session.csrfToken);
            expect(jsonDecode(request.body), {
              'url': 'https://example.invalid/demo.py?sig=secret',
              'path': 'jobs/demo.py',
              'proxy_id': 'p1',
              'request_id': 'a' * 32,
            });
            return _jsonResponse({
              'ok': true,
              'job': _job(status: 'downloading'),
            }, 202);
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/scripts/pull-history')) {
            expect(request.url.queryParameters, {'limit': '5'});
            return _jsonResponse({
              'ok': true,
              'items': [_job(status: 'downloading')],
            });
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/scripts/pull/${'b' * 32}')) {
            return _jsonResponse({'ok': true, 'job': _job(status: 'complete')});
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith(
                '/api/scripts/pull/${'b' * 32}/cancel',
              )) {
            expect(request.headers['x-csrf-token'], session.csrfToken);
            return _jsonResponse({
              'ok': true,
              'job': _job(status: 'cancelling'),
            }, 202);
          }
          fail('unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(api.close);
      final manager = PanelScriptPullManager(api);

      final options = await manager.fetchOptions();
      final submitted = await manager.submitFile(
        url: 'https://example.invalid/demo.py?sig=secret',
        path: 'jobs/demo.py',
        requestId: 'a' * 32,
        proxyId: 'p1',
      );
      final history = await manager.fetchHistory(limit: 5);
      final current = await manager.fetchJob('b' * 32);
      final cancelled = await manager.cancel('b' * 32);

      expect(options.proxies.single.name, 'Local relay');
      expect(submitted.isActive, isTrue);
      expect(submitted.progress.percent, 42);
      expect(history.items.single.id, 'b' * 32);
      expect(current.isComplete, isTrue);
      expect(cancelled.status, 'cancelling');
      expect(requests, hasLength(5));
    },
  );

  test('rejects malformed job identifiers, paths and progress', () async {
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient(
        (request) async => _jsonResponse({
          'ok': true,
          'job': {
            ..._job(),
            'progress': {..._job()['progress'] as Map, 'percent': 101},
          },
        }),
      ),
    );
    addTearDown(api.close);
    final manager = PanelScriptPullManager(api);

    await expectLater(
      manager.submitFile(
        url: 'https://example.invalid/a.py',
        path: '../escape.py',
        requestId: 'a' * 32,
      ),
      throwsArgumentError,
    );
    await expectLater(manager.fetchJob('../bad'), throwsArgumentError);
    await expectLater(
      manager.submitFile(
        url: 'https://example.invalid/a.py',
        path: 'a.py',
        requestId: 'bad',
      ),
      throwsArgumentError,
    );
    await expectLater(
      manager.submitFile(
        url: 'https://example.invalid/a.py',
        path: 'a.py',
        requestId: 'c' * 32,
      ),
      throwsA(isA<PanelApiException>()),
    );
  });
}

Map<String, dynamic> _job({String status = 'complete'}) => {
  'id': 'b' * 32,
  'request_id': 'a' * 32,
  'kind': 'file',
  'path': 'jobs/demo.py',
  'source_host': 'example.invalid',
  'status': status,
  'progress': {
    'state': status == 'downloading' ? 'downloading' : status,
    'downloaded_bytes': 42,
    'total_bytes': 100,
    'percent': status == 'downloading' ? 42 : 42,
  },
  'error_code': '',
  'created_at': '2026-11-25T10:00:00+08:00',
  'updated_at': '2026-11-25T10:00:01+08:00',
  'replayed': false,
};

http.Response _jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);
