import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_notify_deliveries_view.dart';
import 'package:fls_for_android/features/panel_notify_view.dart';
import 'package:fls_for_android/models/panel_notify.dart';
import 'package:fls_for_android/models/panel_notify_delivery.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_notify_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_notify_test.dart'
    show notifySchemaFixture, notifyItemFixture, notifyPageFixture;
import 'panel_proxy_manager_test.dart' show proxySession;
import 'panel_test_http.dart';

Map<String, Object?> deliveryFixture({
  String status = 'unknown',
  int attempt = 1,
  bool reveal = false,
  bool truncated = false,
}) => {
  'id': 'd' * 32,
  'item_id': 'n',
  'item_name': 'Test channel',
  'channel': 'webhook',
  'source': 'test',
  'status': status,
  'version': 'b' * 64,
  'attempt': attempt,
  'retry_allowed': status == 'unknown' || status == 'failed',
  'content_truncated': truncated,
  'created_at': '2026-11-26 10:00:00',
  'updated_at': '2026-11-26 10:01:00',
  'item_exists': true,
  'item_enabled': true,
  'item_version': 'a' * 64,
  if (reveal) 'title': 'Test title',
  if (reveal) 'content': 'private task content',
};
Map<String, Object?> requestFixture(
  String id, {
  String status = 'unknown',
  int attempt = 1,
}) => {
  'ok': true,
  'request': {
    'request_id': id,
    'kind': 'test',
    'delivery_id': 'd' * 32,
    'item_id': 'n',
    'attempt': attempt,
    'status': status,
    'code': status == 'succeeded'
        ? 'accepted'
        : status == 'running'
        ? ''
        : 'timeout',
    'active': status == 'running',
    'historical': status != 'running',
    'history_available': true,
    'current_attempt': attempt,
    'current_matches': true,
  },
};
http.Response response(Object data, [int status = 200]) =>
    utf8Response(jsonEncode(data), status);
http.Response read(http.Request request) {
  if (request.url.path.endsWith('/schema')) {
    return response(notifySchemaFixture());
  }
  if (request.url.path.endsWith('/settings')) {
    return response(notifyPageFixture());
  }
  if (request.url.path.contains('/settings/')) {
    return response({'ok': true, 'item': notifyItemFixture()});
  }
  if (request.url.path.contains('/delivery-requests/')) {
    return response(requestFixture(request.url.path.split('/').last));
  }
  if (request.url.path.endsWith('/deliveries')) {
    return response({
      'ok': true,
      'items': [deliveryFixture()],
      'page': 1,
      'pages': 1,
      'total': 1,
    });
  }
  return response({
    'ok': true,
    'item': deliveryFixture(
      reveal: request.url.queryParameters['reveal'] == '1',
    ),
  });
}

PanelApiClient apiWith(Future<http.Response> Function(http.Request) handler) =>
    PanelApiClient(
      baseUrl: 'https://panel.example/fls',
      credentials: proxySession,
      client: panelMockClient(handler),
    );
Future<void> idle(WidgetTester tester) async {
  await pumpUntil(
    tester,
    () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
  await tester.pumpAndSettle();
}

Future<void> launchDetail(
  WidgetTester tester,
  PanelApiClient api, {
  PanelNotifyRecovery? recovery,
  String? requestId,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PanelNotifyDeliveryView(
        manager: PanelNotifyManager(api),
        recovery: recovery ?? PanelNotifyRecovery(),
        onUnauthorized: (_) async {},
        deliveryId: requestId == null ? 'd' * 32 : null,
        requestId: requestId,
      ),
    ),
  );
  await pumpUntilFound(tester, find.text('Test channel'));
  await idle(tester);
}

