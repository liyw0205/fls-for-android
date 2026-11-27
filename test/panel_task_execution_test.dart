import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_task_detail_view.dart';
import 'package:fls_for_android/models/panel_task_detail.dart';
import 'package:fls_for_android/models/panel_task_summary.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_tasks_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

Map<String, Object?> detail(String status, {String id = 'a'}) => {
  'ok': true,
  'task': {
    'id': id,
    'name': 'Task $id',
    'command': 'task $id.py',
    'enabled': true,
    'env': {'TOKEN': 'private-value'},
  },
  'runtime': {
    'status': status,
    'running': {'running', 'retry_wait', 'stopping'}.contains(status),
    'active': {'running', 'retry_wait', 'stopping'}.contains(status),
    'stop_requested': status == 'stopping',
  },
  'history': <Object>[],
};

PanelApiClient apiFor(Future<http.Response> Function(http.Request) handler) =>
    PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=task-session',
        csrfToken: 'task-csrf',
      ),
      client: panelMockClient(handler),
    );

http.Response logResponse(String text, {String id = 'a'}) =>
    utf8Response(jsonEncode({'ok': true, 'task_id': id, 'log': text}), 200);

class _ObservedTasksManager extends PanelTasksManager {
  _ObservedTasksManager(super.api);

  bool detailSettled = false;
  Object? detailError;

  @override
  Future<PanelTaskDetail> fetchTaskDetail(String taskId) async {
    try {
      return await super.fetchTaskDetail(taskId);
    } catch (error) {
      detailError = error;
      rethrow;
    } finally {
      detailSettled = true;
    }
  }
}

Widget page(
  PanelTasksManager manager,
  Future<void> Function(Object) unauthorized, {
  String id = 'a',
}) => MaterialApp(
  home: PanelTaskDetailView(
    manager: manager,
    taskId: id,
    taskName: 'Task $id',
    onUnauthorized: unauthorized,
  ),
);

void main() {
  test('execution phases and legacy runtime remain distinguishable', () {
    for (final entry in {
      'retry_wait': '等待重试',
      'stopping': '正在停止',
      'unknown': '结果未知',
      'success': '已完成',
    }.entries) {
      expect(
        PanelTaskDetail.fromJson(detail(entry.key)).executionLabel,
        entry.value,
      );
    }
    final legacy = detail('running');
    legacy['runtime'] = {'running': true};
    expect(PanelTaskDetail.fromJson(legacy).executionLabel, '运行中');
    final invalid = detail('running');
    invalid['runtime'] = {'running': true, 'active': 'false'};
    expect(() => PanelTaskDetail.fromJson(invalid), throwsFormatException);
    expect(
      PanelTaskSummary.fromJson({
        'id': 'a',
        'name': 'Task a',
        'running': true,
        'execution_status': 'retry_wait',
      }).executionLabel,
      '等待重试',
    );
  });

  testWidgets('polls retry and stop phases with GET and stops after cleanup', (
    tester,
  ) async {
    var reads = 0;
    final api = apiFor((request) async {
      expect(request.method, 'GET');
      if (request.url.path.endsWith('/log')) return logResponse('output');
      final states = ['retry_wait', 'stopping', 'stopped'];
      return utf8Response(jsonEncode(detail(states[reads++])), 200);
    });
    addTearDown(api.close);
    await tester.pumpWidget(page(PanelTasksManager(api), (_) async {}));
    await pumpUntilFound(tester, find.text('等待重试'));
    await tester.pump(const Duration(seconds: 2));
    await pumpUntilFound(tester, find.text('正在停止'));
    await tester.pump(const Duration(seconds: 2));
    await pumpUntilFound(tester, find.text('已停止'));
    await tester.pump(const Duration(seconds: 5));
    expect(reads, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late old panel 401 cannot replace the new task', (
    tester,
  ) async {
    final oldResponse = Completer<http.Response>();
    var unauthorized = 0;
    var oldReads = 0;
    final oldApi = apiFor((request) {
      oldReads++;
      return oldResponse.future;
    });
    final oldManager = _ObservedTasksManager(oldApi);
    final newApi = apiFor(
      (request) async => request.url.path.endsWith('/log')
          ? logResponse('new output', id: 'b')
          : utf8Response(jsonEncode(detail('stopped', id: 'b')), 200),
    );
    addTearDown(oldApi.close);
    addTearDown(newApi.close);
    Future<void> expired(Object _) async => unauthorized++;
    await tester.pumpWidget(page(oldManager, expired));
    await pumpUntil(tester, () => oldReads == 1);
    await tester.pumpWidget(page(PanelTasksManager(newApi), expired, id: 'b'));
    await pumpUntilFound(tester, find.text('已停止'));
    await pumpUntil(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    oldResponse.complete(utf8Response('{"ok":false,"msg":"expired"}', 401));
    await pumpUntil(tester, () => oldManager.detailSettled);
    await tester.pumpAndSettle();
    expect(oldManager.detailError, isA<PanelApiException>());
    expect((oldManager.detailError as PanelApiException).statusCode, 401);
    expect(find.text('task b.py'), findsOneWidget);
    expect(find.text('task a.py'), findsNothing);
    expect(unauthorized, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current polling 401 hides content and stops further reads', (
    tester,
  ) async {
    var reads = 0;
    var unauthorized = 0;
    final api = apiFor((request) async {
      if (request.url.path.endsWith('/log')) return logResponse('old output');
      if (reads++ == 0) {
        return utf8Response(jsonEncode(detail('running')), 200);
      }
      return utf8Response('{"ok":false,"msg":"expired"}', 401);
    });
    addTearDown(api.close);
    await tester.pumpWidget(
      page(PanelTasksManager(api), (_) async {
        unauthorized++;
      }),
    );
    await pumpUntilFound(tester, find.text('运行中'));
    expect(find.text('task a.py'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await pumpUntilFound(tester, find.text('登录已失效'));
    expect(find.text('task a.py'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(unauthorized, 1);
    expect(reads, 2);
  });

  testWidgets('background hides content and discards a late log response', (
    tester,
  ) async {
    final lateLog = Completer<http.Response>();
    var logs = 0;
    final api = apiFor((request) async {
      if (request.url.path.endsWith('/log')) {
        if (logs++ == 0) return lateLog.future;
        return logResponse('fresh output');
      }
      return utf8Response(jsonEncode(detail('running')), 200);
    });
    addTearDown(api.close);
    await tester.pumpWidget(page(PanelTasksManager(api), (_) async {}));
    await pumpUntilFound(tester, find.text('运行中'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text('task a.py'), findsNothing);
    lateLog.complete(logResponse('late private output'));
    await tester.pump();
    expect(find.text('late private output'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntilFound(tester, find.text('运行中'));
    expect(find.text('task a.py'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });
}
