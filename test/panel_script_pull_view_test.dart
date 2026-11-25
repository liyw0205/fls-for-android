import 'dart:convert';

import 'package:fls_for_android/features/panel_script_pull_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_script_pull_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

void main() {
  testWidgets('explains when the destination directory changed', (
    tester,
  ) async {
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=pull-session',
        csrfToken: 'pull-csrf',
      ),
      client: panelMockClient((request) async {
        if (request.url.path == '/api/scripts/pull-options') {
          return _jsonResponse({'ok': true, 'proxies': []});
        }
        if (request.url.path == '/api/scripts/pull-history') {
          return _jsonResponse({
            'ok': true,
            'items': [_job(status: 'failed', errorCode: 'path_changed')],
          });
        }
        if (request.url.path == '/api/scripts/repo-pull-history') {
          return _jsonResponse({'ok': true, 'items': <Object>[]});
        }
        fail('unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelScriptPullView(
          manager: PanelScriptPullManager(api),
          currentPath: '',
          onUnauthorized: (_) async {},
        ),
      ),
    );

    await pumpUntilFound(tester, find.textContaining('目标目录已变化，未发布'));
    expect(find.textContaining('目标目录已变化，未发布'), findsOneWidget);
  });

  testWidgets(
    'submits a pull and renders byte progress before refreshing the directory',
    (tester) async {
      final requests = <String>[];
      var historyReads = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=pull-session',
          csrfToken: 'pull-csrf',
        ),
        client: panelMockClient((request) async {
          requests.add('${request.method} ${request.url}');
          expect(request.headers['cookie'], 'fls_native_session=pull-session');
          if (request.url.path == '/api/scripts/pull-options') {
            return _jsonResponse({
              'ok': true,
              'proxies': [
                {'id': 'relay', 'name': 'Fast relay', 'type': 'http'},
              ],
            });
          }
          if (request.url.path == '/api/scripts/pull-history') {
            historyReads++;
            return _jsonResponse({
              'ok': true,
              'items': historyReads == 1 ? [] : [_job(status: 'complete')],
            });
          }
          if (request.url.path == '/api/scripts/repo-pull-history') {
            return _jsonResponse({'ok': true, 'items': <Object>[]});
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/scripts/pull') {
            expect(request.headers['x-csrf-token'], 'pull-csrf');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['url'], 'https://example.invalid/script.py');
            expect(body['path'], 'folder/script.py');
            expect(body['proxy_id'], 'relay');
            expect(body['request_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
            return _jsonResponse({
              'ok': true,
              'job': _job(status: 'downloading'),
            }, 202);
          }
          fail('unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(api.close);

      var unauthorized = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PanelScriptPullView(
            manager: PanelScriptPullManager(api),
            currentPath: 'folder',
            onUnauthorized: (_) async => unauthorized++,
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('最近拉取'));
      expect(find.text('保存到 folder'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('panel-script-pull-url')),
        'https://example.invalid/script.py',
      );
      await tester.enterText(
        find.byKey(const ValueKey('panel-script-pull-name')),
        'script.py',
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fast relay · http').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始拉取'));
      await pumpUntilFound(tester, find.text('已完成'));

      expect(find.text('script.py'), findsWidgets);
      expect(find.textContaining('100%'), findsOneWidget);
      expect(find.text('返回并刷新目录'), findsOneWidget);
      expect(unauthorized, 0);
      expect(historyReads, greaterThanOrEqualTo(2));
      expect(
        requests.where(
          (item) => item == 'POST https://panel.example/api/scripts/pull',
        ),
        hasLength(1),
      );

      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回并刷新目录'));
      await tester.pumpAndSettle();
      expect(find.text('远程拉取'), findsNothing);
    },
  );

  testWidgets(
    'shows indeterminate progress for unknown totals and can cancel',
    (tester) async {
      var cancelCount = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=pull-session',
          csrfToken: 'pull-csrf',
        ),
        client: panelMockClient((request) async {
          if (request.url.path == '/api/scripts/pull-options') {
            return _jsonResponse({'ok': true, 'proxies': []});
          }
          if (request.url.path == '/api/scripts/pull-history') {
            return _jsonResponse({
              'ok': true,
              'items': [_job(status: 'downloading', unknownTotal: true)],
            });
          }
          if (request.url.path == '/api/scripts/repo-pull-history') {
            return _jsonResponse({'ok': true, 'items': <Object>[]});
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/cancel')) {
            cancelCount++;
            return _jsonResponse({
              'ok': true,
              'job': _job(status: 'cancelling', unknownTotal: true),
            }, 202);
          }
          fail('unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: PanelScriptPullView(
            manager: PanelScriptPullManager(api),
            currentPath: '',
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.textContaining('总量未知'));
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator).last,
            )
            .value,
        isNull,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
      expect(find.byTooltip('取消拉取'), findsOneWidget);
      await tester.tap(find.byTooltip('取消拉取'));
      await pumpUntilFound(tester, find.text('正在取消'));
      expect(cancelCount, 1);
    },
  );
  testWidgets(
    'submits a Git repository and shows object stage without percent',
    (tester) async {
      var submitted = false;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=pull-session',
          csrfToken: 'pull-csrf',
        ),
        client: panelMockClient((request) async {
          if (request.url.path == '/api/scripts/pull-options') {
            return _jsonResponse({'ok': true, 'proxies': []});
          }
          if (request.url.path == '/api/scripts/pull-history') {
            return _jsonResponse({'ok': true, 'items': <Object>[]});
          }
          if (request.url.path == '/api/scripts/repo-pull-history') {
            return _jsonResponse({
              'ok': true,
              'items': submitted ? [_repoJob()] : <Object>[],
            });
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/scripts/repo-pull') {
            submitted = true;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['url'], 'https://example.invalid/repo.git');
            expect(body['path'], 'folder/repo');
            expect(body['request_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
            return _jsonResponse({'ok': true, 'job': _repoJob()}, 202);
          }
          fail('unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: PanelScriptPullView(
            manager: PanelScriptPullManager(api),
            currentPath: 'folder',
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('最近拉取'));
      await tester.tap(find.text('Git 仓库'));
      await tester.enterText(
        find.byKey(const ValueKey('panel-script-pull-url')),
        'https://example.invalid/repo.git',
      );
      await tester.enterText(
        find.byKey(const ValueKey('panel-script-pull-name')),
        'repo',
      );
      await tester.tap(find.text('开始拉取'));
      await pumpUntilFound(tester, find.text('接收对象 · 1/4 个对象'));

      expect(find.text('正在克隆'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator).last,
            )
            .value,
        isNull,
      );
    },
  );

  testWidgets('shows a completed Git repository with a full progress bar', (
    tester,
  ) async {
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=pull-session',
        csrfToken: 'pull-csrf',
      ),
      client: panelMockClient((request) async {
        if (request.url.path == '/api/scripts/pull-options') {
          return _jsonResponse({'ok': true, 'proxies': []});
        }
        if (request.url.path == '/api/scripts/pull-history') {
          return _jsonResponse({'ok': true, 'items': <Object>[]});
        }
        if (request.url.path == '/api/scripts/repo-pull-history') {
          return _jsonResponse({
            'ok': true,
            'items': [_repoJob(status: 'complete')],
          });
        }
        fail('unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelScriptPullView(
          manager: PanelScriptPullManager(api),
          currentPath: '',
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('最近拉取'));

    await tester.tap(find.text('folder/repo'));
    await tester.pump();

    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('个对象'), findsNothing);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator).last,
          )
          .value,
      1,
    );
  });
}

