import 'dart:convert';

import 'package:fls_for_android/features/panel_task_detail_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_tasks_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('renders task details and keeps environment values hidden', (
    tester,
  ) async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=detail-session',
        csrfToken: 'detail-csrf',
      ),
      client: MockClient((request) async {
        if (request.url.path == '/api/task/daily/log') {
          return http.Response(
            '{"ok":true,"task_id":"daily","running":false,"lines":200,"log":"log line"}',
            200,
          );
        }
        expect(request.url.path, '/api/task/daily');
        return http.Response(
          jsonEncode({
            'ok': true,
            'task': {
              'id': 'daily',
              'name': '每日任务',
              'remark': '主账号',
              'command': 'python daily.py',
              'cron': '0 8 * * *',
              'enabled': true,
              'run_count': 2,
              'env': {'API_KEY': 'very-secret'},
              'notify': {'mode': 'default', 'ids': []},
              'random_delay': {'mode': 'custom', 'seconds': 5},
              'retry': {'attempts': 2, 'interval_seconds': 30},
            },
            'runtime': {'running': false, 'status': 'stopped'},
            'history': [
              {
                'id': 'history-1',
                'start_at': '2026-11-25 08:00:00',
                'duration_seconds': 2,
                'status': 'success',
                'message': '完成',
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelTaskDetailView(
          manager: PanelTasksManager(api),
          taskId: 'daily',
          taskName: '每日任务',
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('主账号'), findsOneWidget);
    expect(find.text('python daily.py'), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('已隐藏'), findsOneWidget);
    expect(find.text('very-secret'), findsNothing);

    await tester.tap(find.byTooltip('显示变量值'));
    await tester.pumpAndSettle();
    expect(find.text('very-secret'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
