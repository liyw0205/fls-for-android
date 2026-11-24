import 'dart:convert';

import 'panel_test_http.dart';

import 'package:fls_for_android/features/panel_tasks_view.dart';
import 'package:fls_for_android/models/panel_server.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const server = PanelServer(name: 'Home FLS', url: 'https://fls.example');
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=signed-session',
    csrfToken: 'csrf-session',
  );
  const tasks = [
    {
      'id': 'daily',
      'name': '每日签到',
      'command': 'python /scripts/daily.py',
      'cron': '0 8 * * *',
      'enabled': true,
      'running': false,
      'run_count': 3,
    },
    {
      'id': 'watcher',
      'name': '运行中的监控',
      'command': 'python /scripts/watch.py',
      'cron': '',
      'enabled': false,
      'running': true,
      'run_count': 1,
      'pid': 42,
    },
  ];

  testWidgets('loads a saved session and filters real task summaries', (
    tester,
  ) async {
    final credentials = _MemoryCredentials()..value = session;
    final client = panelMockClient((request) async {
      expect(request.headers['cookie'], session.cookie);
      expect(request.headers['x-token'], isNull);
      final dashboard = _dashboardResponse(request);
      if (dashboard != null) return dashboard;
      return utf8Response(jsonEncode(tasks), 200);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PanelTasksView(
          server: server,
          credentialStore: credentials,
          client: client,
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('2026-11-25 12:00:00'));

    expect(find.text('2026-11-25 12:00:00'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('1 个任务已加入调度'), findsOneWidget);
    await tester.tap(find.text('任务'));
    await pumpUntilFound(tester, find.text('每日签到'));
    expect(find.text('每日签到'), findsOneWidget);
    expect(find.text('运行中的监控'), findsOneWidget);
    await tester.tap(find.text('运行中'));
    await pumpUntil(tester, () => find.text('每日签到').evaluate().isEmpty);
    expect(find.text('运行中的监控'), findsOneWidget);
    expect(find.text('每日签到'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stores only the verified server session after sign-in', (
    tester,
  ) async {
    final credentials = _MemoryCredentials();
    var statusRequested = false;
    final client = panelMockClient((request) async {
      if (request.url.path == '/api/auth/session') {
        expect(request.headers['x-token'], isNull);
        expect(jsonDecode(request.body), {
          'token': 'correct-token',
          'remember': true,
        });
        return utf8Response(
          '{"ok":true,"authenticated":true,"requires_verification":false,"csrf_token":"csrf-new"}',
          200,
          headers: {'set-cookie': 'fls_native_session=new-session; HttpOnly'},
        );
      }
      final dashboard = _dashboardResponse(request);
      if (dashboard != null) return dashboard;
      statusRequested = true;
      expect(request.headers['cookie'], 'fls_native_session=new-session');
      expect(request.headers['x-token'], isNull);
      return utf8Response(jsonEncode(tasks), 200);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PanelTasksView(
          server: server,
          credentialStore: credentials,
          client: client,
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('连接面板'));
    expect(find.text('连接面板'), findsOneWidget);

    await tester.tap(find.text('连接面板'));
    await pumpUntilFound(tester, find.widgetWithText(FilledButton, '连接'));
    await tester.enterText(find.byType(TextField), 'correct-token');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await pumpUntilFound(tester, find.text('已完成'));

    expect(statusRequested, isTrue);
    expect(credentials.value?.cookie, 'fls_native_session=new-session');
    expect(credentials.value?.csrfToken, 'csrf-new');
    expect(credentials.value.toString(), isNot(contains('correct-token')));
    await tester.tap(find.text('任务'));
    await pumpUntilFound(tester, find.text('每日签到'));
    expect(find.text('每日签到'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('requires second factor before saving credentials', (
    tester,
  ) async {
    final credentials = _MemoryCredentials();
    final client = panelMockClient((request) async {
      if (request.url.path.endsWith('/api/auth/session')) {
        return utf8Response(
          '{"ok":true,"authenticated":false,"requires_verification":true,"verification_type":"totp","csrf_token":"csrf-pending"}',
          202,
          headers: {
            'set-cookie': 'fls_native_session=pending-session; HttpOnly',
          },
        );
      }
      if (request.url.path.endsWith('/api/auth/verify')) {
        expect(request.headers['cookie'], 'fls_native_session=pending-session');
        expect(request.headers['x-csrf-token'], 'csrf-pending');
        expect(jsonDecode(request.body), {'code': '123456'});
        return utf8Response(
          '{"ok":true,"authenticated":true,"csrf_token":"csrf-verified"}',
          200,
        );
      }
      final dashboard = _dashboardResponse(request);
      if (dashboard != null) return dashboard;
      expect(request.url.path, '/api/status');
      return utf8Response(jsonEncode(tasks), 200);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PanelTasksView(
          server: server,
          credentialStore: credentials,
          client: client,
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('连接面板'));
    await tester.tap(find.text('连接面板'));
    await pumpUntilFound(tester, find.widgetWithText(FilledButton, '连接'));
    await tester.enterText(find.byType(TextField), 'correct-token');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await pumpUntilFound(tester, find.text('输入身份验证器代码'));

    expect(find.text('输入身份验证器代码'), findsOneWidget);
    expect(credentials.value, isNull);
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '验证'));
    await pumpUntilFound(tester, find.text('已完成'));

    expect(credentials.value?.cookie, 'fls_native_session=pending-session');
    expect(credentials.value?.csrfToken, 'csrf-verified');
    await tester.tap(find.text('任务'));
    await pumpUntilFound(tester, find.text('每日签到'));
    expect(find.text('每日签到'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirms task runs with a session and refreshes server state', (
    tester,
  ) async {
    final credentials = _MemoryCredentials()..value = session;
    var postCount = 0;
    final client = panelMockClient((request) async {
      expect(request.headers['cookie'], session.cookie);
      final dashboard = _dashboardResponse(request);
      if (dashboard != null) return dashboard;
      if (request.method == 'POST') {
        postCount++;
        expect(request.url.path, '/api/task/action/run/daily');
        expect(request.headers['x-csrf-token'], session.csrfToken);
        expect(request.headers['x-token'], isNull);
        return utf8Response('{"ok":true,"msg":"已提交"}', 200);
      }
      return utf8Response(jsonEncode(tasks), 200);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PanelTasksView(
          server: server,
          credentialStore: credentials,
          client: client,
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('2026-11-25 12:00:00'));
    await tester.tap(find.text('任务'));
    await pumpUntilFound(tester, find.text('每日签到'));
    await tester.tap(find.byTooltip('任务操作').first);
    await pumpUntilFound(tester, find.text('立即运行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即运行'));
    await pumpUntilFound(tester, find.text('确认'));
    await tester.tap(find.text('确认'));
    await pumpUntil(tester, () => postCount == 1);

    expect(postCount, 1);
    expect(find.text('每日签到'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens native task details from the task list', (tester) async {
    final credentials = _MemoryCredentials()..value = session;
    final client = MockClient((request) async {
      final dashboard = _dashboardResponse(request);
      if (dashboard != null) return dashboard;
      if (request.url.path == '/api/status') {
        return utf8Response(jsonEncode(tasks), 200);
      }
      if (request.url.path == '/api/task/daily') {
        return utf8Response(
          jsonEncode({
            'ok': true,
            'task': {
              'id': 'daily',
              'name': '每日签到',
              'command': 'python /scripts/daily.py',
              'enabled': true,
              'env': {},
              'notify': {'mode': 'default', 'ids': []},
              'random_delay': {'mode': 'none', 'seconds': 0},
              'retry': {'attempts': 0, 'interval_seconds': 60},
            },
            'runtime': {'running': false, 'status': 'stopped'},
            'history': [],
          }),
          200,
        );
      }
      if (request.url.path == '/api/task/daily/log') {
        return utf8Response(
          '{"ok":true,"task_id":"daily","running":false,"lines":200,"log":"task log"}',
          200,
        );
      }
      return utf8Response('{}', 404);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PanelTasksView(
          server: server,
          credentialStore: credentials,
          client: client,
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('2026-11-25 12:00:00'));
    await tester.tap(find.text('任务'));
    await pumpUntilFound(tester, find.text('每日签到'));
    await tester.tap(find.text('每日签到'));
    await pumpUntilFound(tester, find.text('python /scripts/daily.py'));
    await tester.scrollUntilVisible(
      find.text('暂无运行记录'),
      240,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );

    expect(find.text('python /scripts/daily.py'), findsOneWidget);
    expect(find.text('暂无运行记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

http.Response? _dashboardResponse(http.Request request) {
  switch (request.url.path) {
    case '/api/dashboard/runtime':
      return utf8Response(
        jsonEncode({
          'ok': true,
          'current_time': '2026-11-25 12:00:00',
          'timezone': 'UTC+8',
          'panel_uptime': '1 小时',
          'system_cpu_percent': '12.0%',
          'panel_cpu_current': '1.0%',
          'panel_cpu_peak': '5.0%',
        }),
        200,
      );
    case '/api/scheduler/status':
      return utf8Response(
        '{"ok":true,"status":"succeeded","status_label":"已完成","task_count":2,"scheduled_count":1,"error":""}',
        200,
      );
    case '/api/scheduler/jobs':
      return utf8Response(
        '{"ok":true,"jobs":[{"id":"daily","next_run_time":"2026-11-26 08:00:00","trigger":"cron[hour=8]"}]}',
        200,
      );
  }
  return null;
}

class _MemoryCredentials implements PanelCredentialStore {
  PanelSessionCredentials? value;

  @override
  Future<void> delete(String panelUrl) async => value = null;

  @override
  Future<PanelSessionCredentials?> read(String panelUrl) async => value;

  @override
  Future<void> write(
    String panelUrl,
    PanelSessionCredentials credentials,
  ) async => value = credentials;
}
