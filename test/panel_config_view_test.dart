import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:fls_for_android/features/panel_config_view.dart';
import 'package:fls_for_android/models/panel_config.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_config_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_test_http.dart';

Map<String, Object?> _config() => {
  'ok': true,
  'settings': {
    'theme': 'deepseek',
    'port': 5700,
    'online_script_source': 'https://example.invalid/index.json',
    'online_script_source_requires_reveal': false,
    'log_cleanup_minutes': 30,
    'log_max_size_mb': 10,
    'log_keep_per_task': 10,
    'task_timeout_seconds': 1800,
    'random_delay_seconds': 0,
    'task_types': {'py': true, 'sh': true, 'js': false},
  },
  'revision': 'a' * 64,
  'schema': <String, Object?>{},
  'credentials': {
    'token_configured': true,
    'token_managed_by_environment': false,
    'totp_configured': false,
    'security_verify_enabled': false,
    'security_verify_type': 'code',
  },
  'apply': {'status': 'succeeded', 'message': '', 'error_count': 0},
};

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _launch(
  WidgetTester tester,
  PanelApiClient api, {
  PanelConfigRecovery? recovery,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PanelConfigView(
        manager: PanelConfigManager(api),
        recovery: recovery,
        onUnauthorized: (_) async {},
      ),
    ),
  );
  await pumpUntilFound(tester, _field('面板端口'));
}

Future<void> _confirmSave(WidgetTester tester) async {
  await tester.tap(find.text('保存配置'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认保存'));
}

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=config-widget',
    csrfToken: 'config-csrf',
  );

  testWidgets('native configuration saves a narrow changed-field patch', (
    tester,
  ) async {
    var writes = 0;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        if (request.method == 'GET') {
          return utf8Response(jsonEncode(_config()), 200);
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['settings'], {'theme': 'editorial'});
        expect(body['credentials'], isEmpty);
        writes++;
        return utf8Response(
          jsonEncode({
            'ok': true,
            'request_id': body['request_id'],
            'saved': true,
            'apply_status': 'succeeded',
            'revision': 'c' * 64,
            'reauth_required': false,
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelConfigView(
          manager: PanelConfigManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.byType(DropdownButtonFormField<String>));
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑杂志风').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await pumpUntilFound(tester, find.text('配置已保存并应用'));
    expect(writes, 1);
    expect(find.text('配置已保存并应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lost save response is queried, failed application only retries apply',
    (tester) async {
      var saves = 0;
      var applications = 0;
      var queries = 0;
      String? saveId;
      final config = _config();
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/api/config/settings') {
            return utf8Response(jsonEncode(config), 200);
          }
          if (request.method == 'GET') {
            queries++;
            expect(request.url.path, '/api/config/requests/$saveId');
            return utf8Response(
              jsonEncode({
                'ok': true,
                'request_id': saveId,
                'state': 'completed',
                'saved': true,
                'apply_status': 'failed',
                'revision': 'c' * 64,
                'reauth_required': false,
              }),
              200,
            );
          }
          final data = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path == '/api/config/settings') {
            saves++;
            saveId = data['request_id'] as String;
            (config['settings'] as Map)['port'] = 5701;
            config['revision'] = 'c' * 64;
            config['apply'] = {'status': 'failed', 'message': '应用失败'};
            throw http.ClientException('response lost');
          }
          expect(request.url.path, '/api/config/apply');
          applications++;
          expect(data['request_id'], isNot(saveId));
          expect(data['expected_revision'], 'c' * 64);
          config['apply'] = {'status': 'succeeded', 'message': ''};
          return utf8Response(
            jsonEncode({
              'ok': true,
              'request_id': data['request_id'],
              'saved': true,
              'apply_status': 'succeeded',
              'revision': 'c' * 64,
              'reauth_required': false,
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api);
      await tester.enterText(_field('面板端口'), '5701');
      await _confirmSave(tester);
      await pumpUntilFound(tester, find.text('重新应用'));
      await tester.tap(find.text('重新应用'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '重新应用'));
      await pumpUntil(tester, () => applications == 1);
      expect(saves, 1);
      expect(queries, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown response blocks new writes and a reopened page can query the original',
    (tester) async {
      var saves = 0;
      var queries = 0;
      var resolved = false;
      String? id;
      final recovery = PanelConfigRecovery();
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            saves++;
            id = (jsonDecode(request.body) as Map)['request_id'] as String;
            throw http.ClientException('response lost');
          }
          if (request.url.path.startsWith('/api/config/requests/')) {
            queries++;
            return utf8Response(
              jsonEncode({
                'ok': true,
                'request_id': id,
                'state': resolved ? 'completed' : 'missing',
                'saved': resolved ? true : null,
                if (resolved) ...{
                  'apply_status': 'succeeded',
                  'revision': 'a' * 64,
                  'reauth_required': true,
                },
              }),
              200,
            );
          }
          return utf8Response(jsonEncode(_config()), 200);
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api, recovery: recovery);
      await tester.enterText(_field('面板端口'), '5701');
      await _confirmSave(tester);
      await pumpUntilFound(tester, find.text('查询原提交'));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存配置'))
            .onPressed,
        isNull,
      );
      expect(recovery.requestId, id);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      resolved = true;
      await _launch(tester, api, recovery: recovery);
      await tester.tap(find.text('查询原提交'));
      await pumpUntil(tester, () => recovery.requestId == null);
      expect(saves, 1);
      expect(queries, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conflict merge keeps local port and adopts unrelated server delay',
    (tester) async {
      var saves = 0;
      final config = _config();
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient((request) async {
          if (request.method == 'GET') {
            return utf8Response(jsonEncode(config), 200);
          }
          final data = jsonDecode(request.body) as Map<String, dynamic>;
          saves++;
          expect(data['settings'], {'port': 5701});
          if (saves == 1) {
            config['revision'] = 'c' * 64;
            (config['settings'] as Map)['random_delay_seconds'] = 17;
            return utf8Response(
              jsonEncode({'ok': false, 'conflict': true, 'msg': '配置已变化'}),
              409,
            );
          }
          expect(data['expected_revision'], 'c' * 64);
          (config['settings'] as Map)['port'] = 5701;
          return utf8Response(
            jsonEncode({
              'ok': true,
              'request_id': data['request_id'],
              'saved': true,
              'apply_status': 'succeeded',
              'revision': 'c' * 64,
              'reauth_required': false,
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api);
      await tester.enterText(_field('面板端口'), '5701');
      await _confirmSave(tester);
      await pumpUntilFound(tester, find.text('查看冲突项'));
      await tester.tap(find.text('查看冲突项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留修改并合并'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_field('面板端口')).controller!.text, '5701');
      await _confirmSave(tester);
      await pumpUntil(tester, () => saves == 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'configuration remains reachable on narrow screens with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient(
          (request) async => utf8Response(jsonEncode(_config()), 200),
        ),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: PanelConfigView(
            manager: PanelConfigManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, _field('面板端口'));
      await tester.scrollUntilVisible(
        find.text('启用登录后安全验证'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('保存配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
