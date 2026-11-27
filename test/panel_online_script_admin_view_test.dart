import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_online_script_admin_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_online_scripts_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'panel_test_http.dart';

void main() {
  const oldJson = '[{"id":"old"}]';
  const currentJson = '[{"id":"current"}]';
  const revision =
      'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

  testWidgets('preserves an editor draft when the source cache changes', (
    tester,
  ) async {
    var sourceReads = 0;
    final sourceLoaded = Completer<void>();
    final conflictRead = Completer<void>();
    final putSent = Completer<void>();
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=script-session',
        csrfToken: 'script-csrf',
      ),
      client: MockClient((request) async {
        if (request.url.path == '/api/online-scripts/refresh-options') {
          return utf8Response('{"ok":true,"proxies":[]}', 200);
        }
        if (request.url.path == '/api/online-scripts/refresh-history') {
          return utf8Response(
            '{"ok":true,"items":[],"total":0,"offset":0,"limit":10}',
            200,
          );
        }
        if (request.url.path == '/api/online-scripts/import-tasks-history') {
          return utf8Response('{"ok":true,"items":[],"has_more":false}', 200);
        }
        if (request.url.path == '/api/online-scripts/task-link-history') {
          return utf8Response('{"ok":true,"items":[],"has_more":false}', 200);
        }
        if (request.url.path == '/api/online-scripts/source' &&
            request.method == 'GET') {
          sourceReads++;
          if (!sourceLoaded.isCompleted) sourceLoaded.complete();
          if (sourceReads == 2 && !conflictRead.isCompleted) {
            conflictRead.complete();
          }
          final text = sourceReads == 1 ? oldJson : currentJson;
          return utf8Response(
            jsonEncode({
              'ok': true,
              'json_text': text,
              'cache_revision': revision,
            }),
            200,
          );
        }
        expect(request.method, 'PUT');
        expect(request.headers['x-csrf-token'], 'script-csrf');
        expect(jsonDecode(request.body)['json_text'], '[{"id":"draft"}]');
        if (!putSent.isCompleted) putSent.complete();
        return utf8Response(
          '{"ok":false,"code":"revision_conflict","msg":"缓存已变更，未保存"}',
          409,
        );
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelOnlineScriptSourceEditorView(
            manager: PanelOnlineScriptsManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => sourceLoaded.future);
    await tester.pump();

    final editor = tester.widget<TextField>(find.byType(TextField));
    expect(editor.controller!.text, oldJson);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNotNull,
    );
    editor.controller!.text = '[{"id":"draft"}]';
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.runAsync(() => putSent.future);
    await tester.pump();
    await tester.runAsync(() => conflictRead.future);
    await tester.pump();
    await tester.pump();

    expect(find.text('缓存已被其他操作修改。当前草稿保留；可查看新版本后决定是否替换。'), findsOneWidget);
    expect(find.text('查看当前'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '[{"id":"draft"}]',
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    expect(sourceReads, 2);

    await tester.tap(find.text('查看当前'));
    await tester.pump();
    await tester.tap(find.text('使用服务器版本').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      currentJson,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('renders task operation diagnostics with credentials redacted', (
    tester,
  ) async {
    const requestId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final historyLoaded = Completer<void>();
    final statusLoaded = Completer<void>();
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=script-session',
        csrfToken: 'script-csrf',
      ),
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/api/online-scripts/refresh-options':
            return utf8Response('{"ok":true,"proxies":[]}', 200);
          case '/api/online-scripts/refresh-history':
            return utf8Response('{"ok":true,"items":[]}', 200);
          case '/api/online-scripts/source':
            return utf8Response(
              jsonEncode({
                'ok': true,
                'json_text': '[]',
                'cache_revision': revision,
              }),
              200,
            );
          case '/api/online-scripts/import-tasks-history':
            if (!historyLoaded.isCompleted) historyLoaded.complete();
            return utf8Response(
              jsonEncode({
                'ok': true,
                'items': [
                  {
                    'request_id': requestId,
                    'state': 'failed',
                    'script_id': 'demo',
                    'updated_at': 'now',
                  },
                ],
                'has_more': false,
              }),
              200,
            );
          case '/api/online-scripts/import-tasks-status/$requestId':
            if (!statusLoaded.isCompleted) statusLoaded.complete();
            return utf8Response(
              jsonEncode({
                'ok': true,
                'request_id': requestId,
                'state': 'failed',
                'script_id': 'demo',
                'error':
                    'fetch https://source.example/tasks?token=private-value',
                'active': false,
                'retry_allowed': false,
              }),
              200,
            );
          default:
            fail('Unexpected request: ${request.method} ${request.url}');
        }
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelOnlineScriptTaskHistoryView(
            manager: PanelOnlineScriptsManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => historyLoaded.future);
    await tester.pump();
    await tester.pump();
    expect(find.text('demo'), findsOneWidget);
    await tester.tap(find.text('demo').first);
    await tester.pump();
    await tester.runAsync(() => statusLoaded.future);
    await tester.pump();

    expect(find.textContaining('token=[已隐藏]'), findsOneWidget);
    expect(find.textContaining('private-value'), findsNothing);
  });

  for (final taskImport in [true, false]) {
    final kind = taskImport ? 'import-tasks' : 'task-link';
    const requestId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    Map<String, dynamic> record({
      bool active = false,
      String state = 'unknown',
    }) => {
      'ok': true,
      'request_id': requestId,
      'script_id': 'demo',
      'state': state,
      'active': active,
      'retry_allowed': true,
      'receipt_confirmation_required': true,
      'scheduler_reload_required': true,
    };

    testWidgets('$kind disables recovery while another worker is active', (
      tester,
    ) async {
      var writes = 0;
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        client: MockClient((request) async {
          if (request.method != 'GET') writes++;
          return utf8Response(
            jsonEncode(
              request.url.path.endsWith('-history')
                  ? {
                      'ok': true,
                      'items': [record(active: true)],
                    }
                  : record(active: true),
            ),
            200,
          );
        }),
      );
      addTearDown(api.close);
      await openTaskOperation(tester, api, taskImport: taskImport);
      for (final label in ['核对原请求', '继续原请求', if (taskImport) '重新加载调度器']) {
        final button = find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
      }
      expect(find.text('归档记录'), findsNothing);
      expect(writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '$kind queries original request after 409 and ignores an older 401',
      (tester) async {
        var reads = 0;
        var writes = 0;
        var unauthorized = 0;
        final oldResponse = Completer<void>();
        final api = PanelApiClient(
          baseUrl: 'https://fls.example',
          client: MockClient((request) async {
            if (request.url.path.endsWith('-history')) {
              return utf8Response(
                jsonEncode({
                  'ok': true,
                  'items': [record()],
                }),
                200,
              );
            }
            if (request.method == 'POST') {
              writes++;
              expect(
                request.url.path,
                '/api/online-scripts/$kind-confirm/$requestId',
              );
              return utf8Response(
                '{"ok":false,"msg":"原操作仍在处理中","active":true}',
                409,
              );
            }
            reads++;
            expect(
              request.url.path,
              '/api/online-scripts/$kind-status/$requestId',
            );
            if (reads == 2) {
              await oldResponse.future;
              return utf8Response(
                '{"ok":false,"msg":"expired old response"}',
                401,
              );
            }
            return utf8Response(
              jsonEncode(
                reads == 1
                    ? record()
                    : {
                        'ok': true,
                        'request_id': requestId,
                        'script_id': 'demo',
                        'state': 'completed',
                      },
              ),
              200,
            );
          }),
        );
        addTearDown(api.close);
        await openTaskOperation(
          tester,
          api,
          taskImport: taskImport,
          onUnauthorized: (_) async {
            unauthorized++;
          },
        );
        await tester.tap(find.byTooltip('刷新状态'));
        await pumpUntil(tester, () => reads == 2);
        await tester.tap(find.text('核对原请求'));
        await pumpUntilFound(tester, find.text('completed'));
        expect(reads, 3);
        expect(writes, 1);
        oldResponse.complete();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        expect(find.text('completed'), findsOneWidget);
        expect(unauthorized, 0);
        expect(writes, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$kind exits nested operation on a current unauthorized response',
      (tester) async {
        var unauthorized = 0;
        final api = PanelApiClient(
          baseUrl: 'https://fls.example',
          client: MockClient((request) async {
            if (request.url.path.endsWith('-history')) {
              return utf8Response(
                jsonEncode({
                  'ok': true,
                  'items': [record()],
                }),
                200,
              );
            }
            return utf8Response('{"ok":false,"msg":"session expired"}', 401);
          }),
        );
        addTearDown(api.close);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PanelOnlineScriptTaskHistoryView(
                manager: PanelOnlineScriptsManager(api),
                onUnauthorized: (_) async {
                  unauthorized++;
                },
              ),
            ),
          ),
        );
        if (!taskImport) {
          await tester.tap(find.text('外部任务同步'));
        }
        await pumpUntilFound(tester, find.text('demo'));
        await tester.tap(find.text('demo'));
        await pumpUntil(tester, () => unauthorized == 1);
        await tester.pumpAndSettle();
        expect(find.byTooltip('刷新状态'), findsNothing);
        expect(find.byTooltip('刷新记录'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

Future<void> openTaskOperation(
  WidgetTester tester,
  PanelApiClient api, {
  required bool taskImport,
  Future<void> Function(Object)? onUnauthorized,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PanelOnlineScriptTaskHistoryView(
          manager: PanelOnlineScriptsManager(api),
          onUnauthorized: onUnauthorized ?? (_) async {},
        ),
      ),
    ),
  );
  await pumpUntilFound(tester, find.text('demo'));
  if (!taskImport) {
    await tester.tap(find.text('外部任务同步'));
    await pumpUntilFound(tester, find.text('demo'));
  }
  await tester.tap(find.text('demo'));
  await pumpUntilFound(tester, find.text('核对原请求'));
}
