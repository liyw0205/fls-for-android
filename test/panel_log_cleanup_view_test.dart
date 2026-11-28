import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_log_cleanup_view.dart';
import 'package:fls_for_android/features/panel_records_view.dart';
import 'package:fls_for_android/models/panel_records.dart';
import 'package:fls_for_android/services/panel_log_cleanup_manager.dart';
import 'package:fls_for_android/services/panel_records_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_log_cleanup_fixtures.dart';
import 'panel_test_http.dart';

List<PanelLogFile> selectedFiles([int count = 2]) => [
  for (var i = 0; i < count; i++)
    PanelLogFile(
      filename: 'worker$i.log',
      group: 'Workers',
      sizeBytes: 12,
      modifiedAt: 'now',
      version: 'd' * 64,
    ),
];

PanelLogCleanupManager makeManager(
  Future<http.Response> Function(http.Request) handler,
) => PanelLogCleanupManager(
  cleanupApi(handler),
  panelId: 'https://fls.example',
  panelLabel: '测试面板',
  recovery: PanelLogCleanupRecovery('https://fls.example'),
);

Widget cleanupScreen(
  PanelLogCleanupManager manager, {
  PanelLogCleanupOperation? operation,
  Future<void> Function(Object)? onUnauthorized,
}) => MaterialApp(
  home: PanelLogCleanupView(
    manager: manager,
    files: selectedFiles(),
    operation: operation,
    onUnauthorized: onUnauthorized ?? (_) async {},
  ),
);

Future<void> confirmDeletion(WidgetTester tester) async {
  await tester.tap(find.text('确认清理'));
  await tester.pumpAndSettle();
  expect(find.text('确认清理日志'), findsOneWidget);
  await tester.tap(find.text('确认删除'));
}