void main() {
  test('delivery DTOs reject raw secrets and inconsistent acceptance', () {
    expect(NotifyDelivery.parse(deliveryFixture()).status, 'unknown');
    for (final bad in [
      {...deliveryFixture(), 'message': 'raw upstream secret'},
      {...deliveryFixture(), 'content': 'raw body'},
      {...deliveryFixture(), 'attempt': 0},
      {...deliveryFixture(), 'status': 'succeeded', 'retry_allowed': true},
    ]) {
      expect(() => NotifyDelivery.parse(bad), throwsFormatException);
    }
    final raw = requestFixture('a' * 32, status: 'succeeded');
    (raw['request'] as Map)['code'] = 'timeout';
    expect(
      () => NotifyDeliveryRequest.parse(raw, 'a' * 32),
      throwsFormatException,
    );
  });

  test(
    'delivery manager preserves prefix session csrf and only GET recovers requests',
    () async {
      final requests = <http.Request>[];
      final api = apiWith((request) async {
        requests.add(request);
        expect(request.headers['cookie'], proxySession.cookie);
        if (request.method == 'POST') {
          expect(request.headers['x-csrf-token'], proxySession.csrfToken);
          final body = jsonDecode(request.body) as Map;
          expect(body['item_version'], 'a' * 64);
          if (request.url.path.endsWith('/retry')) {
            expect(body['expected_attempt'], 1);
            expect(body['version'], 'b' * 64);
            expect(body['confirm_truncated'], true);
          }
          return response(
            requestFixture(body['request_id'] as String, status: 'running'),
          );
        }
        return read(request);
      });
      addTearDown(api.close);
      final manager = PanelNotifyManager(api);
      final item = PanelNotifyItem.parse(notifyItemFixture());
      await manager.sendTest(item, 'a' * 32);
      await manager.deliveryStatus('a' * 32);
      final delivery = await manager.delivery('d' * 32);
      await manager.deliveryHistory(status: 'unknown', channel: 'webhook');
      await manager.retryDelivery(
        delivery,
        item,
        'b' * 32,
        confirmTruncated: true,
      );
      expect(requests.map((r) => r.method), [
        'POST',
        'GET',
        'GET',
        'GET',
        'POST',
      ]);
      expect(
        requests.every((r) => r.url.path.startsWith('/fls/api/notify/')),
        true,
      );
    },
  );

  testWidgets('lost test response opens original query without posting again', (
    tester,
  ) async {
    var posts = 0, queries = 0;
    String? id;
    final recovery = PanelNotifyRecovery();
    final api = apiWith((request) async {
      if (request.method == 'POST') {
        posts++;
        expect(request.url.path, '/fls/api/notify/deliveries/test');
        id = (jsonDecode(request.body) as Map)['request_id'] as String;
        throw http.ClientException('lost response');
      }
      if (request.url.path.contains('/delivery-requests/')) {
        queries++;
      }
      return read(request);
    });
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelNotifyView(
          manager: PanelNotifyManager(api),
          recovery: recovery,
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('Alpha'));
    await idle(tester);
    await tester.tap(find.byTooltip('通知操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送测试通知'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await pumpUntilFound(tester, find.text('查询原投递'));
    await idle(tester);
    expect(recovery.deliveryRequests, contains(id));
    expect(posts, 1);
    final before = queries;
    await tester.tap(find.text('查询原投递'));
    await pumpUntil(tester, () => queries > before);
    await idle(tester);
    expect(posts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rejected test preserves conflict message without retaining a missing request',
    (tester) async {
      final recovery = PanelNotifyRecovery();
      final api = apiWith((request) async {
        if (request.method == 'POST') {
          return response({
            'ok': false,
            'msg': '通知配置已变化，请核对当前渠道后重新确认',
            'accepted': false,
          }, 409);
        }
        return read(request);
      });
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PanelNotifyView(
            manager: PanelNotifyManager(api),
            recovery: recovery,
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('Alpha'));
      await idle(tester);
      await tester.tap(find.byTooltip('通知操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送测试通知'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认发送'));
      await pumpUntilFound(tester, find.textContaining('通知配置已变化'));
      await idle(tester);
      expect(recovery.deliveryRequests, isEmpty);
      expect(find.text('投递详情'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'active request only polls GET and page disposal leaves server work running',
    (tester) async {
      var queries = 0;
      final methods = <String>[];
      final api = apiWith((request) async {
        methods.add(request.method);
        if (request.url.path.contains('/delivery-requests/')) {
          queries++;
          return response(requestFixture('a' * 32, status: 'running'));
        }
        return response({
          'ok': true,
          'item': deliveryFixture(status: 'running'),
        });
      });
      addTearDown(api.close);
      await launchDetail(tester, api, requestId: 'a' * 32);
      final initial = queries;
      await tester.pump(const Duration(seconds: 2));
      await pumpUntil(tester, () => queries > initial);
      await idle(tester);
      await tester.pumpWidget(const SizedBox());
      final afterClose = queries;
      await tester.pump(const Duration(seconds: 5));
      expect(queries, afterClose);
      expect(methods.every((method) => method == 'GET'), true);
    },
  );

  testWidgets(
    'detail reveals body explicitly and drops it when returning from background',
    (tester) async {
      final api = apiWith((request) async => read(request));
      addTearDown(api.close);
      await launchDetail(tester, api);
      expect(find.text('private task content'), findsNothing);
      await tester.tap(find.text('查看投递正文'));
      await pumpUntilFound(tester, find.text('private task content'));
      await idle(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.text('private task content'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpUntilFound(tester, find.text('查看投递正文'));
      await idle(tester);
      expect(find.text('private task content'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'body response from before background never reveals on resumed page',
    (tester) async {
      final pending = Completer<http.Response>();
      var revealStarted = false;
      final api = apiWith((request) async {
        if (request.url.queryParameters['reveal'] == '1') {
          revealStarted = true;
          return pending.future;
        }
        return read(request);
      });
      addTearDown(api.close);
      await launchDetail(tester, api);
      await tester.tap(find.text('查看投递正文'));
      await pumpUntil(tester, () => revealStarted);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      pending.complete(
        response({'ok': true, 'item': deliveryFixture(reveal: true)}),
      );
      await pumpUntilFound(tester, find.text('查看投递正文'));
      await idle(tester);
      expect(find.text('private task content'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit retry confirms current channel version and truncated attempt',
    (tester) async {
      Map? submitted;
      final api = apiWith((request) async {
        if (request.method == 'POST') {
          submitted = jsonDecode(request.body) as Map;
          return response(
            requestFixture(
              submitted!['request_id'] as String,
              status: 'succeeded',
              attempt: 2,
            ),
          );
        }
        if (request.url.path.contains('/delivery-requests/')) {
          return response(
            requestFixture(
              request.url.path.split('/').last,
              status: 'succeeded',
              attempt: 2,
            ),
          );
        }
        if (request.url.path.contains('/deliveries/')) {
          return response({
            'ok': true,
            'item': deliveryFixture(truncated: true),
          });
        }
        return read(request);
      });
      addTearDown(api.close);
      await launchDetail(tester, api);
      await tester.tap(find.text('重新选择渠道并投递'));
      await pumpUntilFound(tester, find.text('Alpha'));
      await pumpUntil(
        tester,
        () => find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(LinearProgressIndicator),
            )
            .evaluate()
            .isEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Alpha'));
      await pumpUntilFound(tester, find.text('确认重新投递'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('将只发送截断后的内容'), findsOneWidget);
      await tester.tap(find.text('确认重新投递'));
      await pumpUntil(tester, () => submitted != null);
      await idle(tester);
      expect(submitted!['expected_attempt'], 1);
      expect(submitted!['item_version'], 'a' * 64);
      expect(submitted!['confirm_truncated'], true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unauthorized nested request exits and retains only original request identity',
    (tester) async {
      final recovery = PanelNotifyRecovery();
      String? id;
      final api = apiWith((request) async {
        if (request.method == 'POST') {
          id = (jsonDecode(request.body) as Map)['request_id'] as String;
          return response({'ok': false, 'msg': 'expired'}, 401);
        }
        return read(request);
      });
      addTearDown(api.close);
      var expired = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => PanelNotifyView(
                      manager: PanelNotifyManager(api),
                      recovery: recovery,
                      onUnauthorized: (_) async {
                        expired++;
                      },
                    ),
                  ),
                ),
                child: const Text('Open notifications'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open notifications'));
      await pumpUntilFound(tester, find.text('Alpha'));
      await idle(tester);
      await tester.tap(find.byTooltip('通知操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送测试通知'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认发送'));
      await pumpUntilFound(tester, find.text('Open notifications'));
      await tester.pumpAndSettle();
      expect(expired, 1);
      expect(recovery.deliveryRequests, {id});
      expect(find.text('通知渠道'), findsNothing);
    },
  );

  testWidgets(
    'narrow large text history scrolls retained recovery requests and records',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final recovery = PanelNotifyRecovery();
      for (var index = 0; index < 8; index++) {
        recovery.deliveryRequests.add(index.toRadixString(16).padLeft(32, '0'));
      }
      final api = apiWith((request) async => read(request));
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: PanelNotifyDeliveriesView(
            manager: PanelNotifyManager(api),
            recovery: recovery,
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('原投递请求 (8)'));
      await idle(tester);
      await tester.scrollUntilVisible(
        find.text('Test channel'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Test channel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
