import 'dart:convert';

import 'package:fls_for_android/features/panel_proxy_checks_view.dart';
import 'package:fls_for_android/models/panel_proxy.dart';
import 'package:fls_for_android/models/panel_proxy_check.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_proxy_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_proxy_manager_test.dart' show proxyFixture, proxySession;
import 'panel_test_http.dart';

Map<String, Object?> checkFixture({
  String? id,
  String status = 'succeeded',
  String source = 'saved',
  String name = 'Alpha',
  String? proxyId,
}) => {
  'id': id ?? 'b' * 32,
  'request_id': id ?? 'b' * 32,
  'source': source,
  'proxy_id': proxyId ?? 'p',
  'proxy_name': name,
  'proxy_type': 'http',
  'version': 'a' * 64,
  'kind': 'test',
  'targets': ['https://example.com'],
  'status': status,
  'error_code': '',
  'created_at': '2026-11-26 10:00:00',
  'updated_at': '2026-11-26 10:00:01',
  'retry_of': '',
  'proxy_exists': true,
  'current_matches': true,
  'retry_allowed': source != 'draft' && status != 'running',
  'completed': status == 'running' ? 0 : 1,
  'total': 1,
  'items': [
    <String, Object?>{
      'target': 'https://example.com',
      'mode': 'http',
      'status': status == 'running' ? 'running' : 'succeeded',
      'reachable': status == 'running' ? null : true,
      'http_success': status == 'running' ? null : false,
      'status_code': status == 'running' ? null : 503,
      'elapsed_ms': status == 'running' ? null : 12,
      'error_code': '',
    },
  ],
};

