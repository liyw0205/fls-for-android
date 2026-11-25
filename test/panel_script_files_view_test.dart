import 'dart:convert';

import 'package:fls_for_android/features/panel_script_files_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_script_files_manager.dart';
import 'package:fls_for_android/services/panel_script_debug_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

void main() {
  testWidgets(
    'opens a panel file, compares a revision conflict, and preserves the draft',
    (tester) async {
      final putBodies = <Map<String, dynamic>>[];
      final requests = <String>[];
      var putCount = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=file-session',
          csrfToken: 'file-csrf',
        ),
        client: panelMockClient((request) async {
          requests.add('${request.method} ${request.url}');
          if (request.method == 'GET' &&
              request.url.path == '/api/scripts/tree') {
            return _jsonResponse(_tree());
          }
          if (request.method == 'GET') {
            return _jsonResponse({
              'ok': true,
              'file': _file('print("before")\n', 'a' * 64),
            });
          }
          expect(request.headers['x-csrf-token'], 'file-csrf');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          putBodies.add(body);
          putCount++;
          if (putCount == 1) {
            return _jsonResponse({
              'ok': false,
              'code': 'revision_conflict',
              'msg': '文件已被其他操作修改',
              'current': _file('print("server")\n', 'b' * 64),
            }, 409);
          }
          return _jsonResponse({
            'ok': true,
            'changed': true,
            'file': _file(body['content'] as String, 'c' * 64),
          });
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: PanelScriptFilesView(
            manager: PanelScriptFilesManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            find.text('demo.py').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
        diagnostics: () => requests.join(' | '),
      );
      expect(find.text('demo.py'), findsOneWidget);
      await tester.tap(find.text('demo.py'));
      await _pumpUntil(tester, () {
        final fields = find.byType(TextField);
        return fields.evaluate().length > 1 &&
            tester.widget<TextField>(fields.last).enabled == true;
      });
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'print("draft")\n');
      await tester.tap(find.byTooltip('保存文件'));
      await _pumpUntil(tester, () => find.text('文件版本冲突').evaluate().isNotEmpty);

      expect(find.text('文件版本冲突'), findsOneWidget);
      expect(find.textContaining('draft'), findsNWidgets(2));
      expect(find.textContaining('server'), findsOneWidget);
      await tester.tap(find.text('保留草稿'));
      await _pumpUntil(
        tester,
        () => find.textContaining('草稿已保留').evaluate().isNotEmpty,
      );
      expect(find.textContaining('草稿已保留'), findsOneWidget);

      await tester.tap(find.byTooltip('保存文件'));
      await _pumpUntil(
        tester,
        () => find.byTooltip('新建文件或目录').evaluate().isNotEmpty,
      );
      expect(putBodies, hasLength(2));
      expect(putBodies.last['content'], 'print("draft")\n');
      expect(putBodies.last['revision'], 'b' * 64);
      expect(find.text('面板文件'), findsOneWidget);
    },
  );

  testWidgets('verifies a saved draft after the write response is unknown', (
    tester,
  ) async {
    final requests = <String>[];
    var fileReads = 0;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=file-session',
        csrfToken: 'file-csrf',
      ),
      client: panelMockClient((request) async {
        requests.add('${request.method} ${request.url}');
        if (request.url.path == '/api/scripts/tree') {
          return _jsonResponse(_tree());
        }
        if (request.method == 'GET') {
          fileReads++;
          return _jsonResponse({
            'ok': true,
            'file': fileReads == 1
                ? _file('print("before")\n', 'a' * 64)
                : _file('print("draft")\n', 'b' * 64),
          });
        }
        return _jsonResponse({
          'ok': false,
          'saved': true,
          'code': 'write_result_unknown',
          'msg': '文件已保存，请重新读取确认',
        }, 503);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelScriptFilesView(
          manager: PanelScriptFilesManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find.text('demo.py').evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
      diagnostics: () => requests.join(' | '),
    );
    await tester.tap(find.text('demo.py'));
    await _pumpUntil(tester, () {
      final fields = find.byType(TextField);
      return fields.evaluate().length > 1 &&
          tester.widget<TextField>(fields.last).enabled == true;
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'print("draft")\n');
    await tester.tap(find.byTooltip('保存文件'));
    await _pumpUntil(
      tester,
      () => find.byTooltip('新建文件或目录').evaluate().isNotEmpty,
    );

    expect(fileReads, 2);
    expect(find.text('面板文件'), findsOneWidget);
  });

  testWidgets('reviews task references before renaming a panel script', (
    tester,
  ) async {
    var treeReads = 0;
    var renameSubmitted = false;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=file-session',
        csrfToken: 'file-csrf',
      ),
      client: panelMockClient((request) async {
        if (request.url.path == '/api/scripts/tree') {
          treeReads++;
          return _jsonResponse({
            ..._tree(),
            'items': [
              {
                'name': renameSubmitted ? 'renamed.py' : 'demo.py',
                'path': renameSubmitted ? 'renamed.py' : 'demo.py',
                'kind': 'file',
                'size_bytes': 10,
                'modified_at': 'now',
              },
            ],
          });
        }
        if (request.url.path == '/api/scripts/rename/preview') {
          expect(request.url.queryParameters, {
            'path': 'demo.py',
            'new_name': 'renamed.py',
          });
          return _jsonResponse({
            'ok': true,
            'preview': {
              'source': 'demo.py',
              'destination': 'renamed.py',
              'revision': 'd' * 64,
              'references': [
                {
                  'id': 'task-1',
                  'name': 'Demo task',
                  'manual': false,
                  'before': {'command': 'python demo.py', 'config_path': ''},
                  'after': {'command': 'python renamed.py', 'config_path': ''},
                },
              ],
            },
          });
        }
        expect(request.url.path, '/api/scripts/rename');
        expect(request.headers['x-csrf-token'], 'file-csrf');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['revision'], 'd' * 64);
        expect(body['references'], [
          {
            'task_id': 'task-1',
            'command': 'python renamed.py',
            'config_path': '',
          },
        ]);
        renameSubmitted = true;
        return _jsonResponse({
          'ok': true,
          'operation': {
            'id': body['operation_id'],
            'source': 'demo.py',
            'destination': 'renamed.py',
            'status': 'succeeded',
            'finished': true,
            'actual': {
              'source_exists': false,
              'destination_exists': true,
              'tasks': [
                {'task_id': 'task-1', 'state': 'updated'},
              ],
            },
          },
        });
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelScriptFilesView(
          manager: PanelScriptFilesManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('demo.py').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('文件操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'renamed.py');
    await tester.tap(find.text('检查引用'));
    await _pumpUntil(tester, () => find.text('检查任务引用').evaluate().isNotEmpty);
    expect(find.text('python demo.py'), findsOneWidget);
    expect(find.text('python renamed.py'), findsOneWidget);
    await tester.tap(find.text('确认改名'));
    await _pumpUntil(tester, () => treeReads == 2 && renameSubmitted);

    expect(renameSubmitted, isTrue);
    expect(treeReads, 2);
    expect(find.text('renamed.py'), findsOneWidget);
    expect(find.text('面板文件'), findsOneWidget);
  });

  testWidgets('reviews task impact and confirms panel script deletion', (
    tester,
  ) async {
    var treeReads = 0;
    var deleteSubmitted = false;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=file-session',
        csrfToken: 'file-csrf',
      ),
      client: panelMockClient((request) async {
        if (request.url.path == '/api/scripts/tree') {
          treeReads++;
          return _jsonResponse({
            ..._tree(),
            'total': deleteSubmitted ? 0 : 1,
            'items': deleteSubmitted
                ? <Map<String, dynamic>>[]
                : _tree()['items'],
          });
        }
        if (request.url.path == '/api/scripts/delete/preview') {
          expect(request.url.queryParameters, {'path': 'demo.py'});
          return _jsonResponse({
            'ok': true,
            'preview': {
              'path': 'demo.py',
              'kind': 'file',
              'revision': 'e' * 64,
              'size_bytes': 10,
              'modified_at': 'now',
              'references': [
                {
                  'task_id': 'task-1',
                  'task_name': 'Demo task',
                  'fields': ['command'],
                },
              ],
            },
          });
        }
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/scripts/file');
        expect(request.headers['x-csrf-token'], 'file-csrf');
        expect(jsonDecode(request.body), {
          'path': 'demo.py',
          'revision': 'e' * 64,
          'confirm_references': true,
        });
        deleteSubmitted = true;
        return _jsonResponse({'ok': true, 'deleted': true, 'path': 'demo.py'});
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelScriptFilesView(
          manager: PanelScriptFilesManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('demo.py').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('文件操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除文件').first);
    await _pumpUntil(
      tester,
      () => find.text('删除 demo.py').evaluate().isNotEmpty,
    );

    expect(find.text('以下任务引用此文件。删除后这些任务可能无法运行。'), findsOneWidget);
    expect(find.text('Demo task'), findsOneWidget);
    expect(find.text('python demo.py'), findsNothing);
    await tester.tap(find.text('删除文件').last);
    await _pumpUntil(
      tester,
      () => treeReads == 2 && find.text('目录为空').evaluate().isNotEmpty,
    );

    expect(deleteSubmitted, isTrue);
    expect(treeReads, 2);
    expect(find.text('目录为空'), findsOneWidget);
  });

  testWidgets('opens the native debugger from a panel file editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final requests = <String>[];
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=file-session',
        csrfToken: 'file-csrf',
      ),
      client: panelMockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/scripts/tree') {
          return _jsonResponse(_tree());
        }
        if (request.url.path == '/api/scripts/file') {
          return _jsonResponse({
            'ok': true,
            'file': _file('print("debug")\n', 'a' * 64),
          });
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/scripts/debug-runs') {
          expect(request.headers['x-csrf-token'], 'file-csrf');
          expect(jsonDecode(request.body)['path'], 'demo.py');
          return _jsonResponse({
            'ok': true,
            'replayed': false,
            'run': {
              'id': 'b' * 32,
              'path': 'demo.py',
              'status': 'succeeded',
              'running': false,
              'returncode': 0,
              'error': '',
              'created_at': 'now',
              'updated_at': 'now',
            },
          }, 202);
        }
        if (request.method == 'GET' &&
            request.url.path == '/api/scripts/debug-runs/${'b' * 32}') {
          return _jsonResponse({
            'ok': true,
            'run': {
              'id': 'b' * 32,
              'path': 'demo.py',
              'status': 'succeeded',
              'running': false,
              'returncode': 0,
              'error': '',
              'created_at': 'now',
              'updated_at': 'now',
            },
            'log': 'debug output',
          });
        }
        fail('unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelScriptFilesView(
          manager: PanelScriptFilesManager(api),
          debugManager: PanelScriptDebugManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('demo.py').evaluate().isNotEmpty);
    await tester.tap(find.text('demo.py'));
    await _pumpUntil(
      tester,
      () => find.byTooltip('调试运行').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('调试运行'));
    await _pumpUntil(
      tester,
      () => find.text('debug output').evaluate().isNotEmpty,
    );

    expect(find.text('脚本调试'), findsOneWidget);
    expect(requests, contains('POST /api/scripts/debug-runs'));
    expect(requests, contains('GET /api/scripts/debug-runs/${'b' * 32}'));
    expect(tester.takeException(), isNull);
  });
}

Map<String, dynamic> _tree() => {
  'ok': true,
  'path': '',
  'parent': null,
  'page': 1,
  'pages': 1,
  'total': 1,
  'limit': 50,
  'items': [
    {
      'name': 'demo.py',
      'path': 'demo.py',
      'kind': 'file',
      'size_bytes': 10,
      'modified_at': 'now',
    },
  ],
};

Map<String, dynamic> _file(String content, String revision) => {
  'path': 'demo.py',
  'name': 'demo.py',
  'content': content,
  'revision': revision,
  'size_bytes': content.length,
  'modified_at': 'now',
};

http.Response _jsonResponse(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String Function()? diagnostics,
}) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  final banners = tester
      .widgetList<MaterialBanner>(find.byType(MaterialBanner))
      .map((banner) => banner.content)
      .whereType<Text>()
      .map((text) => text.data)
      .join(' | ');
  fail(
    'widget state did not reach the expected condition; '
    'file=${find.text("demo.py").evaluate().length}, '
    'progress=${find.byType(LinearProgressIndicator).evaluate().length}, '
    'banners=$banners, requests=${diagnostics?.call() ?? ""}',
  );
}
