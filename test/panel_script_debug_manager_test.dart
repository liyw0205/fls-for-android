import 'dart:convert';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_script_debug_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_test_http.dart';

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=debug-session',
    csrfToken: 'debug-csrf',
  );

  test(
    'uses the idempotent start, history, detail, and stop contracts',
    () async {
      final requests = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/root',
        credentials: session,
        client: panelMockClient((request) async {
          requests.add('${request.method} ${request.url}');
          expect(request.headers['cookie'], session.cookie);
          if (request.method == 'POST' &&
              request.url.path.endsWith('/api/scripts/debug-runs')) {
            expect(request.headers['x-csrf-token'], session.csrfToken);
            expect(jsonDecode(request.body), {
              'path': 'jobs/demo.py',
              'request_id': 'a' * 32,
            });
            return utf8Response(
              jsonEncode({
                'ok': true,
                'replayed': true,
                'run': _run(status: 'running'),
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/scripts/debug-runs')) {
            expect(request.url.queryParameters, {'limit': '5'});
            return utf8Response(
              jsonEncode({
                'ok': true,
                'runs': [_run(status: 'running')],
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith(
                '/api/scripts/debug-runs/${'b' * 32}',
              )) {
            expect(request.url.queryParameters, {'lines': '90'});
            return utf8Response(
              jsonEncode({
                'ok': true,
                'run': _run(status: 'running'),
                'log': 'running output',
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith(
                '/api/scripts/debug-runs/${'b' * 32}/stop',
              )) {
            expect(request.headers['x-csrf-token'], session.csrfToken);
            expect(jsonDecode(request.body), isEmpty);
            return utf8Response(
              jsonEncode({'ok': true, 'run': _run(status: 'stopped')}),
              200,
            );
          }
          fail('unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(api.close);

      final manager = PanelScriptDebugManager(api);
      final started = await manager.start(
        path: 'jobs/demo.py',
        requestId: 'a' * 32,
      );
      expect(started.id, 'b' * 32);
      expect(started.replayed, isTrue);
      expect(started.isActive, isTrue);

      final history = await manager.fetchHistory(limit: 5);
      expect(history.runs, hasLength(1));
      expect(history.runs.single.path, 'jobs/demo.py');

      final detail = await manager.fetchRun('b' * 32, lines: 90);
      expect(detail.log, 'running output');
      expect(detail.run.status, 'running');

      final stopped = await manager.stop('b' * 32);
      expect(stopped.status, 'stopped');
      expect(stopped.isActive, isFalse);
      expect(requests, hasLength(4));
    },
  );

  test(
    'rejects invalid IDs, unsafe paths, and inconsistent DTO states',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient(
          (_) async => throw StateError('unexpected request'),
        ),
      );
      addTearDown(api.close);
      final manager = PanelScriptDebugManager(api);

      await expectLater(
        manager.start(path: '../demo.py', requestId: 'a' * 32),
        throwsArgumentError,
      );
      await expectLater(
        manager.start(path: 'demo.py', requestId: 'bad'),
        throwsArgumentError,
      );
      await expectLater(manager.fetchRun('bad'), throwsArgumentError);
    },
  );
}

Map<String, dynamic> _run({required String status}) => {
  'id': 'b' * 32,
  'path': 'jobs/demo.py',
  'status': status,
  'running': const {'starting', 'running'}.contains(status),
  'returncode': status == 'stopped' ? -15 : null,
  'error': '',
  'created_at': '2026-11-26 12:00:00',
  'updated_at': '2026-11-26 12:00:01',
};
