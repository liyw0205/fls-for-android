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
}
