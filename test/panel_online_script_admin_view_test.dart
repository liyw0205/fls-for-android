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
        return utf8Response(
          '{"ok":false,"code":"revision_conflict","msg":"缓存已变更，未保存"}',
          409,
        );
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelOnlineScriptSourceEditorView(
          manager: PanelOnlineScriptsManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

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
        home: PanelOnlineScriptTaskHistoryView(
          manager: PanelOnlineScriptsManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('demo'), findsOneWidget);
    await tester.tap(find.text('demo').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('token=[已隐藏]'), findsOneWidget);
    expect(find.textContaining('private-value'), findsNothing);
  });
}
