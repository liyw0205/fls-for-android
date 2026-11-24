import 'dart:convert';

import 'package:fls_for_android/features/panel_task_editor_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_tasks_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('creates a task from the native form with a session', (
    tester,
  ) async {
    var created = false;
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=form-session',
        csrfToken: 'form-csrf',
      ),
      client: MockClient((request) async {
        expect(request.headers['cookie'], 'fls_native_session=form-session');
        if (request.url.path == '/api/tasks/form-options') {
          return http.Response(
            '{"ok":true,"collections":[{"id":"group-1","name":"签到"}],"proxies":[],"notifications":[]}',
            200,
          );
        }
        expect(request.url.path, '/api/tasks');
        expect(request.method, 'POST');
        expect(request.headers['x-csrf-token'], 'form-csrf');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['request_id'], matches(RegExp(r'^[a-f0-9]{32}$')));
        expect(body['task']['name'], '每日签到');
        expect(body['task']['command'], 'python daily.py');
        created = true;
        return http.Response(
          '{"ok":true,"created":true,"task":{"id":"task-id","name":"每日签到"}}',
          201,
        );
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => PanelTaskEditorView(
                      manager: PanelTasksManager(api),
                      onUnauthorized: (_) async {},
                    ),
                  ),
                ),
                child: const Text('打开编辑器'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开编辑器'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), '每日签到');
    await tester.enterText(find.byType(TextFormField).at(2), 'python daily.py');
    await tester.tap(find.text('保存任务'));
    await tester.pumpAndSettle();

    expect(created, isTrue);
    expect(find.text('打开编辑器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovers scheduler reload without resubmitting a saved task', (
    tester,
  ) async {
    var saveRequests = 0;
    var reloadRequests = 0;
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=form-session',
        csrfToken: 'form-csrf',
      ),
      client: MockClient((request) async {
        if (request.url.path == '/api/tasks/form-options') {
          return http.Response(
            '{"ok":true,"collections":[],"proxies":[],"notifications":[]}',
            200,
          );
        }
        if (request.url.path == '/api/tasks') {
          saveRequests++;
          return http.Response(
            '{"ok":false,"saved":true,"reload_required":true,"task_id":"task-1","msg":"任务已保存，请重新加载调度器。"}',
            503,
          );
        }
        expect(request.url.path, '/api/scheduler/reload');
        expect(request.method, 'POST');
        expect(request.headers['x-csrf-token'], 'form-csrf');
        reloadRequests++;
        return http.Response(
          '{"ok":true,"status":"succeeded","state":{}}',
          200,
        );
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => PanelTaskEditorView(
                      manager: PanelTasksManager(api),
                      onUnauthorized: (_) async {},
                    ),
                  ),
                ),
                child: const Text('打开编辑器'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开编辑器'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), '每日签到');
    await tester.enterText(find.byType(TextFormField).at(2), 'python daily.py');
    await tester.tap(find.text('保存任务'));
    await tester.pumpAndSettle();

    expect(saveRequests, 1);
    expect(find.text('任务已保存，调度器尚未重载。不要重复保存。'), findsOneWidget);
    expect(find.text('重新加载调度器'), findsOneWidget);

    await tester.tap(find.text('重新加载调度器'));
    await tester.pumpAndSettle();

    expect(saveRequests, 1);
    expect(reloadRequests, 1);
    expect(find.text('打开编辑器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
