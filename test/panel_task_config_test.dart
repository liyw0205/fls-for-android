import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_task_config_view.dart';
import 'package:fls_for_android/models/panel_task_config.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_tasks_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

const configPath = '/api/tasks/daily/config-file';

Map<String, Object?> configFile({
  String content = 'key: original\n',
  String taskId = 'daily',
  String? revision,
  String path = 'conf/app.yml',
  bool exists = true,
}) => {
  'ok': true,
  'file': {
    'task_id': taskId,
    'path': path,
    'revision': revision ?? 'a' * 64,
    'content': content,
    'exists': exists,
    'max_bytes': 1024 * 1024,
  },
};

Map<String, Object?> receipt(String requestId, String status) => {
  'ok': true,
  'task_id': 'daily',
  'request_id': requestId,
  'path': status == 'missing' ? '' : 'conf/app.yml',
  'status': status,
  'saved': status == 'saved'
      ? true
      : status == 'not_saved'
      ? false
      : null,
};

http.Response jsonResponse(Object value, [int status = 200]) =>
    utf8Response(jsonEncode(value), status);

PanelApiClient apiFor(
  Future<http.Response> Function(http.Request request) handler,
) => PanelApiClient(
  baseUrl: 'https://fls.example',
  credentials: const PanelSessionCredentials(
    cookie: 'fls_native_session=config',
    csrfToken: 'config-csrf',
  ),
  client: panelMockClient(handler),
);

Widget editor(
  PanelTasksManager manager, {
  Future<void> Function(Object)? onUnauthorized,
  Key? key,
}) => MaterialApp(
  home: PanelTaskConfigView(
    key: key,
    manager: manager,
    taskId: 'daily',
    taskName: '每日任务',
    onUnauthorized: onUnauthorized ?? (_) async {},
  ),
);

