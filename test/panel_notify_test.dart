import 'dart:convert';

import 'package:fls_for_android/features/panel_notify_view.dart';
import 'package:fls_for_android/models/panel_notify.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_notify_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_proxy_manager_test.dart' show proxySession;
import 'panel_test_http.dart';

Map<String, Object?> notifySchemaFixture() => {
  'ok': true,
  'channels': [
    {
      'id': 'webhook',
      'name': '自定义 Webhook',
      'fields': [
        {
          'key': 'WEBHOOK_URL',
          'label': '请求 URL',
          'kind': 'secret',
          'sensitive': true,
          'multiline': false,
          'max_length': 4096,
          'options': <String>[],
        },
        {
          'key': 'WEBHOOK_METHOD',
          'label': '请求方法',
          'kind': 'select',
          'sensitive': false,
          'multiline': false,
          'max_length': 500,
          'options': ['POST', 'GET', 'PATCH'],
        },
        {
          'key': 'WEBHOOK_BODY',
          'label': '请求体',
          'kind': 'secret',
          'sensitive': true,
          'multiline': true,
          'max_length': 16384,
          'options': <String>[],
        },
      ],
    },
    {
      'id': 'telegram',
      'name': 'Telegram Bot',
      'fields': [
        {
          'key': 'TG_BOT_TOKEN',
          'label': 'Bot Token',
          'kind': 'secret',
          'sensitive': true,
          'multiline': false,
          'max_length': 4096,
          'options': <String>[],
        },
      ],
    },
  ],
};

Map<String, Object?> notifyItemFixture({
  String id = 'n',
  String name = 'Alpha',
  String? version,
  String method = 'POST',
}) => {
  'id': id,
  'name': name,
  'channel': 'webhook',
  'enabled': true,
  'default': id == 'n',
  'version': version ?? 'a' * 64,
  'log_mode': 'full',
  'reference_count': 0,
  'values': {'WEBHOOK_METHOD': method},
  'configured': {'WEBHOOK_URL': true, 'WEBHOOK_BODY': true},
  'invalid_fields': <String>[],
};

Map<String, Object?> notifyPageFixture() => {
  'ok': true,
  'items': [notifyItemFixture(), notifyItemFixture(id: 'b', name: 'Beta')],
  'page': 1,
  'pages': 1,
  'total': 2,
};

http.Response _json(Object? data, [int status = 200]) =>
    utf8Response(jsonEncode(data), status);