void main() {
  testWidgets(
    'previews exact files, confirms and presents individual outcomes on a narrow large-text screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preview = cleanupPreview();
      var submits = 0;
      final manager = makeManager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        if (request.url.path.endsWith('/preview')) return cleanupJson(preview);
        expect(request.url.path, cleanupPath);
        submits++;
        final body = jsonDecode(request.body) as Map;
        return cleanupJson(
          cleanupResult(preview, body['request_id'] as String),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: PanelLogCleanupView(
            manager: manager,
            files: selectedFiles(),
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('确认清理'));
      expect(find.text('worker0.log'), findsOneWidget);
      expect(submits, 0);
      await confirmDeletion(tester);
      await pumpUntilFound(tester, find.text('处理完成'));
      expect(find.textContaining('已删除'), findsWidgets);
      expect(find.textContaining('正在使用'), findsWidgets);
      expect(find.text('确认清理'), findsNothing);
      expect(submits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lost response only queries the original request, missing does not enable deletion, and reopening recovers',
    (tester) async {
      final preview = cleanupPreview();
      var submits = 0;
      var queries = 0;
      var recovered = false;
      final manager = makeManager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        if (request.url.path.endsWith('/preview')) return cleanupJson(preview);
        if (request.url.path == cleanupPath) {
          submits++;
          return cleanupJson({'msg': '连接中断'}, 503);
        }
        queries++;
        return cleanupJson(
          cleanupResult(
            preview,
            request.url.path.split('/').last,
            missing: !recovered,
            statuses: ['unknown', 'unknown'],
          ),
        );
      });
      await tester.pumpWidget(cleanupScreen(manager));
      await pumpUntilFound(tester, find.text('确认清理'));
      await confirmDeletion(tester);
      await pumpUntilFound(tester, find.text('连接中断'));
      final operation = manager.recovery.operations.single;
      await tester.tap(find.text('查询原请求'));
      await pumpUntilFound(tester, find.text('未找到原请求回执，删除结果尚未确认'));
      expect(find.text('确认清理'), findsNothing);
      expect(submits, 1);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      recovered = true;
      await tester.pumpWidget(cleanupScreen(manager, operation: operation));
      await pumpUntilFound(tester, find.text('核对未知目标'));
      expect(queries, 2);
      expect(submits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background hides targets and closes confirmation without sending deletion',
    (tester) async {
      var submits = 0;
      final manager = makeManager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        if (request.url.path.endsWith('/preview')) {
          return cleanupJson(cleanupPreview());
        }
        submits++;
        return cleanupJson({'msg': 'unexpected'}, 500);
      });
      await tester.pumpWidget(cleanupScreen(manager));
      await pumpUntilFound(tester, find.text('确认清理'));
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(find.text('确认删除'), findsNothing);
      expect(find.text('worker0.log'), findsNothing);
      expect(find.text('日志信息已隐藏'), findsOneWidget);
      expect(submits, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('worker0.log'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late old preview 401 cannot expire a replacement manager; current 401 hides content once',
    (tester) async {
      final oldResponse = Completer<http.Response>();
      var oldStarted = false;
      var unauthorized = 0;
      final old = makeManager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        oldStarted = true;
        return oldResponse.future;
      });
      final current = makeManager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        if (request.url.path.endsWith('/preview')) {
          return cleanupJson(cleanupPreview());
        }
        return cleanupJson({'msg': 'expired'}, 401);
      });
      await tester.pumpWidget(
        cleanupScreen(
          old,
          onUnauthorized: (_) async {
            unauthorized++;
          },
        ),
      );
      await pumpUntil(tester, () => oldStarted);
      await tester.pumpWidget(
        cleanupScreen(
          current,
          onUnauthorized: (_) async {
            unauthorized++;
          },
        ),
      );
      await pumpUntilFound(tester, find.text('确认清理'));
      oldResponse.complete(cleanupJson({'msg': 'old expired'}, 401));
      await tester.runAsync(() async {
        await oldResponse.future;
      });
      await tester.pumpAndSettle();
      expect(unauthorized, 0);
      await confirmDeletion(tester);
      await pumpUntilFound(tester, find.text('面板会话不可用，请重新连接'));
      expect(unauthorized, 1);
      expect(find.text('worker0.log'), findsNothing);
      expect(current.recovery.operations, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dedicated unsupported capability disables writes and shows no misleading success',
    (tester) async {
      final paths = <String>[];
      final manager = makeManager((request) async {
        paths.add(request.url.path);
        return cleanupJson({'msg': 'not found'}, 404);
      });
      await tester.pumpWidget(cleanupScreen(manager));
      await pumpUntilFound(tester, find.text('当前面板不支持日志清理'));
      expect(paths, ['$cleanupPath/capabilities']);
      expect(find.text('确认清理'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['file', 'group', 'detail']) {
    testWidgets('records opens $mode cleanup with the selected target', (
      tester,
    ) async {
      final groups = mode == 'group';
      final preview = cleanupPreview(
        groups: groups ? ['Workers'] : const [],
        count: groups ? 2 : 1,
      );
      final bodies = <Map<String, dynamic>>[];
      final api = cleanupApi((request) async {
        if (request.url.path == '/api/history') {
          return cleanupJson({
            'ok': true,
            'items': [],
            'page': 1,
            'pages': 1,
            'total': 0,
          });
        }
        if (request.url.path == '/api/logs') {
          return cleanupJson({
            'ok': true,
            'items': [
              for (var i = 0; i < 2; i++)
                {
                  'filename': 'worker$i.log',
                  'group': 'Workers',
                  'size_bytes': 12,
                  'modified_at': 'now',
                  'version': 'd' * 64,
                  'busy': false,
                },
            ],
            'page': 1,
            'pages': 1,
            'total': 2,
          });
        }
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        if (request.url.path == '/api/logfile/worker0.log') {
          return cleanupJson({
            'ok': true,
            'filename': 'worker0.log',
            'lines': 1,
            'log': 'log text',
          });
        }
        if (request.url.path.endsWith('/preview')) {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return cleanupJson(preview);
        }
        throw TestFailure('Unexpected request ${request.url}');
      });
      addTearDown(api.close);
      final manager = PanelLogCleanupManager(
        api,
        panelId: 'https://fls.example',
        panelLabel: '测试面板',
        recovery: PanelLogCleanupRecovery('https://fls.example'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PanelRecordsView(
              manager: PanelRecordsManager(api),
              cleanupManager: manager,
              onUnauthorized: (_) async {},
            ),
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('暂无运行历史'));
      await tester.tap(find.text('日志文件'));
      await pumpUntilFound(tester, find.text('worker0.log'));
      if (mode == 'detail') {
        await tester.tap(find.text('worker0.log'));
        await pumpUntilFound(tester, find.text('log text'));
        await tester.tap(find.byTooltip('删除日志文件'));
      } else {
        await tester.tap(find.byTooltip('选择清理日志'));
        await pumpUntilFound(tester, find.text('分组'));
        if (groups) {
          await tester.tap(find.text('分组'));
          await tester.pump();
        }
        await tester.tap(find.text('worker0.log'));
        await tester.pump();
        await tester.tap(find.byTooltip('预检查清理日志'));
      }
      await pumpUntilFound(tester, find.text('确认清理'));
      expect(
        bodies.single,
        groups
            ? {
                'groups': ['Workers'],
              }
            : {
                'files': [
                  {'filename': 'worker0.log', 'version': 'd' * 64},
                ],
              },
      );
      expect(tester.takeException(), isNull);
    });
  }
}