String draft(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  test(
    'binds config reads, writes and read-only receipts to the task and original request',
    () async {
      final requests = <http.Request>[];
      final api = apiFor((request) async {
        requests.add(request);
        expect(request.headers['cookie'], 'fls_native_session=config');
        if (request.method == 'POST') {
          expect(request.headers['x-csrf-token'], 'config-csrf');
          expect(request.url.path, configPath);
          expect(jsonDecode(request.body), {
            'request_id': 'b' * 32,
            'path': 'conf/app.yml',
            'expected_revision': 'a' * 64,
            'content': 'exact\r\n',
          });
          return jsonResponse(receipt('b' * 32, 'saved'));
        }
        if (request.url.path.contains('/requests/')) {
          return jsonResponse(receipt('b' * 32, 'saved'));
        }
        return jsonResponse(configFile());
      });
      addTearDown(api.close);
      final manager = PanelTasksManager(api);
      final file = await manager.fetchTaskConfig('daily');
      final result = await manager.saveTaskConfig(
        file,
        content: 'exact\r\n',
        requestId: 'b' * 32,
      );
      expect(result.status, 'saved');
      expect(
        (await manager.fetchTaskConfigRequest('daily', 'b' * 32)).status,
        'saved',
      );
      expect(requests.map((request) => request.method), ['GET', 'POST', 'GET']);
      expect(
        manager.configRecoveryFor('daily'),
        same(manager.configRecoveryFor('daily')),
      );
      expect(
        manager.configRecoveryFor('other'),
        isNot(same(manager.configRecoveryFor('daily'))),
      );
    },
  );

  test(
    'rejects wrong task, mismatched request and contradictory save results',
    () async {
      final responses = [
        configFile(taskId: 'other'),
        {...receipt('a' * 32, 'saved'), 'request_id': 'b' * 32},
        {...receipt('a' * 32, 'saved'), 'saved': null},
        {...receipt('a' * 32, 'unknown'), 'saved': false},
      ];
      final api = apiFor((_) async => jsonResponse(responses.removeAt(0)));
      addTearDown(api.close);
      final manager = PanelTasksManager(api);
      await expectLater(
        manager.fetchTaskConfig('daily'),
        throwsA(isA<PanelApiException>()),
      );
      for (var i = 0; i < 3; i++) {
        await expectLater(
          manager.fetchTaskConfigRequest('daily', 'a' * 32),
          throwsA(isA<PanelApiException>()),
        );
      }
      expect(
        () => PanelTaskConfigSnapshot.fromJson({
          ...(configFile()['file'] as Map<String, Object?>),
          'content': '中' * 4,
          'max_bytes': 10,
        }),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'creates a missing config with exact draft and refreshes after confirmed save',
    (tester) async {
      var saved = false;
      var posts = 0;
      final api = apiFor((request) async {
        if (request.method == 'POST') {
          posts++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['path'], 'conf/app.yml');
          expect(body['content'], 'secret: value\r\n');
          saved = true;
          return jsonResponse(receipt(body['request_id'] as String, 'saved'));
        }
        return jsonResponse(
          configFile(
            content: saved ? 'secret: value\r\n' : '',
            exists: saved,
            revision: saved ? 'b' * 64 : null,
          ),
        );
      });
      addTearDown(api.close);
      await tester.pumpWidget(editor(PanelTasksManager(api)));
      await pumpUntilFound(tester, find.text('文件不存在，保存后创建'));
      await tester.enterText(find.byType(TextField), 'secret: value\r\n');
      await tester.tap(find.byTooltip('保存配置'));
      await pumpUntilFound(tester, find.text('配置已保存'));
      await pumpUntil(
        tester,
        () => !tester.widget<TextField>(find.byType(TextField)).readOnly,
      );
      expect(posts, 1);
      expect(draft(tester), 'secret: value\r\n');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keeps a conflicting draft and requires review before a new save',
    (tester) async {
      var posts = 0;
      var current = false;
      final api = apiFor((request) async {
        if (request.method == 'POST') {
          posts++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (posts == 1) {
            current = true;
            return jsonResponse({
              'ok': false,
              'code': 'revision_conflict',
              'saved': false,
              'msg': '配置已变更',
              'current': configFile(
                content: 'server\n',
                revision: 'b' * 64,
              )['file'],
            }, 409);
          }
          expect(body['expected_revision'], 'b' * 64);
          expect(body['content'], 'merged\n');
          return jsonResponse(receipt(body['request_id'] as String, 'saved'));
        }
        return jsonResponse(
          configFile(
            content: current ? 'server\n' : 'original\n',
            revision: current ? 'b' * 64 : null,
          ),
        );
      });
      addTearDown(api.close);
      await tester.pumpWidget(editor(PanelTasksManager(api)));
      await pumpUntil(
        tester,
        () =>
            find.byType(TextField).evaluate().isNotEmpty &&
            draft(tester) == 'original\n',
      );
      await tester.enterText(find.byType(TextField), 'local\n');
      await tester.tap(find.byTooltip('保存配置'));
      await pumpUntilFound(tester, find.text('对照并合并草稿'));
      expect(draft(tester), 'local\n');
      expect(
        tester.widget<IconButton>(find.byTooltip('保存配置')).onPressed,
        isNull,
      );
      await tester.tap(find.text('对照并合并草稿'));
      await pumpUntilFound(tester, find.text('核对任务配置'));
      expect(find.text('server\n'), findsOneWidget);
      await tester.tap(find.text('保留草稿合并'));
      await tester.pumpAndSettle();
      expect(draft(tester), 'local\n');
      expect(posts, 1);
      await tester.enterText(find.byType(TextField), 'merged\n');
      await tester.tap(find.byTooltip('保存配置'));
      await pumpUntilFound(tester, find.text('配置已保存'));
      expect(posts, 2);
    },
  );

  testWidgets(
    'lost response and unknown receipt never replay POST and retain the original ID',
    (tester) async {
      var posts = 0;
      var queries = 0;
      String? requestId;
      final api = apiFor((request) async {
        if (request.method == 'POST') {
          posts++;
          requestId =
              (jsonDecode(request.body) as Map<String, dynamic>)['request_id']
                  as String;
          throw http.ClientException('response lost');
        }
        if (request.url.path.contains('/requests/')) {
          queries++;
          expect(request.url.path, '$configPath/requests/$requestId');
          return jsonResponse(receipt(requestId!, 'unknown'));
        }
        return jsonResponse(configFile());
      });
      addTearDown(api.close);
      final manager = PanelTasksManager(api);
      await tester.pumpWidget(editor(manager));
      await pumpUntil(
        tester,
        () =>
            find.byType(TextField).evaluate().isNotEmpty &&
            draft(tester).isNotEmpty,
      );
      await tester.enterText(find.byType(TextField), 'local secret');
      await tester.tap(find.byTooltip('保存配置'));
      await pumpUntil(
        tester,
        () =>
            posts == 1 &&
            tester
                    .widget<OutlinedButton>(
                      find.widgetWithText(OutlinedButton, '查询原提交'),
                    )
                    .onPressed !=
                null,
      );
      expect(manager.configRecoveryFor('daily').requestId, requestId);
      expect(
        tester.widget<IconButton>(find.byTooltip('保存配置')).onPressed,
        isNull,
      );
      await tester.tap(find.text('查询原提交'));
      await pumpUntilFound(tester, find.text('核对当前配置'));
      expect(queries, 1);
      expect(posts, 1);
      await tester.tap(find.text('核对当前配置'));
      await pumpUntilFound(tester, find.text('核对任务配置'));
      await tester.tap(find.text('保留草稿合并'));
      await tester.pumpAndSettle();
      expect(manager.configRecoveryFor('daily').requestId, isNull);
      expect(draft(tester), 'local secret');
      expect(posts, 1);
    },
  );

  testWidgets(
    'reopening the same panel session queries a pending request before editing',
    (tester) async {
      final methods = <String>[];
      final api = apiFor((request) async {
        methods.add(request.method);
        if (request.url.path.contains('/requests/')) {
          return jsonResponse(receipt('b' * 32, 'saved'));
        }
        return jsonResponse(configFile(content: 'saved remotely'));
      });
      addTearDown(api.close);
      final manager = PanelTasksManager(api);
      manager.configRecoveryFor('daily').requestId = 'b' * 32;
      await tester.pumpWidget(editor(manager));
      await pumpUntil(
        tester,
        () =>
            find.byType(TextField).evaluate().isNotEmpty &&
            draft(tester) == 'saved remotely',
      );
      expect(methods, ['GET', 'GET']);
      expect(manager.configRecoveryFor('daily').requestId, isNull);
    },
  );

  testWidgets('late old-panel 401 cannot clear or sign out the new panel', (
    tester,
  ) async {
    final oldResponse = Completer<http.Response>();
    var unauthorized = 0;
    final oldApi = apiFor((_) => oldResponse.future);
    final newApi = apiFor(
      (_) async => jsonResponse(configFile(content: 'new panel')),
    );
    addTearDown(oldApi.close);
    addTearDown(newApi.close);
    await tester.pumpWidget(
      editor(
        PanelTasksManager(oldApi),
        onUnauthorized: (_) async {
          unauthorized++;
        },
      ),
    );
    await tester.pumpWidget(
      editor(
        PanelTasksManager(newApi),
        onUnauthorized: (_) async {
          unauthorized++;
        },
      ),
    );
    await pumpUntil(
      tester,
      () =>
          find.byType(TextField).evaluate().isNotEmpty &&
          draft(tester) == 'new panel',
    );
    oldResponse.complete(jsonResponse({'ok': false, 'msg': 'expired'}, 401));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(unauthorized, 0);
    expect(draft(tester), 'new panel');
  });

  testWidgets(
    'current 401 hides the editor and keeps a pending original submission',
    (tester) async {
      var unauthorized = 0;
      final api = apiFor((request) async {
        if (request.method == 'POST') {
          return jsonResponse({'ok': false, 'msg': 'expired'}, 401);
        }
        return jsonResponse(configFile(content: 'secret draft'));
      });
      addTearDown(api.close);
      final manager = PanelTasksManager(api);
      await tester.pumpWidget(
        editor(
          manager,
          onUnauthorized: (_) async {
            unauthorized++;
          },
        ),
      );
      await pumpUntil(
        tester,
        () =>
            find.byType(TextField).evaluate().isNotEmpty &&
            draft(tester) == 'secret draft',
      );
      await tester.tap(find.byTooltip('保存配置'));
      await pumpUntil(tester, () => unauthorized == 1);
      expect(find.byType(TextField), findsNothing);
      expect(manager.configRecoveryFor('daily').requestId, isNotNull);
      expect(
        tester.widget<IconButton>(find.byTooltip('保存配置')).onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'narrow large-text unknown-result view remains scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = apiFor(
        (_) async => jsonResponse(receipt('b' * 32, 'unknown')),
      );
      addTearDown(api.close);
      final manager = PanelTasksManager(api);
      manager.configRecoveryFor('daily').requestId = 'b' * 32;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: PanelTaskConfigView(
            manager: manager,
            taskId: 'daily',
            taskName: '每日任务配置内容',
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('核对当前配置'));
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsWidgets);
    },
  );
}