http.Response _read(http.Request request) {
  if (request.url.path.endsWith('/schema')) return _json(notifySchemaFixture());
  if (request.url.path.endsWith('/defaults')) {
    return _json({
      'ok': true,
      'default_ids': ['n'],
      'version': 'd' * 64,
    });
  }
  if (request.url.path.endsWith('/settings/n')) {
    return _json({'ok': true, 'item': notifyItemFixture()});
  }
  return _json(notifyPageFixture());
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Finder _editorScroll() => find
    .descendant(
      of: find.byType(ListView).last,
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _launch(
  WidgetTester tester,
  PanelApiClient api, {
  PanelNotifyRecovery? recovery,
}) async {
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
  await tester.pumpAndSettle();
}

Future<void> _edit(WidgetTester tester) async {
  await tester.tap(find.text('Alpha'));
  await pumpUntilFound(tester, _field('通知名称'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('保存通知'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认保存'));
}

void main() {
  test(
    'notification DTOs reject readable secrets and inconsistent receipts',
    () {
      expect(NotifyChannel.schema(notifySchemaFixture()).length, 2);
      for (final item in [
        {
          ...notifyItemFixture(),
          'config': {'WEBHOOK_URL': 'private'},
        },
        {
          ...notifyItemFixture(),
          'values': {'WEBHOOK_URL': 'private'},
        },
        {...notifyItemFixture(), 'enabled': 1},
        {...notifyItemFixture(), 'version': 'bad'},
      ]) {
        expect(
          () => PanelNotifyItem.parse(item, detail: true),
          throwsFormatException,
        );
      }
      final schema = notifySchemaFixture();
      final channel = (schema['channels'] as List).first as Map;
      ((channel['fields'] as List).first as Map)['sensitive'] = false;
      expect(() => NotifyChannel.schema(schema), throwsFormatException);
      expect(
        () => NotifyResult.parse(
          {
            'ok': true,
            'request_id': 'a' * 32,
            'saved': null,
            'resolved': false,
            'state': 'completed',
            'retry_allowed': true,
          },
          'a' * 32,
          query: true,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'notification manager preserves subdirectory session and only queries unknown writes',
    () async {
      final methods = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/fls',
        credentials: proxySession,
        client: panelMockClient((request) async {
          methods.add(request.method);
          expect(request.headers['cookie'], proxySession.cookie);
          if (request.method == 'POST') {
            expect(request.headers['x-csrf-token'], proxySession.csrfToken);
            expect(request.url.path, '/fls/api/notify/settings');
            return _json({
              'ok': true,
              'request_id': 'a' * 32,
              'saved': true,
              'resolved': true,
            });
          }
          if (request.url.path.contains('/requests/')) {
            return _json({
              'ok': true,
              'request_id': 'a' * 32,
              'saved': null,
              'resolved': false,
              'state': 'unknown',
              'retry_allowed': false,
            });
          }
          return _read(request);
        }),
      );
      addTearDown(api.close);
      final manager = PanelNotifyManager(api);
      expect((await manager.schema()).length, 2);
      expect((await manager.fetch('n')).configured['WEBHOOK_URL'], true);
      expect((await manager.fetchPage(query: 'Alpha')).total, 2);
      expect(
        (await manager.submit({
          'request_id': 'a' * 32,
          'action': 'edit',
          'item_id': 'n',
          'version': 'a' * 64,
        })).saved,
        true,
      );
      expect((await manager.status('a' * 32)).saved, isNull);
      expect(methods, ['GET', 'GET', 'GET', 'POST', 'GET']);
    },
  );

  test(
    'notification errors redact credential values and omit raw configuration',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/fls',
        credentials: proxySession,
        client: panelMockClient(
          (request) async => _json({
            'ok': false,
            'msg': 'private-address private-body',
            'saved': false,
            'resolved': true,
            'conflict': true,
            'current': {
              'config': {'WEBHOOK_URL': 'another-secret'},
            },
            'reference_count': 1,
            'references': [
              {'id': 't', 'name': 'Task', 'config': 'private'},
            ],
          }, 409),
        ),
      );
      addTearDown(api.close);
      try {
        await PanelNotifyManager(api).submit({
          'action': 'edit',
          'request_id': 'a' * 32,
          'credentials': {
            'WEBHOOK_URL': {'action': 'replace', 'value': 'private-address'},
            'WEBHOOK_BODY': {'action': 'replace', 'value': 'private-body'},
          },
        });
        fail('expected conflict');
      } on PanelApiException catch (error) {
        expect(error.message, isNot(contains('private-address')));
        expect(error.message, isNot(contains('private-body')));
        expect(error.data?['conflict'], true);
        expect(error.data?.containsKey('current'), false);
        expect(error.data?['references'], [
          {'id': 't', 'name': 'Task'},
        ]);
      }
    },
  );

  testWidgets(
    'notification editor saves a partial name change without sending or reading credentials',
    (tester) async {
      var saves = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            saves++;
            expect(request.url.path, '/api/notify/settings');
            final body = jsonDecode(request.body) as Map;
            expect(body['settings'], {'name': 'Local name'});
            expect(body['values'], isEmpty);
            expect(body['credentials'], isEmpty);
            expect(body.containsKey('test'), false);
            return _json({
              'ok': true,
              'request_id': body['request_id'],
              'saved': true,
              'resolved': true,
            });
          }
          return _read(request);
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api);
      await _edit(tester);
      await tester.enterText(_field('通知名称'), 'Local name');
      await _save(tester);
      await pumpUntilFound(tester, find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lost notification save response queries the original request without resubmission',
    (tester) async {
      var posts = 0, queries = 0;
      String? id;
      final recovery = PanelNotifyRecovery();
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            id = (jsonDecode(request.body) as Map)['request_id'] as String;
            throw http.ClientException('lost response');
          }
          if (request.url.path.contains('/requests/')) {
            queries++;
            expect(request.url.path, '/api/notify/requests/$id');
            return _json({
              'ok': true,
              'request_id': id,
              'saved': true,
              'resolved': true,
              'state': 'completed',
              'retry_allowed': false,
              'current_matches': true,
            });
          }
          return _read(request);
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api, recovery: recovery);
      await _edit(tester);
      await tester.enterText(_field('通知名称'), 'Draft');
      await _save(tester);
      await pumpUntilFound(tester, find.text('查询原通知提交'));
      await tester.pumpAndSettle();
      expect(recovery.requestId, id);
      expect(find.text('保存通知'), findsNothing);
      await tester.tap(find.text('查询原通知提交'));
      await pumpUntilFound(tester, find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(posts, 1);
      expect(queries, 1);
      expect(recovery.requestId, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clearing a notification credential submits an explicit intent without reading its value',
    (tester) async {
      Map? submitted;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            submitted = jsonDecode(request.body) as Map;
            return _json({
              'ok': true,
              'request_id': submitted!['request_id'],
              'saved': true,
              'resolved': true,
            });
          }
          return _read(request);
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api);
      await _edit(tester);
      final intent = find.byKey(const ValueKey('intent-WEBHOOK_URL-keep'));
      await tester.scrollUntilVisible(intent, 160, scrollable: _editorScroll());
      await tester.tap(intent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空').last);
      await tester.pumpAndSettle();
      await _save(tester);
      await pumpUntilFound(tester, find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(submitted!['credentials'], {
        'WEBHOOK_URL': {'action': 'clear'},
      });
      expect(submitted!['values'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'authentication expiry exits nested notification editing and retains only the recovery ID',
    (tester) async {
      var expired = 0;
      final recovery = PanelNotifyRecovery();
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            return _json({'ok': false, 'msg': '会话过期'}, 401);
          }
          return _read(request);
        }),
      );
      addTearDown(api.close);
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
                child: const Text('打开通知'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开通知'));
      await pumpUntilFound(tester, find.text('Alpha'));
      await tester.pumpAndSettle();
      await _edit(tester);
      await tester.enterText(_field('通知名称'), 'Private draft');
      await _save(tester);
      await pumpUntilFound(tester, find.text('打开通知'));
      await tester.pumpAndSettle();
      expect(expired, 1);
      expect(recovery.requestId, matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(find.text('Private draft'), findsNothing);
      expect(find.text('编辑通知'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conflicting notification draft merges only local changes after confirmation',
    (tester) async {
      var reads = 0, posts = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            final body = jsonDecode(request.body) as Map;
            if (posts == 1) {
              return _json({
                'ok': false,
                'msg': '通知配置已变化',
                'saved': false,
                'resolved': true,
                'conflict': true,
              }, 409);
            }
            expect(body['version'], 'b' * 64);
            expect(body['settings'], {'name': 'Local'});
            expect(body['values'], isEmpty);
            return _json({
              'ok': true,
              'request_id': body['request_id'],
              'saved': true,
              'resolved': true,
            });
          }
          if (request.url.path.endsWith('/settings/n')) {
            reads++;
            return _json({
              'ok': true,
              'item': notifyItemFixture(
                version: reads == 1 ? 'a' * 64 : 'b' * 64,
                method: reads == 1 ? 'POST' : 'PATCH',
              ),
            });
          }
          return _read(request);
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api);
      await _edit(tester);
      await tester.enterText(_field('通知名称'), 'Local');
      await _save(tester);
      await pumpUntilFound(tester, find.text('核对并合并'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并合并'));
      await pumpUntilFound(tester, find.text('合并本地改动'));
      expect(find.textContaining('请求方法：PATCH'), findsOneWidget);
      await tester.tap(find.text('合并本地改动'));
      await tester.pumpAndSettle();
      expect(find.text('Local'), findsOneWidget);
      await _save(tester);
      await pumpUntilFound(tester, find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(posts, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'channel switch cancellation restores selection and confirmation clears prior field intents',
    (tester) async {
      Map? submitted;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            submitted = jsonDecode(request.body) as Map;
            return _json({
              'ok': true,
              'request_id': submitted!['request_id'],
              'saved': true,
              'resolved': true,
            });
          }
          return _read(request);
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api);
      await _edit(tester);
      Future<void> choose(String key) async {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Telegram Bot').last);
        await tester.pumpAndSettle();
      }

      await choose('webhook-0');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('webhook-1')),
            )
            .initialValue,
        'webhook',
      );
      await choose('webhook-1');
      await tester.tap(find.text('更换渠道'));
      await tester.pumpAndSettle();
      await _save(tester);
      await pumpUntilFound(tester, find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(submitted!['reset_channel'], true);
      expect(submitted!['settings'], {'channel': 'telegram'});
      expect(submitted!['values'], isEmpty);
      expect(submitted!['credentials'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'default channel conflict retains local selection and requires current version review',
    (tester) async {
      var posts = 0, reads = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            final body = jsonDecode(request.body) as Map;
            expect(body['default_ids'], ['b', 'n']);
            if (posts == 1) {
              return _json({
                'ok': false,
                'saved': false,
                'resolved': true,
                'conflict': true,
                'msg': '默认选择已变化',
              }, 409);
            }
            expect(body['version'], 'e' * 64);
            return _json({
              'ok': true,
              'request_id': body['request_id'],
              'saved': true,
              'resolved': true,
            });
          }
          if (request.url.path.endsWith('/defaults')) {
            reads++;
            return _json({
              'ok': true,
              'default_ids': ['n'],
              'version': (reads == 1 ? 'd' : 'e') * 64,
            });
          }
          return _read(request);
        }),
      );
      addTearDown(api.close);
      await _launch(tester, api);
      await tester.tap(find.byTooltip('选择默认通知'));
      await pumpUntilFound(tester, find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta'));
      Future<void> save() async {
        await tester.tap(find.text('保存默认渠道'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认保存'));
      }

      await save();
      await pumpUntilFound(tester, find.text('核对默认选择'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对默认选择'));
      await pumpUntilFound(tester, find.text('保留本地选择'));
      await tester.tap(find.text('保留本地选择'));
      await pumpUntilFound(tester, find.text('保存默认渠道'));
      await tester.pumpAndSettle();
      await save();
      await pumpUntilFound(tester, find.byTooltip('选择默认通知'));
      await tester.pumpAndSettle();
      expect(posts, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'notification forms fit 320 dp with large text and keep secret inputs obscured after background',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: proxySession,
        client: panelMockClient((request) async => _read(request)),
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
          home: PanelNotifyView(
            manager: PanelNotifyManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('Alpha'));
      await tester.pumpAndSettle();
      await _edit(tester);
      final intent = find.byKey(const ValueKey('intent-WEBHOOK_URL-keep'));
      await tester.scrollUntilVisible(intent, 180, scrollable: _editorScroll());
      await tester.tap(intent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('替换').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(_field('请求 URL'));
      await tester.enterText(_field('请求 URL'), 'https://private.example/token');
      await tester.tap(find.byTooltip('显示输入'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_field('请求 URL')).obscureText, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(find.text('https://private.example/token'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        _field('请求 URL'),
        160,
        scrollable: _editorScroll(),
      );
      expect(tester.widget<TextField>(_field('请求 URL')).obscureText, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
