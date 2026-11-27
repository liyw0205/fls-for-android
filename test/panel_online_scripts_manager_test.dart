import 'dart:convert';

import 'panel_test_http.dart';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_online_scripts_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

void main() {
  const requestId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const historyId = 'cccccccccccccccccccccccccccccccc';
  const snapshot =
      'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

  test(
    'refresh state rejects a different request and malformed active flags',
    () async {
      for (final change in <Map<String, dynamic>>[
        {'request_id': historyId},
        {'active': 'true'},
        {'running': 1},
      ]) {
        final api = PanelApiClient(
          baseUrl: 'https://fls.example',
          client: MockClient(
            (_) async => utf8Response(
              jsonEncode({
                'request_id': requestId,
                'status': '运行中',
                'running': true,
                ...change,
              }),
              200,
            ),
          ),
        );
        try {
          await expectLater(
            PanelOnlineScriptsManager(api).fetchRefreshState(requestId),
            throwsA(isA<PanelApiException>()),
          );
        } finally {
          api.close();
        }
      }
    },
  );

  test(
    'refresh failure pages bind request, offset, digest and bounds',
    () async {
      final page = <String, dynamic>{
        'ok': true,
        'request_id': requestId,
        'offset': 100,
        'total': 101,
        'digest': snapshot,
        'items': [
          {'script_id': 'last'},
        ],
        'has_more': false,
      };
      for (final change in <Map<String, dynamic>>[
        {},
        {'request_id': historyId},
        {'offset': 0},
        {'total': 100},
        {'digest': 'invalid'},
        {'has_more': 'false'},
      ]) {
        final api = PanelApiClient(
          baseUrl: 'https://fls.example',
          client: MockClient((request) async {
            expect(request.url.queryParameters['offset'], '100');
            return utf8Response(jsonEncode({...page, ...change}), 200);
          }),
        );
        try {
          final future = PanelOnlineScriptsManager(
            api,
          ).fetchRefreshTaskLinkFailures(requestId, offset: 100);
          if (change.isEmpty) {
            expect((await future)['items'], page['items']);
          } else {
            await expectLater(future, throwsA(isA<PanelApiException>()));
          }
        } finally {
          api.close();
        }
      }
    },
  );

  test('redacts secrets from script diagnostics', () {
    final safe = PanelOnlineScriptsManager.sanitizeDiagnostic(
      'https://source.example/tasks.json?token=secret-value&mode=1 '
      '{"api_key":"json-secret"} password=plain-secret '
      'https://user:basic-secret@source.example/tasks.json',
    );

    expect(safe, contains('token=[已隐藏]&mode=1'));
    expect(safe, contains('"api_key":"[已隐藏]"'));
    expect(safe, contains('password=[已隐藏]'));
    expect(safe, isNot(contains('secret-value')));
    expect(safe, isNot(contains('json-secret')));
    expect(safe, isNot(contains('plain-secret')));
    expect(safe, contains('https://[已隐藏]@source.example'));
    expect(safe, isNot(contains('basic-secret')));
  });

  test(
    'loads paginated online scripts and safely parses install options',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://fls.example/panel',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=script-session',
          csrfToken: 'script-csrf',
        ),
        client: MockClient((request) async {
          expect(
            request.headers['cookie'],
            'fls_native_session=script-session',
          );
          if (request.url.path == '/panel/api/online-scripts/catalog') {
            expect(request.method, 'GET');
            expect(request.url.queryParameters, {
              'q': '示例 脚本',
              'page': '2',
              'limit': '10',
            });
            return utf8Response(
              '{"ok":true,"items":[{"id":"demo","name":"示例脚本","type":"raw","link_name":"demo.sh","source_url":"https://example.invalid/demo.sh","doc_url":"https://example.invalid/README.md","description":"说明","version":"1.0","author":"maintainer","category":"tools","tags":["shell"],"has_install":true,"has_doc":true,"has_tasks":true,"task_count":1}],"page":2,"pages":3,"total":21}',
              200,
            );
          }
          expect(
            request.url.path,
            '/panel/api/online-scripts/install-options/demo',
          );
          expect(request.url.queryParameters, {
            'q': 'Daily',
            'page': '1',
            'limit': '20',
          });
          return utf8Response(
            '{"ok":true,"script_id":"demo","items":[{"index":1,"name":"Daily task","cron":"0 * * * *","command":"python demo.py","remark":"","config_path":"","enabled":true,"variable_names":["API_TOKEN"],"variable_count":1,"sensitive_variables":["API_TOKEN"],"valid":true,"validation_error":""}],"proxies":[{"id":"proxy-1","name":"Proxy","type":"github","password":"drop-me"}],"page":1,"pages":1,"total":1}',
            200,
          );
        }),
      );
      addTearDown(api.close);

      final manager = PanelOnlineScriptsManager(api);
      final catalog = await manager.fetchCatalog(
        query: '示例 脚本',
        page: 2,
        limit: 10,
      );
      final options = await manager.fetchInstallOptions('demo', query: 'Daily');

      expect(catalog.items.single.id, 'demo');
      expect(catalog.items.single.hasTasks, isTrue);
      expect(options.tasks.single.variableNames, ['API_TOKEN']);
      expect(options.proxies.single.id, 'proxy-1');
      expect(options.toString(), isNot(contains('drop-me')));
    },
  );

  test(
    'submits install with idempotency, session and CSRF then reads progress',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=script-session',
          csrfToken: 'script-csrf',
        ),
        client: MockClient((request) async {
          if (request.method == 'POST') {
            expect(request.url.path, '/api/online-scripts/install/demo');
            expect(
              request.headers['cookie'],
              'fls_native_session=script-session',
            );
            expect(request.headers['x-csrf-token'], 'script-csrf');
            expect(jsonDecode(request.body), {
              'request_id': requestId,
              'proxy_id': 'proxy-1',
              'import_task': true,
              'enable_task': false,
              'force': false,
              'task_indexes': ['2'],
            });
            return utf8Response(
              '{"ok":true,"request_id":"$requestId","install_id":"$requestId","running":true,"status":"下载中","phase":"downloading"}',
              200,
            );
          }
          expect(request.url.path, '/api/online-scripts/log/$requestId');
          expect(request.url.queryParameters, {'state_only': '1'});
          return utf8Response(
            '{"ok":true,"install_id":"$requestId","running":true,"status":"下载中","phase":"downloading","download_progress":{"state":"downloading","kind":"raw","downloaded_bytes":524288,"total_bytes":1048576,"percent":50}}',
            200,
          );
        }),
      );
      addTearDown(api.close);

      final manager = PanelOnlineScriptsManager(api);
      final started = await manager.startInstall(
        scriptId: 'demo',
        requestId: requestId,
        proxyId: 'proxy-1',
        importTasks: true,
        taskIndexes: [2],
      );
      final state = await manager.fetchInstallState(requestId);

      expect(started['accepted'], isNull);
      expect(state.downloadedBytes, 524288);
      expect(state.totalBytes, 1048576);
      expect(state.percent, 50);
      await expectLater(
        manager.startInstall(
          scriptId: 'demo',
          requestId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          enableTasks: true,
        ),
        throwsArgumentError,
      );
    },
  );

  test('reads bounded install history with a stable snapshot', () async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=script-session',
        csrfToken: 'script-csrf',
      ),
      client: MockClient((request) async {
        expect(request.url.path, '/api/online-scripts/install-history');
        expect(request.url.queryParameters, {
          'script_id': 'demo',
          'status': '失败',
          'limit': '15',
          'offset': '15',
          'snapshot': snapshot,
        });
        return utf8Response(
          '{"ok":true,"items":[{"id":"$historyId","script_id":"demo","script_name":"Demo","status":"失败","running":false,"start_time":"2026-11-25 10:00:00"}],"total":16,"offset":15,"limit":15,"has_more":false,"snapshot":"$snapshot"}',
          200,
        );
      }),
    );
    addTearDown(api.close);

    final page = await PanelOnlineScriptsManager(api).fetchInstallHistory(
      scriptId: 'demo',
      status: '失败',
      limit: 15,
      offset: 15,
      snapshot: snapshot,
    );

    expect(page.items.single.installId, historyId);
    expect(page.items.single.scriptName, 'Demo');
    expect(page.hasMore, isFalse);
  });

  test('reads and saves source cache with optimistic revision control', () async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=script-session',
        csrfToken: 'script-csrf',
      ),
      client: MockClient((request) async {
        if (request.method == 'GET') {
          expect(request.url.path, '/api/online-scripts/source');
          return utf8Response(
            '{"ok":true,"json_text":"[]","cache_revision":"$snapshot"}',
            200,
          );
        }
        expect(request.method, 'PUT');
        expect(request.headers['x-csrf-token'], 'script-csrf');
        expect(request.url.path, '/api/online-scripts/source');
        expect(jsonDecode(request.body), {
          'json_text': '[{"id":"demo"}]',
          'cache_revision': snapshot,
        });
        return utf8Response(
          '{"ok":true,"count":1,"json_text":"[]","cache_revision":"$snapshot"}',
          200,
        );
      }),
    );
    addTearDown(api.close);

    final manager = PanelOnlineScriptsManager(api);
    final source = await manager.fetchSourceCache();
    final saved = await manager.saveSourceCache(
      jsonText: '[{"id":"demo"}]',
      cacheRevision: source['cache_revision'] as String,
    );

    expect(source['json_text'], '[]');
    expect(saved['count'], 1);
  });

  test(
    'submits refresh, task import, and task-link with stable request IDs',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=script-session',
          csrfToken: 'script-csrf',
        ),
        client: MockClient((request) async {
          expect(request.headers['x-csrf-token'], 'script-csrf');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path == '/api/online-scripts/refresh') {
            expect(body, {'request_id': requestId, 'proxy_id': 'proxy-1'});
          } else if (request.url.path ==
              '/api/online-scripts/import-tasks/demo') {
            expect(body, {
              'request_id': requestId,
              'task_indexes': ['2'],
              'enable_task': true,
            });
          } else {
            expect(
              request.url.path,
              '/api/online-scripts/refresh-task-link/$historyId/task-link/demo',
            );
            expect(body, {'request_id': requestId, 'proxy_id': 'proxy-1'});
          }
          return utf8Response('{"ok":true,"request_id":"$requestId"}', 202);
        }),
      );
      addTearDown(api.close);

      final manager = PanelOnlineScriptsManager(api);
      await manager.startRefresh(requestId: requestId, proxyId: 'proxy-1');
      await manager.importTasks(
        scriptId: 'demo',
        requestId: requestId,
        taskIndexes: [2],
        enableTasks: true,
      );
      await manager.linkTasks(
        scriptId: 'demo',
        requestId: requestId,
        proxyId: 'proxy-1',
        refreshRequestId: historyId,
      );
    },
  );
}
