import 'dart:convert';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_runtime_deps_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_test_http.dart';

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=deps-session',
    csrfToken: 'deps-csrf',
  );

  test(
    'uses package, runtime, checks, install, and history contracts',
    () async {
      final requests = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/root',
        credentials: session,
        client: panelMockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          expect(request.headers['cookie'], session.cookie);
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/deps/packages')) {
            expect(request.url.queryParameters, {
              'q': 'requests',
              'page': '2',
              'limit': '10',
            });
            return utf8Response(
              jsonEncode({
                'ok': true,
                'items': [
                  {'name': 'requests', 'version': '2.0'},
                ],
                'page': 2,
                'pages': 2,
                'total': 11,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/runtime/status')) {
            return utf8Response(
              jsonEncode({
                'ok': true,
                'items': [
                  {
                    'key': 'node',
                    'name': 'Node.js',
                    'suffix': '.js / .mjs',
                    'status': 'missing',
                    'version': '',
                    'detail': '未找到可执行文件',
                    'installable': true,
                    'install_error': '',
                  },
                ],
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/api/deps/refresh')) {
            expect(request.headers['x-csrf-token'], session.csrfToken);
            return utf8Response(
              jsonEncode({
                'ok': true,
                'time': 'now',
                'packages': {'flask': '3.0'},
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/api/deps/install')) {
            expect(request.headers['x-csrf-token'], session.csrfToken);
            expect(jsonDecode(request.body), {
              'name': 'requests',
              'request_id': 'a' * 32,
            });
            return utf8Response(
              jsonEncode(_job(status: 'running', running: true)),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/deps/install-history')) {
            expect(request.url.queryParameters, {'limit': '20', 'kind': ''});
            return utf8Response(
              jsonEncode({
                'ok': true,
                'items': [_job(status: 'running', running: true)],
              }),
              200,
            );
          }
          fail('unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(api.close);

      final manager = PanelRuntimeDepsManager(api);
      final packages = await manager.fetchPackages(
        query: 'requests',
        page: 2,
        limit: 10,
      );
      expect(packages.items.single.version, '2.0');
      expect(packages.total, 11);
      final runtimes = await manager.fetchRuntimes();
      expect(runtimes.single.key, 'node');
      expect(runtimes.single.installable, isTrue);
      final checks = await manager.refreshCoreDependencies();
      expect(checks.packages['flask'], '3.0');
      final job = await manager.installDependency(
        'requests',
        requestId: 'a' * 32,
      );
      expect(job.id, 'b' * 32);
      expect(job.running, isTrue);
      expect(
        (await manager.fetchHistory(limit: 20)).items.single.operation,
        'install',
      );
      expect(requests, hasLength(5));
    },
  );

  test('reads pending receipts from structured 503 responses', () async {
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient(
        (_) async => utf8Response(
          jsonEncode({
            'ok': false,
            'request_id': 'c' * 32,
            'install_id': 'c' * 32,
            'kind': 'dependency',
            'operation': 'uninstall',
            'package': 'requests',
            'status': 'unknown',
            'running': false,
            'receipt_pending': true,
            'retry_confirmation_required': true,
            'error': 'receipt pending',
          }),
          503,
        ),
      ),
    );
    addTearDown(api.close);

    final job = await PanelRuntimeDepsManager(api).fetchInstall('c' * 32);
    expect(job.operation, 'uninstall');
    expect(job.receiptPending, isTrue);
    expect(job.retryConfirmationRequired, isTrue);
  });

  test('rejects unsafe identifiers and package arguments before requests', () {
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((_) async => fail('no request expected')),
    );
    addTearDown(api.close);
    final manager = PanelRuntimeDepsManager(api);

    expect(
      () => manager.installDependency('--help', requestId: 'a' * 32),
      throwsArgumentError,
    );
    expect(
      () => manager.installRuntime('node/other', requestId: 'a' * 32),
      throwsArgumentError,
    );
    expect(
      () => manager.uninstallDependency('requests', requestId: '../x'),
      throwsArgumentError,
    );
  });
}

Map<String, Object?> _job({required String status, required bool running}) => {
  'ok': true,
  'install_id': 'b' * 32,
  'request_id': 'b' * 32,
  'kind': 'dependency',
  'operation': 'install',
  'package': 'requests',
  'status': status,
  'status_label': '安装中',
  'running': running,
  'returncode': null,
  'error': '',
  'log': '',
  'retry_confirmation_required': false,
  'cancel_status': '',
  'updated_at': 'now',
};
