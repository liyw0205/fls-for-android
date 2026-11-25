import 'dart:convert';

import 'panel_test_http.dart';

import 'package:fls_for_android/features/panel_online_scripts_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_online_scripts_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

void main() {
  testWidgets('returns from nested script pages when the session expires', (
    tester,
  ) async {
    var unauthorizedCalls = 0;
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=expired-session',
        csrfToken: 'expired-csrf',
      ),
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/api/online-scripts/catalog':
            return utf8Response(
              '{"ok":true,"items":[{"id":"demo","name":"演示脚本","type":"raw","has_install":true}],"page":1,"pages":1,"total":1}',
              200,
            );
          case '/api/online-scripts/detail/demo':
            return utf8Response(
              '{"ok":true,"item":{"id":"demo","name":"演示脚本","has_install":true}}',
              200,
            );
          case '/api/online-scripts/install-options/demo':
            return utf8Response('{"ok":false,"msg":"会话已过期"}', 401);
          default:
            fail('Unexpected request: ${request.method} ${request.url}');
        }
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelOnlineScriptsView(
            manager: PanelOnlineScriptsManager(api),
            onUnauthorized: (_) async => unauthorizedCalls++,
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('演示脚本'));
    await tester.tap(find.text('演示脚本'));
    await pumpUntilFound(tester, find.text('安装 / 更新'));
    await tester.tap(find.text('安装 / 更新'));
    await pumpUntilFound(tester, find.text('搜索在线脚本'));

    expect(unauthorizedCalls, 1);
    expect(find.text('搜索在线脚本'), findsOneWidget);
    expect(find.text('安装 / 更新'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('browses a script and confirms an existing target before install', (
    tester,
  ) async {
    String? installId;
    var installAttempts = 0;
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=script-session',
        csrfToken: 'script-csrf',
      ),
      client: MockClient((request) async {
        expect(request.headers['cookie'], 'fls_native_session=script-session');
        switch (request.url.path) {
          case '/api/online-scripts/catalog':
            return utf8Response(
              '{"ok":true,"items":[{"id":"demo","name":"演示脚本","type":"raw","link_name":"demo.sh","has_install":true,"has_doc":true,"has_tasks":true,"task_count":1}],"page":1,"pages":1,"total":1}',
              200,
            );
          case '/api/online-scripts/detail/demo':
            return utf8Response(
              '{"ok":true,"item":{"id":"demo","name":"演示脚本","type":"raw","description":"用于验证","has_install":true,"has_doc":true,"has_tasks":true,"task_count":1}}',
              200,
            );
          case '/api/online-scripts/doc/demo':
            return utf8Response(
              '{"ok":true,"format":"markdown","content":"# 安装说明\\n安全的原生文档","source_url":"https://example.invalid/README.md","size_bytes":30}',
              200,
            );
          case '/api/online-scripts/install-options/demo':
            return utf8Response(
              '{"ok":true,"script_id":"demo","items":[{"index":1,"name":"每日任务","cron":"0 0 * * *","command":"python task.py","valid":true,"variable_names":["API_TOKEN"],"sensitive_variables":["API_TOKEN"]}],"proxies":[],"page":1,"pages":1,"total":1}',
              200,
            );
          case '/api/online-scripts/install/demo':
            installAttempts++;
            expect(request.headers['x-csrf-token'], 'script-csrf');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final requestId = body['request_id'] as String;
            expect(RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId), isTrue);
            if (installId == null) {
              installId = requestId;
            } else {
              expect(requestId, installId);
            }
            expect(body['import_task'], isTrue);
            expect(body['task_indexes'], ['1']);
            if (installAttempts == 1) {
              expect(body['force'], isFalse);
              return utf8Response(
                '{"ok":false,"confirm_required":true,"target_exists":true,"target":"/secret/panel/scripts/demo.sh","request_id":"$requestId","retry_allowed":true,"msg":"目标已存在，请确认覆盖"}',
                409,
              );
            }
            expect(body['force'], isTrue);
            return utf8Response(
              '{"ok":true,"request_id":"$requestId","install_id":"$requestId","running":false,"status":"已完成","phase":"completed"}',
              200,
            );
          default:
            if (request.url.path != '/api/online-scripts/log/$installId') {
              fail('Unexpected request: ${request.method} ${request.url}');
            }
            if (request.url.queryParameters['state_only'] == '1') {
              return utf8Response(
                '{"ok":true,"install_id":"$installId","running":false,"status":"已完成","phase":"completed","download_progress":{"state":"complete","kind":"raw","downloaded_bytes":1024,"total_bytes":1024,"percent":100}}',
                200,
              );
            }
            return utf8Response(
              '{"ok":true,"install_id":"$installId","running":false,"status":"已完成","phase":"completed","log":"安装完成"}',
              200,
            );
        }
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelOnlineScriptsView(
            manager: PanelOnlineScriptsManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('演示脚本'));
    await tester.tap(find.text('演示脚本'));
    await pumpUntilFound(tester, find.text('安全的原生文档'));
    await tester.tap(find.text('安装 / 更新'));
    await pumpUntilFound(tester, find.text('导入附带任务'));
    await tester.tap(find.text('导入附带任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每日任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续 · 已选 1 个任务'));
    await pumpUntilFound(tester, find.text('覆盖已有脚本？'));
    expect(find.text('/secret/panel/scripts/demo.sh'), findsNothing);
    await tester.tap(find.text('覆盖安装'));
    await pumpUntilFound(tester, find.text('安装完成'));

    expect(installAttempts, 2);
    expect(find.text('1 KB / 1 KB · 100%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
