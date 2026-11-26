import 'dart:convert';

import 'package:fls_for_android/features/panel_proxy_view.dart';
import 'package:fls_for_android/models/panel_proxy.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_proxy_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_proxy_manager_test.dart'
    show proxyFixture, proxyPageFixture, proxySession;
import 'panel_test_http.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _launch(
  WidgetTester tester,
  PanelApiClient api, {
  PanelProxyRecovery? recovery,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PanelProxyView(
        manager: PanelProxyManager(api),
        recovery: recovery,
        onUnauthorized: (_) async {},
      ),
    ),
  );
  await pumpUntilFound(tester, find.text('Alpha'));
}

Future<void> _edit(WidgetTester tester) async {
  await tester.tap(find.text('Alpha'));
  await pumpUntilFound(tester, _field('代理名称'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('保存代理'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认保存'));
}

void main() {
  testWidgets('proxy editor saves only local changes and keeps credentials', (
    tester,
  ) async {
    var writes = 0;
    final proxy = proxyFixture();
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: proxySession,
      client: panelMockClient((request) async {
        if (request.method == 'POST') {
          final data = jsonDecode(request.body) as Map;
          expect(data['settings'], {'name': 'Edited'});
          expect(data['credentials'], isEmpty);
          writes++;
          proxy['name'] = 'Edited';
          return utf8Response(
            jsonEncode({
              'ok': true,
              'request_id': data['request_id'],
              'saved': true,
              'proxy_id': 'p',
            }),
            200,
          );
        }
        return utf8Response(
          jsonEncode(
            request.url.path.endsWith('/settings/p')
                ? {'ok': true, 'proxy': proxy}
                : proxyPageFixture(proxy),
          ),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await _launch(tester, api);
    await _edit(tester);
    await tester.enterText(_field('代理名称'), 'Edited');
    await _save(tester);
    await pumpUntilFound(tester, find.text('代理已保存'));
    expect(writes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lost response recovers by GET without repeating mutation', (
    tester,
  ) async {
    var writes = 0, queries = 0;
    String? id;
    final recovery = PanelProxyRecovery();
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: proxySession,
      client: panelMockClient((request) async {
        if (request.method == 'POST') {
          writes++;
          id = (jsonDecode(request.body) as Map)['request_id'] as String;
          throw http.ClientException('lost response');
        }
        if (request.url.path.contains('/requests/')) {
          queries++;
          return utf8Response(
            jsonEncode({
              'ok': true,
              'request_id': id,
              'saved': true,
              'state': 'completed',
              'proxy_id': 'p',
              'resolved': true,
              'retry_allowed': false,
              'current_matches': true,
              'confirm_required': false,
            }),
            200,
          );
        }
        return utf8Response(
          jsonEncode(
            request.url.path.endsWith('/settings/p')
                ? {'ok': true, 'proxy': proxyFixture()}
                : proxyPageFixture(proxyFixture()),
          ),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await _launch(tester, api, recovery: recovery);
    await _edit(tester);
    await tester.enterText(_field('代理名称'), 'Edited');
    await _save(tester);
    await pumpUntilFound(tester, find.text('代理已保存'));
    expect(writes, 1);
    expect(queries, 1);
    expect(recovery.requestId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown request blocks writes and survives closing editor', (
    tester,
  ) async {
    var writes = 0;
    final recovery = PanelProxyRecovery();
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: proxySession,
      client: panelMockClient((request) async {
        if (request.method == 'POST') {
          writes++;
          throw http.ClientException('lost response');
        }
        if (request.url.path.contains('/requests/')) {
          return utf8Response(
            jsonEncode({
              'ok': true,
              'request_id': recovery.requestId,
              'saved': null,
              'state': 'unknown',
              'resolved': false,
              'retry_allowed': false,
            }),
            200,
          );
        }
        return utf8Response(
          jsonEncode(
            request.url.path.endsWith('/settings/p')
                ? {'ok': true, 'proxy': proxyFixture()}
                : proxyPageFixture(proxyFixture()),
          ),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await _launch(tester, api, recovery: recovery);
    await _edit(tester);
    await tester.enterText(_field('代理名称'), 'Edited');
    await _save(tester);
    await pumpUntilFound(tester, find.text('原提交结果仍未知，暂不能再次保存'));
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存代理'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('返回代理列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('离开'));
    await pumpUntilFound(tester, find.text('有未确认的代理提交'));
    await tester.pumpAndSettle();
    expect(recovery.requestId, isNotNull);
    await tester.tap(find.text('查询原提交'));
    await pumpUntilFound(tester, find.text('原提交结果仍未知，暂不能发起新操作'));
    expect(writes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('conflict merge preserves local name and server host', (
    tester,
  ) async {
    var writes = 0;
    var changed = false;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: proxySession,
      client: panelMockClient((request) async {
        if (request.method == 'POST') {
          writes++;
          final data = jsonDecode(request.body) as Map;
          if (writes == 1) {
            changed = true;
            return utf8Response(
              jsonEncode({
                'ok': false,
                'msg': '代理设置已变化',
                'saved': false,
                'resolved': true,
                'conflict': true,
              }),
              409,
            );
          }
          expect(data['version'], 'c' * 64);
          expect(data['settings'], {'name': 'Local'});
          return utf8Response(
            jsonEncode({
              'ok': true,
              'request_id': data['request_id'],
              'saved': true,
              'proxy_id': 'p',
            }),
            200,
          );
        }
        return utf8Response(
          jsonEncode(
            request.url.path.endsWith('/settings/p')
                ? {
                    'ok': true,
                    'proxy': proxyFixture(
                      host: changed ? 'server.example' : 'localhost',
                      version: changed ? 'c' * 64 : 'a' * 64,
                    ),
                  }
                : proxyPageFixture(proxyFixture()),
          ),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await _launch(tester, api);
    await _edit(tester);
    await tester.enterText(_field('代理名称'), 'Local');
    await _save(tester);
    await pumpUntilFound(tester, find.text('核对当前代理'));
    await tester.tap(find.text('核对当前代理'));
    await pumpUntilFound(tester, find.text('合并本地改动'));
    await tester.tap(find.text('合并本地改动'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_field('代理名称')).controller!.text, 'Local');
    expect(
      tester.widget<TextField>(_field('代理 Host')).controller!.text,
      'server.example',
    );
    await _save(tester);
    await pumpUntilFound(tester, find.text('代理已保存'));
    expect(writes, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'referenced proxy cannot be disabled and the result remains visible',
    (tester) async {
      var writes = 0;
      final recovery = PanelProxyRecovery();
      final proxy = {...proxyFixture(), 'reference_count': 1};
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            final body = jsonDecode(request.body) as Map;
            expect(body['action'], 'toggle');
            expect(body['enabled'], false);
            expect(body['version'], 'a' * 64);
            writes++;
            return utf8Response(
              jsonEncode({
                'ok': false,
                'msg': '代理仍被任务引用',
                'saved': false,
                'resolved': true,
                'reference_count': 1,
                'references': [
                  {'id': 't', 'name': 'Referenced task'},
                ],
              }),
              409,
            );
          }
          return utf8Response(jsonEncode(proxyPageFixture(proxy)), 200);
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api, recovery: recovery);
      await tester.tap(find.byTooltip('Alpha 操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('停用代理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await pumpUntilFound(tester, find.textContaining('Referenced task'));
      expect(writes, 1);
      expect(recovery.requestId, isNull);
      expect(find.textContaining('已启用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'prepared receipt is retried only after confirmation with original id',
    (tester) async {
      var writes = 0;
      String? id;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            final body = jsonDecode(request.body) as Map;
            writes++;
            if (writes == 1) {
              id = body['request_id'] as String;
              return utf8Response(
                jsonEncode({
                  'ok': false,
                  'msg': '保存中断',
                  'saved': false,
                  'confirm_required': true,
                }),
                500,
              );
            }
            expect(body['request_id'], id);
            expect(body['confirm_retry'], true);
            expect(body['settings'], {'name': 'Edited'});
            return utf8Response(
              jsonEncode({
                'ok': true,
                'request_id': id,
                'saved': true,
                'proxy_id': 'p',
              }),
              200,
            );
          }
          if (request.url.path.contains('/requests/')) {
            return utf8Response(
              jsonEncode({
                'ok': true,
                'request_id': id,
                'saved': false,
                'proxy_id': 'p',
                'resolved': true,
                'state': 'prepared',
                'retry_allowed': true,
                'confirm_required': true,
                'current_matches': false,
              }),
              200,
            );
          }
          return utf8Response(
            jsonEncode(
              request.url.path.endsWith('/settings/p')
                  ? {'ok': true, 'proxy': proxyFixture()}
                  : proxyPageFixture(proxyFixture()),
            ),
            200,
          );
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api);
      await _edit(tester);
      await tester.enterText(_field('代理名称'), 'Edited');
      await _save(tester);
      await pumpUntilFound(tester, find.text('重试原提交'));
      expect(writes, 1);
      await tester.tap(find.text('重试原提交'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认重试'));
      await pumpUntilFound(tester, find.text('代理已保存'));
      expect(writes, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unauthorized editor leaves nested pages and retains only recovery id',
    (tester) async {
      var expired = 0;
      final recovery = PanelProxyRecovery();
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            return utf8Response(
              jsonEncode({'ok': false, 'msg': 'expired'}),
              401,
            );
          }
          return utf8Response(
            jsonEncode(
              request.url.path.endsWith('/settings/p')
                  ? {'ok': true, 'proxy': proxyFixture()}
                  : proxyPageFixture(proxyFixture()),
            ),
            200,
          );
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PanelProxyView(
                      manager: PanelProxyManager(api),
                      recovery: recovery,
                      onUnauthorized: (_) async {
                        expired++;
                      },
                    ),
                  ),
                ),
                child: const Text('打开代理'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开代理'));
      await pumpUntilFound(tester, find.text('Alpha'));
      await _edit(tester);
      await tester.enterText(_field('代理名称'), 'Sensitive draft');
      await _save(tester);
      await pumpUntilFound(tester, find.text('打开代理'));
      await tester.pumpAndSettle();
      expect(expired, 1);
      expect(recovery.requestId, isNotNull);
      expect(find.byType(PanelProxyView), findsNothing);
      expect(find.text('Sensitive draft'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow large-text proxy editor keeps save control reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: proxySession,
      client: panelMockClient(
        (request) async => utf8Response(
          jsonEncode(
            request.url.path.endsWith('/settings/p')
                ? {'ok': true, 'proxy': proxyFixture()}
                : proxyPageFixture(proxyFixture()),
          ),
          200,
        ),
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
        home: PanelProxyView(
          manager: PanelProxyManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('Alpha'));
    await tester.ensureVisible(find.text('Alpha'));
    await tester.tap(find.text('Alpha'));
    await pumpUntilFound(tester, _field('代理名称'));
    await tester.pumpAndSettle();
    expect(find.text('保存代理'), findsOneWidget);
    expect(
      tester.getRect(find.widgetWithText(FilledButton, '保存代理')).bottom,
      lessThanOrEqualTo(640),
    );
    expect(tester.takeException(), isNull);
  });
}
