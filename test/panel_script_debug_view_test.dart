import 'dart:convert';

import 'package:fls_for_android/features/panel_script_debug_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_script_debug_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=debug-view-session',
    csrfToken: 'debug-view-csrf',
  );

  testWidgets('starts, restores, and explicitly stops a panel debug run', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final requests = <String>[];
    var stopCalls = 0;
    var stopped = false;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'POST' &&
            request.url.path == '/api/scripts/debug-runs') {
          expect(request.headers['x-csrf-token'], session.csrfToken);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['path'], 'jobs/demo.py');
          expect(body['request_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
          return _jsonResponse({
            'ok': true,
            'replayed': false,
            'run': _run(status: 'running'),
          }, 202);
        }
        if (request.method == 'GET' &&
            request.url.path == '/api/scripts/debug-runs') {
          return _jsonResponse({
            'ok': true,
            'runs': [_run(status: 'running')],
          });
        }
        if (request.method == 'GET' &&
            request.url.path == '/api/scripts/debug-runs/${'a' * 32}') {
          return _jsonResponse({
            'ok': true,
            'run': _run(status: stopped ? 'stopped' : 'running'),
            'log': 'line one\nline two',
          });
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/scripts/debug-runs/${'a' * 32}/stop') {
          expect(request.headers['x-csrf-token'], session.csrfToken);
          stopCalls++;
          stopped = true;
          return _jsonResponse({'ok': true, 'run': _run(status: 'stopped')});
        }
        fail('unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);
    final manager = PanelScriptDebugManager(api);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => PanelScriptDebugView(
                    manager: manager,
                    initialPath: 'jobs/demo.py',
                    routesToClose: 1,
                    onUnauthorized: (_) async {},
                  ),
                ),
              ),
              child: const Text('调试'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('调试'));
    await pumpUntilFound(tester, find.text('line one\nline two'));
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('jobs/demo.py'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('停止调试运行'));
    await tester.pumpAndSettle();
    expect(find.text('停止调试运行？'), findsOneWidget);
    await tester.tap(find.text('停止运行'));
    await pumpUntilFound(tester, find.text('已停止'));
    expect(stopCalls, 1);
    expect(requests, contains('POST /api/scripts/debug-runs/${'a' * 32}/stop'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history opens a known run and leaving the page does not stop it',
    (tester) async {
      final requests = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          if (request.method == 'GET' &&
              request.url.path == '/api/scripts/debug-runs') {
            return _jsonResponse({
              'ok': true,
              'runs': [_run(status: 'unknown')],
            });
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/scripts/debug-runs/${'a' * 32}') {
            return _jsonResponse({
              'ok': true,
              'run': _run(status: 'unknown'),
              'log': 'previous output',
            });
          }
          fail('unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: PanelScriptDebugHistoryView(
            manager: PanelScriptDebugManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('jobs/demo.py'));
      await tester.tap(find.text('jobs/demo.py'));
      await pumpUntilFound(tester, find.text('previous output'));
      expect(find.text('结果未知'), findsOneWidget);
      expect(find.byTooltip('停止调试运行'), findsNothing);
      expect(find.text('重新运行'), findsNothing);
      expect(tester.takeException(), isNull);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(requests.where((request) => request.contains('/stop')), isEmpty);
    },
  );
}

Map<String, dynamic> _run({required String status}) => {
  'id': 'a' * 32,
  'path': 'jobs/demo.py',
  'status': status,
  'running': const {'starting', 'running'}.contains(status),
  'returncode': status == 'stopped' ? -15 : null,
  'error': '',
  'created_at': '2026-11-26 12:00:00',
  'updated_at': '2026-11-26 12:00:01',
};

http.Response _jsonResponse(
  Map<String, dynamic> body, [
  int statusCode = 200,
]) => utf8Response(jsonEncode(body), statusCode);
