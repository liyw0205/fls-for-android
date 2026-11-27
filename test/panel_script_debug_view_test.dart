import 'dart:async';
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

  testWidgets('lost start response only queries the retained request', (
    tester,
  ) async {
    var starts = 0;
    var lookups = 0;
    String? requestId;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        if (request.method == 'POST') {
          starts++;
          requestId = (jsonDecode(request.body) as Map)['request_id'] as String;
          throw http.ClientException('start response lost');
        }
        if (request.url.path.contains('/debug-requests/')) {
          lookups++;
          expect(request.url.path, '/api/scripts/debug-requests/$requestId');
          return _jsonResponse({
            'ok': true,
            'run': {
              ..._run(status: 'succeeded'),
              'request_id': requestId,
              'active': false,
            },
          });
        }
        return _jsonResponse({
          'ok': true,
          'run': {
            ..._run(status: 'succeeded'),
            'request_id': requestId,
            'active': false,
          },
          'log': 'recovered output',
        });
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelScriptDebugView(
          manager: PanelScriptDebugManager(api),
          initialPath: 'jobs/demo.py',
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.textContaining('面板连接失败'));
    expect(starts, 1);
    await tester.tap(find.byTooltip('刷新状态与日志'));
    await pumpUntilFound(tester, find.text('recovered output'));
    expect(lookups, 1);
    expect(starts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed state query disables rerun until a trusted query succeeds',
    (tester) async {
      var queries = 0;
      final pending = Completer<http.Response>();
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient((request) async {
          expect(request.method, 'GET');
          queries++;
          if (queries == 2) return pending.future;
          return _jsonResponse({
            'ok': true,
            'run': _run(status: 'succeeded'),
            'log': 'done',
          });
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PanelScriptDebugView(
            manager: PanelScriptDebugManager(api),
            initialRunId: 'a' * 32,
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('done'));
      await tester.tap(find.byTooltip('刷新状态与日志'));
      await pumpUntil(tester, () => queries == 2);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新运行'))
            .onPressed,
        isNull,
      );
      pending.complete(
        _jsonResponse({'ok': false, 'msg': 'query unavailable'}, 503),
      );
      await pumpUntilFound(tester, find.textContaining('query unavailable'));
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新运行'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('刷新状态与日志'));
      await pumpUntil(tester, () => queries == 3);
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新运行'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stop response loss queries the same run without repeating stop',
    (tester) async {
      var stops = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            stops++;
            expect(
              request.url.path,
              '/api/scripts/debug-runs/${'a' * 32}/stop',
            );
            throw http.ClientException('stop response lost');
          }
          expect(request.url.path, '/api/scripts/debug-runs/${'a' * 32}');
          return _jsonResponse({
            'ok': true,
            'run': _run(status: stops == 0 ? 'running' : 'stopped'),
            'log': 'output',
          });
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PanelScriptDebugView(
            manager: PanelScriptDebugManager(api),
            initialRunId: 'a' * 32,
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('output'));
      await tester.tap(find.byTooltip('停止调试运行'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('停止运行'));
      await pumpUntilFound(tester, find.text('已停止'));
      expect(stops, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('active cleanup and stopping states do not offer another write', (
    tester,
  ) async {
    var status = 'succeeded';
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        expect(request.method, 'GET');
        return _jsonResponse({
          'ok': true,
          'run': {
            ..._run(status: status),
            'active': true,
            'running': status == 'stopping',
          },
          'log': status,
        });
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelScriptDebugView(
          manager: PanelScriptDebugManager(api),
          initialRunId: 'a' * 32,
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('succeeded'));
    expect(find.text('重新运行'), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '停止调试运行',
            ),
          )
          .onPressed,
      isNull,
    );
    status = 'stopping';
    await tester.tap(find.byTooltip('刷新状态与日志'));
    await pumpUntilFound(tester, find.text('停止中'));
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '停止调试运行',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  for (final responseCode in [200, 401]) {
    testWidgets('late $responseCode from the previous panel is discarded', (
      tester,
    ) async {
      final oldResponse = Completer<http.Response>();
      var oldCalls = 0;
      var unauthorized = 0;
      final oldApi = PanelApiClient(
        baseUrl: 'https://old-panel.example',
        credentials: session,
        client: panelMockClient((_) async {
          oldCalls++;
          return oldResponse.future;
        }),
      );
      final newApi = PanelApiClient(
        baseUrl: 'https://new-panel.example',
        credentials: session,
        client: panelMockClient(
          (_) async => _jsonResponse({
            'ok': true,
            'run': _run(status: 'succeeded'),
            'log': 'new panel',
          }),
        ),
      );
      addTearDown(oldApi.close);
      addTearDown(newApi.close);
      Widget page(PanelApiClient api) => MaterialApp(
        home: PanelScriptDebugView(
          manager: PanelScriptDebugManager(api),
          initialRunId: 'a' * 32,
          onUnauthorized: (_) async {
            unauthorized++;
          },
        ),
      );
      await tester.pumpWidget(page(oldApi));
      await pumpUntil(tester, () => oldCalls == 1);
      await tester.pumpWidget(page(newApi));
      await pumpUntilFound(tester, find.text('new panel'));
      oldResponse.complete(
        _jsonResponse({
          'ok': responseCode == 200,
          'msg': 'old session expired',
          'run': _run(status: 'running'),
          'log': 'old panel',
        }, responseCode),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.text('new panel'), findsOneWidget);
      expect(find.text('old panel'), findsNothing);
      expect(unauthorized, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('current unauthorized response closes the run once', (
    tester,
  ) async {
    var unauthorized = 0;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient(
        (_) async =>
            _jsonResponse({'ok': false, 'msg': 'session expired'}, 401),
      ),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => PanelScriptDebugView(
                  manager: PanelScriptDebugManager(api),
                  initialRunId: 'a' * 32,
                  onUnauthorized: (_) async {
                    unauthorized++;
                  },
                ),
              ),
            ),
            child: const Text('open debug'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open debug'));
    await pumpUntil(tester, () => unauthorized == 1);
    await tester.pumpAndSettle();
    expect(find.text('脚本调试'), findsNothing);
    expect(unauthorized, 1);
    expect(tester.takeException(), isNull);
  });
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