Map<String, dynamic> _job({
  required String status,
  bool unknownTotal = false,
  String errorCode = '',
}) => {
  'id': 'b' * 32,
  'request_id': 'a' * 32,
  'kind': 'file',
  'path': 'script.py',
  'source_host': 'example.invalid',
  'status': status,
  'progress': {
    'state': unknownTotal ? 'indeterminate' : status,
    'downloaded_bytes': 1024 * 1024,
    'total_bytes': unknownTotal ? null : 1024 * 1024,
    'percent': unknownTotal ? null : 100,
  },
  'error_code': errorCode,
  'created_at': '2026-11-25T10:00:00+08:00',
  'updated_at': '2026-11-25T10:00:01+08:00',
  'replayed': false,
};

http.Response _jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _repoJob({String status = 'cloning'}) => {
  'id': 'd' * 32,
  'request_id': 'c' * 32,
  'kind': 'repo',
  'path': 'folder/repo',
  'source_host': 'example.invalid',
  'status': status,
  'progress': {
    'phase': status == 'complete' ? 'complete' : 'receiving',
    'current': status == 'complete' ? 4 : 1,
    'total': 4,
    'label': '接收对象',
  },
  'error_code': '',
  'created_at': '2026-11-25T10:00:00+08:00',
  'updated_at': '2026-11-25T10:00:01+08:00',
  'replayed': false,
};
