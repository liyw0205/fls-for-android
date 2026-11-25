import 'dart:convert';

import 'package:fls_for_android/features/panel_runtime_deps_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_runtime_deps_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_test_http.dart';

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=deps-widget',
    csrfToken: 'deps-widget-csrf',
  );

  testWidgets('uninstalls a listed dependency and opens its live job', (
    tester,
  ) async {
    var packageReads = 0;
    final calls = <String>[];
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        expect(request.headers['cookie'], session.cookie);
        if (request.method == 'GET' &&
            request.url.path.endsWith('/api/deps/packages')) {
          packageReads++;
          return utf8Response(
            jsonEncode({
              'ok': true,
              'items': packageReads == 1
                  ? [
                      {'name': 'requests', 'version': '2.0'},
                    ]
                  : [],
              'page': 1,
              'pages': 1,
              'total': packageReads == 1 ? 1 : 0,
            }),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/api/deps/uninstall')) {
          expect(request.headers['x-csrf-token'], session.csrfToken);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['name'], 'requests');
          expect(body['request_id'], matches(RegExp(r'^[a-f0-9]{32}$')));
          return utf8Response(
            jsonEncode(_job(status: 'running', running: true)),
            200,
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/api/deps/install-log/${'b' * 32}')) {
          return utf8Response(
            jsonEncode(
              _job(
                status: 'succeeded',
                running: false,
                log: 'Uninstalled requests',
              ),
            ),
            200,
          );
        }
        fail('unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelRuntimeDepsView(
          manager: PanelRuntimeDepsManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('requests'));
    expect(find.widgetWithText(ListTile, 'requests'), findsOneWidget);
    expect(find.text('版本 2.0'), findsOneWidget);

    await tester.tap(find.byTooltip('卸载 requests'));
    await tester.pumpAndSettle();
    expect(find.text('卸载依赖？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '卸载'));
    await pumpUntilFound(tester, find.text('依赖卸载'));
    await pumpUntilFound(tester, find.text('Uninstalled requests'));

    expect(find.text('依赖卸载'), findsOneWidget);
    expect(find.text('Uninstalled requests'), findsOneWidget);
    expect(
      calls.where((value) => value.endsWith('/api/deps/uninstall')),
      hasLength(1),
    );

    await tester.pageBack();
    await pumpUntilFound(tester, find.text('暂无已安装依赖'));
    expect(find.text('暂无已安装依赖'), findsOneWidget);
    expect(packageReads, 2);
  });
}

Map<String, Object?> _job({
  required String status,
  required bool running,
  String log = '',
}) => {
  'ok': true,
  'install_id': 'b' * 32,
  'request_id': 'b' * 32,
  'kind': 'dependency',
  'operation': 'uninstall',
  'package': 'requests',
  'status': status,
  'status_label': status == 'running' ? '卸载中' : '卸载成功',
  'running': running,
  'returncode': status == 'succeeded' ? 0 : null,
  'error': '',
  'log': log,
  'retry_confirmation_required': false,
  'retry_available': false,
  'recovery_available': false,
  'cancel_status': '',
  'updated_at': 'now',
};