void main() {
  test(
    'check DTO rejects secrets, malformed identity and invented progress',
    () {
      final check = PanelProxyCheck.fromJson(checkFixture());
      expect(check.items.single.statusCode, 503);
      expect(check.items.single.reachable, true);
      expect(check.items.single.httpSuccess, false);
      for (final changes in <Map<String, Object?>>[
        {'password': 'secret'},
        {'status': 'done'},
        {'completed': 2},
        {'total': 0},
        {'request_id': 'c' * 32},
        {
          'targets': ['https://user:secret@example.com'],
        },
        {
          'targets': ['https://example.com/?token=secret'],
        },
        {'retry_allowed': 1},
      ]) {
        expect(
          () => PanelProxyCheck.fromJson({...checkFixture(), ...changes}),
          throwsFormatException,
        );
      }
      final malformed = checkFixture();
      (malformed['items'] as List).single['elapsed_ms'] = -1;
      expect(() => PanelProxyCheck.fromJson(malformed), throwsFormatException);
    },
  );

  test(
    'checks preserve session, CSRF, prefix, body, history filter and explicit retry',
    () async {
      final calls = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/fls',
        credentials: proxySession,
        client: panelMockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          expect(request.headers['cookie'], proxySession.cookie);
          if (request.method == 'POST') {
            expect(request.headers['x-csrf-token'], proxySession.csrfToken);
            final body = jsonDecode(request.body) as Map;
            if (request.url.path.endsWith('/retry')) {
              expect(body, {'request_id': 'c' * 32, 'version': 'a' * 64});
            } else {
              expect(body['draft'], {
                'settings': {'host': 'draft.example'},
                'credentials': {
                  'password_action': 'replace',
                  'password': 'secret',
                },
              });
            }
            return utf8Response(
              jsonEncode({
                'ok': true,
                'check': checkFixture(id: body['request_id'] as String),
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/checks')) {
            expect(request.url.queryParameters['proxy_id'], 'p');
            expect(request.url.queryParameters['kind'], 'quality');
            expect(request.url.queryParameters['status'], 'partial');
            return utf8Response(
              jsonEncode({
                'ok': true,
                'items': [checkFixture()],
                'page': 1,
                'pages': 1,
                'total': 1,
              }),
              200,
            );
          }
          return utf8Response(
            jsonEncode({'ok': true, 'check': checkFixture()}),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelProxyManager(api);
      await manager.startCheck({
        'request_id': 'b' * 32,
        'kind': 'test',
        'proxy_id': 'p',
        'version': 'a' * 64,
        'draft': {
          'settings': {'host': 'draft.example'},
          'credentials': {'password_action': 'replace', 'password': 'secret'},
        },
      });
      expect((await manager.check('b' * 32)).id, 'b' * 32);
      expect(
        (await manager.checkHistory(
          proxyId: 'p',
          kind: 'quality',
          status: 'partial',
        )).total,
        1,
      );
      expect(
        (await manager.retryCheck(
          'b' * 32,
          requestId: 'c' * 32,
          version: 'a' * 64,
        )).id,
        'c' * 32,
      );
      expect(calls, [
        'POST /fls/api/proxy/checks',
        'GET /fls/api/proxy/checks/${'b' * 32}',
        'GET /fls/api/proxy/checks',
        'POST /fls/api/proxy/checks/${'b' * 32}/retry',
      ]);
    },
  );

  test(
    'draft errors redact nested credentials and expose only safe acceptance',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient(
          (request) async => utf8Response(
            jsonEncode({
              'ok': false,
              'msg': 'private-name private-password',
              'accepted': false,
              'current': {'password': 'other-secret'},
            }),
            400,
          ),
        ),
      );
      addTearDown(api.close);
      try {
        await PanelProxyManager(api).startCheck({
          'request_id': 'b' * 32,
          'kind': 'test',
          'draft': {
            'credentials': {
              'username_action': 'replace',
              'username': 'private-name',
              'password_action': 'replace',
              'password': 'private-password',
            },
          },
        });
        fail('expected rejection');
      } on PanelApiException catch (error) {
        expect(error.message, isNot(contains('private-name')));
        expect(error.message, isNot(contains('private-password')));
        expect(error.data, {'accepted': false});
      }
    },
  );

  testWidgets(
    'lost start response queries original ID without replay and clears draft',
    (tester) async {
      var starts = 0, reads = 0;
      final recovery = PanelProxyRecovery();
      final body = <String, Object?>{
        'request_id': 'b' * 32,
        'kind': 'test',
        'draft': {
          'credentials': {'password': 'secret'},
        },
      };
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            starts++;
            throw http.ClientException('response lost');
          }
          reads++;
          expect(request.url.path, '/api/proxy/checks/${'b' * 32}');
          return utf8Response(
            jsonEncode({'ok': true, 'check': checkFixture(source: 'draft')}),
            200,
          );
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PanelProxyCheckView(
            manager: PanelProxyManager(api),
            recovery: recovery,
            id: 'b' * 32,
            submission: body,
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('查询原检测'));
      expect(body, isEmpty);
      expect(recovery.checkIds, {'b' * 32});
      await tester.tap(find.text('查询原检测'));
      await pumpUntilFound(tester, find.text('HTTP 503 · 目标返回非成功状态'));
      expect(starts, 1);
      expect(reads, 1);
      expect(recovery.checkIds, isEmpty);
      expect(find.text('网络可达'), findsOneWidget);
      expect(find.text('重新检测当前代理'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('active check polls GET and disposal never cancels server work', (
    tester,
  ) async {
    var reads = 0;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: proxySession,
      client: panelMockClient((request) async {
        expect(request.method, 'GET');
        reads++;
        return utf8Response(
          jsonEncode({'ok': true, 'check': checkFixture(status: 'running')}),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelProxyCheckView(
          manager: PanelProxyManager(api),
          recovery: PanelProxyRecovery(),
          id: 'b' * 32,
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('已完成 0 / 1'));
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(reads, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
    final before = reads;
    await tester.pump(const Duration(seconds: 5));
    expect(reads, before);
  });

  testWidgets('history filters and unknown request recovery remain read only', (
    tester,
  ) async {
    final recovery = PanelProxyRecovery()..checkIds.add('b' * 32);
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: proxySession,
      client: panelMockClient((request) async {
        expect(request.method, 'GET');
        if (request.url.path.endsWith('/checks')) {
          expect(request.url.queryParameters['proxy_id'], 'p');
          return utf8Response(
            jsonEncode({
              'ok': true,
              'items': [checkFixture(status: 'unknown')],
              'page': 1,
              'pages': 1,
              'total': 1,
            }),
            200,
          );
        }
        return utf8Response(
          jsonEncode({'ok': true, 'check': checkFixture(status: 'unknown')}),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelProxyChecksView(
          manager: PanelProxyManager(api),
          recovery: recovery,
          proxyId: 'p',
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('Alpha'));
    await tester.tap(find.text('查询未确认检测'));
    await pumpUntilFound(tester, find.text('代理检测结果'));
    await pumpUntilFound(tester, find.text('连接检测 · 结果未知'));
    expect(recovery.checkIds, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'batch preserves successful items when one submission is rejected',
    (tester) async {
      final posts = <String>[];
      final recovery = PanelProxyRecovery();
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          posts.add(body['proxy_id'] as String);
          if (body['proxy_id'] == 'bad') {
            return utf8Response(
              jsonEncode({'ok': false, 'accepted': false, 'msg': '代理已变化'}),
              409,
            );
          }
          return utf8Response(
            jsonEncode({
              'ok': true,
              'check': checkFixture(id: body['request_id'] as String),
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PanelProxyBatchCheckView(
            manager: PanelProxyManager(api),
            recovery: recovery,
            options: const ProxyCheckOptions('test', null),
            proxies: [
              PanelProxy.fromJson(proxyFixture()),
              PanelProxy.fromJson(proxyFixture(id: 'bad', name: 'Changed')),
            ],
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('已处理 2 / 2'));
      expect(posts, ['p', 'bad']);
      expect(recovery.checkIds, isEmpty);
      expect(find.text('代理已变化'), findsOneWidget);
      expect(find.text('检测完成 · 1/1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'check detail fits narrow large text and rechecks current version explicitly',
    (tester) async {
      tester.view.physicalSize = const Size(320, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var retries = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.url.path.endsWith('/settings/p')) {
            return utf8Response(
              jsonEncode({
                'ok': true,
                'proxy': proxyFixture(version: 'c' * 64),
              }),
              200,
            );
          }
          if (request.method == 'POST') {
            retries++;
            final body = jsonDecode(request.body) as Map;
            expect(body['version'], 'c' * 64);
            expect(body['request_id'], isNot('b' * 32));
            return utf8Response(
              jsonEncode({
                'ok': true,
                'check': checkFixture(
                  id: body['request_id'] as String,
                  name: 'Retried',
                ),
              }),
              200,
            );
          }
          return utf8Response(
            jsonEncode({'ok': true, 'check': checkFixture()}),
            200,
          );
        }),
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
          home: PanelProxyCheckView(
            manager: PanelProxyManager(api),
            recovery: PanelProxyRecovery(),
            id: 'b' * 32,
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('Alpha'));
      await tester.scrollUntilVisible(
        find.text('重新检测当前代理'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('重新检测当前代理'));
      await pumpUntilFound(tester, find.text('重新检测当前代理？'));
      expect(retries, 0);
      await tester.tap(find.text('重新检测'));
      await pumpUntil(tester, () => retries == 1);
      await pumpUntilFound(tester, find.text('Retried'));
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('401 stops check polling and retains only request identity', (
    tester,
  ) async {
    var expired = 0;
    final recovery = PanelProxyRecovery();
    final body = <String, Object?>{
      'request_id': 'b' * 32,
      'kind': 'test',
      'draft': {
        'credentials': {'password': 'secret'},
      },
    };
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: proxySession,
      client: panelMockClient(
        (request) async => utf8Response('{"ok":false}', 401),
      ),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelProxyCheckView(
          manager: PanelProxyManager(api),
          recovery: recovery,
          id: 'b' * 32,
          submission: body,
          onUnauthorized: (_) async {
            expired++;
          },
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(expired, 1);
    expect(body, isEmpty);
    expect(recovery.checkIds, {'b' * 32});
    await tester.pumpWidget(const SizedBox());
  });
}
