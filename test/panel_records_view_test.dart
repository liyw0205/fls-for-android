import 'dart:convert';

import 'panel_test_http.dart';

import 'package:fls_for_android/features/panel_records_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_records_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

void main() {
  testWidgets('filters and paginates task history, then exports CSV', (
    tester,
  ) async {
    final requests = <Uri>[];
    List<int>? savedBytes;
    String? savedFilename;
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      client: MockClient((request) async {
        requests.add(request.url);
        final page = request.url.queryParameters['page'];
        final status = request.url.queryParameters['status'];
        final item = status == 'failed'
            ? '{"id":"h-failed","task_id":"t1","task_name":"失败任务","command":"python task.py","status":"failed","start_at":"today","duration_seconds":3,"message":"failed"}'
            : '{"id":"h-$page","task_id":"t1","task_name":"每日任务$page","command":"python task.py","status":"success","start_at":"today","duration_seconds":3,"message":"ok"}';
        if (request.url.path == '/api/history/export') {
          return utf8Response('csv data', 200);
        }
        return utf8Response(
          jsonEncode({
            'ok': true,
            'items': [jsonDecode(item)],
            'page': int.parse(page!),
            'pages': status == 'failed' ? 1 : 2,
            'total': status == 'failed' ? 1 : 31,
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelRecordsView(
            manager: PanelRecordsManager(api),
            onUnauthorized: (_) async {},
            saveFile: ({required bytes, required filename}) async {
              savedBytes = bytes;
              savedFilename = filename;
              return true;
            },
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('每日任务1'));

    await tester.tap(find.byTooltip('下一页'));
    await pumpUntilFound(tester, find.text('每日任务2'));
    expect(requests.last.queryParameters['page'], '2');

    await tester.tap(find.text('全部状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('失败').last);
    await pumpUntilFound(tester, find.text('失败任务'));
    expect(requests.last.queryParameters['status'], 'failed');

    await tester.tap(find.byTooltip('导出筛选结果 CSV'));
    await pumpUntilFound(tester, find.text('历史记录已导出'));
    expect(savedBytes, utf8.encode('csv data'));
    expect(savedFilename, 'fls-history-export.csv');
    expect(requests.any((uri) => uri.path == '/api/history/export'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reads, searches, and downloads a selected log file', (
    tester,
  ) async {
    final requests = <Uri>[];
    List<int>? savedBytes;
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      client: MockClient((request) async {
        requests.add(request.url);
        return switch (request.url.path) {
          '/api/history' => utf8Response(
            '{"ok":true,"items":[],"page":1,"pages":1,"total":0}',
            200,
          ),
          '/api/logs' => utf8Response(
            '{"ok":true,"items":[{"filename":"worker.log","group":"Worker","size_bytes":42,"modified_at":"now"}],"page":1,"pages":1,"total":1}',
            200,
          ),
          '/api/logfile/worker.log' => utf8Response(
            '{"ok":true,"filename":"worker.log","lines":2,"log":"INFO ready\\nWARNING retry"}',
            200,
          ),
          '/api/logfile/worker.log/download' => utf8Response(
            'INFO ready\nWARNING retry',
            200,
          ),
          _ => throw TestFailure('Unexpected request ${request.url}'),
        };
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelRecordsView(
            manager: PanelRecordsManager(api),
            onUnauthorized: (_) async {},
            saveFile: ({required bytes, required filename}) async {
              savedBytes = bytes;
              return true;
            },
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('暂无运行历史'));
    await tester.tap(find.text('日志文件'));
    await pumpUntilFound(tester, find.text('worker.log'));
    await tester.tap(find.text('worker.log'));
    await pumpUntilFound(tester, find.textContaining('INFO ready'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'warning');
    await tester.pump();
    expect(find.textContaining('WARNING retry'), findsOneWidget);
    expect(find.textContaining('INFO ready'), findsNothing);

    await tester.tap(find.text('保存日志文件'));
    await pumpUntilFound(tester, find.text('日志文件已保存'));
    expect(savedBytes, utf8.encode('INFO ready\nWARNING retry'));
    expect(
      requests.any((uri) => uri.path == '/api/logfile/worker.log/download'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows an empty log state and a retryable API error', (
    tester,
  ) async {
    var failLogs = true;
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      client: MockClient((request) async {
        if (request.url.path == '/api/history') {
          return utf8Response(
            '{"ok":true,"items":[],"page":1,"pages":1,"total":0}',
            200,
          );
        }
        return failLogs
            ? utf8Response('{"ok":false,"msg":"日志暂不可用"}', 503)
            : utf8Response(
                '{"ok":true,"items":[],"page":1,"pages":1,"total":0}',
                200,
              );
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelRecordsView(
            manager: PanelRecordsManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('暂无运行历史'));
    await tester.tap(find.text('日志文件'));
    await pumpUntilFound(tester, find.text('日志暂不可用'));

    failLogs = false;
    await tester.tap(find.text('重试'));
    await pumpUntilFound(tester, find.text('暂无日志文件'));
    expect(tester.takeException(), isNull);
  });
}
