import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_online_script_admin_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_online_scripts_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'panel_test_http.dart';

const requestId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const taskId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const digest =
    'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

Map<String, dynamic> record({
  String status = '失败',
  bool active = false,
  int total = 0,
  List<Map<String, dynamic>> failures = const [],
}) => {
  'request_id': requestId,
  'status': status,
  'running': false,
  'active': active,
  'proxy_id': '',
  'task_link_failure_count': total,
  'task_link_failure_digest': digest,
  'task_link_failures': failures,
};

http.Response response(Object data, [int status = 200]) =>
    utf8Response(jsonEncode(data), status);

PanelApiClient client(Future<http.Response?> Function(http.Request) handler) =>
    PanelApiClient(
      baseUrl: 'https://fls.example',
      client: MockClient((request) async {
        final custom = await handler(request);
        if (custom != null) return custom;
        switch (request.url.path) {
          case '/api/online-scripts/refresh-options':
            return response({'ok': true, 'proxies': []});
          case '/api/online-scripts/refresh-history':
            return response({
              'ok': true,
              'items': [record()],
            });
          case '/api/online-scripts/source':
            return response({
              'ok': true,
              'json_text': '[]',
              'cache_revision': digest,
            });
          case '/api/online-scripts/import-tasks-history':
          case '/api/online-scripts/task-link-history':
            return response({'ok': true, 'items': []});
        }
        if (request.url.path.contains('/refresh-log/')) {
          return response({
            'request_id': request.url.path.split('/').last,
            'log': 'refresh output',
          });
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );

Future<void> openRefresh(
  WidgetTester tester,
  PanelApiClient api, {
  Future<void> Function(Object)? onUnauthorized,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PanelOnlineScriptAdminView(
        manager: PanelOnlineScriptsManager(api),
        onUnauthorized: onUnauthorized ?? (_) async {},
      ),
    ),
  );
  await pumpUntilFound(tester, find.text('失败'));
  await tester.tap(find.text('失败'));
  await pumpUntilFound(tester, find.text('脚本源同步状态'));
  await pumpUntil(
    tester,
    () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
  await tester.pump(const Duration(milliseconds: 400));
}

Finder button(String text) => find.ancestor(
  of: find.text(text),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
);

void main() {
  testWidgets('active cleanup disables retry even after terminal receipt', (
    tester,
  ) async {
    var writes = 0;
    final api = client((request) async {
      if (request.method == 'POST') writes++;
      if (request.url.path == '/api/online-scripts/refresh-status/$requestId') {
        return response(record(active: true));
      }
      return null;
    });
    addTearDown(api.close);
    await openRefresh(tester, api);
    expect(tester.widget<ButtonStyleButton>(button('重试同步')).onPressed, isNull);
    expect(writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed state read preserves receipt and disables writes', (
    tester,
  ) async {
    var reads = 0;
    final api = client((request) async {
      if (request.url.path == '/api/online-scripts/refresh-status/$requestId') {
        return ++reads == 1
            ? response(record())
            : response({'ok': false, 'msg': 'storage busy'}, 503);
      }
      return null;
    });
    addTearDown(api.close);
    await openRefresh(tester, api);
    expect(
      tester.widget<ButtonStyleButton>(button('重试同步')).onPressed,
      isNotNull,
    );
    await tester.tap(find.byTooltip('刷新状态'));
    await pumpUntilFound(tester, find.text('查询原请求'));
    expect(find.text('失败'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(button('重试同步')).onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('confirmation conflict only queries original request', (
    tester,
  ) async {
    var reads = 0, writes = 0;
    final api = client((request) async {
      if (request.url.path == '/api/online-scripts/refresh-status/$requestId') {
        return response(record(status: ++reads == 1 ? '结果未知' : '已确认发布'));
      }
      if (request.method == 'POST') {
        writes++;
        expect(
          request.url.path,
          '/api/online-scripts/refresh-confirm/$requestId',
        );
        return response({
          'ok': false,
          'msg': 'another worker is confirming',
        }, 409);
      }
      return null;
    });
    addTearDown(api.close);
    await openRefresh(tester, api);
    await tester.tap(find.text('核对结果'));
    await pumpUntilFound(tester, find.text('已确认发布'));
    expect(reads, 2);
    expect(writes, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'lost retry response opens the saved child ID without another POST',
    (tester) async {
      String? childId;
      var writes = 0, childReads = 0;
      final api = client((request) async {
        if (request.url.path ==
            '/api/online-scripts/refresh-retry/$requestId') {
          writes++;
          childId = (jsonDecode(request.body) as Map)['request_id'] as String;
          return response({'ok': false, 'msg': 'response lost'}, 503);
        }
        if (request.url.path.contains('/refresh-status/')) {
          final id = request.url.path.split('/').last;
          if (id == childId) childReads++;
          return response({...record(), 'request_id': id});
        }
        return null;
      });
      addTearDown(api.close);
      await openRefresh(tester, api);
      await tester.tap(find.text('重试同步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('明确重试'));
      await pumpUntil(tester, () => childReads == 1);
      await pumpUntilFound(tester, find.text('请求：$childId'));
      expect(writes, 1);
      expect(childId, isNot(requestId));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('failure pages load beyond the inline receipt', (tester) async {
    var pageReads = 0;
    final api = client((request) async {
      if (request.url.path == '/api/online-scripts/refresh-status/$requestId') {
        return response(
          record(
            total: 101,
            failures: List.generate(
              100,
              (index) => {
                'script_id': '$index',
                'name': 'Failure $index',
                'task_link_request_id': taskId,
              },
            ),
          ),
        );
      }
      if (request.url.path ==
          '/api/online-scripts/refresh-task-link-failures/$requestId') {
        pageReads++;
        expect(request.url.queryParameters['offset'], '100');
        return response({
          'ok': true,
          'request_id': requestId,
          'offset': 100,
          'total': 101,
          'digest': digest,
          'has_more': false,
          'items': [
            {
              'script_id': 'last',
              'name': 'Last failure',
              'task_link_request_id': taskId,
            },
          ],
        });
      }
      return null;
    });
    addTearDown(api.close);
    await openRefresh(tester, api);
    await tester.scrollUntilVisible(
      find.byTooltip('下一页失败项'),
      500,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byTooltip('下一页失败项'));
    await pumpUntilFound(tester, find.text('Last failure'));
    expect(find.text('101-101 / 101'), findsOneWidget);
    expect(pageReads, 1);
    expect(
      tester.widget<IconButton>(find.byTooltip('下一页失败项')).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('lost task-link response queries the original failure ID', (
    tester,
  ) async {
    var writes = 0, taskReads = 0;
    final api = client((request) async {
      if (request.url.path == '/api/online-scripts/refresh-status/$requestId') {
        return response(
          record(
            total: 1,
            failures: [
              {
                'script_id': 'demo',
                'name': 'Demo',
                'task_link_request_id': taskId,
              },
            ],
          ),
        );
      }
      if (request.method == 'POST') {
        writes++;
        expect(
          request.url.path,
          '/api/online-scripts/refresh-task-link/$requestId/task-link/demo',
        );
        expect(jsonDecode(request.body)['request_id'], taskId);
        return response({'ok': false, 'msg': 'response lost'}, 503);
      }
      if (request.url.path == '/api/online-scripts/task-link-status/$taskId') {
        taskReads++;
        return response({
          'ok': true,
          'request_id': taskId,
          'state': 'completed',
          'active': false,
          'script_id': 'demo',
          'retry_allowed': false,
        });
      }
      return null;
    });
    addTearDown(api.close);
    await openRefresh(tester, api);
    await tester.tap(find.byTooltip('重试此任务源'));
    await pumpUntilFound(tester, find.text('completed'));
    expect(writes, 1);
    expect(taskReads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a late unauthorized log cannot affect a disposed refresh page', (
    tester,
  ) async {
    var unauthorized = 0, logReads = 0;
    final release = Completer<void>();
    final api = client((request) async {
      if (request.url.path == '/api/online-scripts/refresh-status/$requestId') {
        return response(record());
      }
      if (request.url.path.contains('/refresh-log/')) {
        logReads++;
        await release.future;
        return response({'ok': false, 'msg': 'expired'}, 401);
      }
      return null;
    });
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelOnlineScriptAdminView(
          manager: PanelOnlineScriptsManager(api),
          onUnauthorized: (_) async {
            unauthorized++;
          },
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('失败'));
    await tester.tap(find.text('失败'));
    await pumpUntil(tester, () => logReads == 1);
    await tester.pumpWidget(const SizedBox.shrink());
    release.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(unauthorized, 0);
  });
}
