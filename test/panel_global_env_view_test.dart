import 'dart:convert';

import 'package:fls_for_android/features/panel_global_env_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_global_env_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_test_http.dart';

final _version = 'a' * 64;
final _newVersion = 'c' * 64;

Map<String, Object?> _page({bool sources = false}) => {
  'ok': true,
  'version': _version,
  'page': 1,
  'pages': 1,
  'total': 1,
  'items': [
    if (sources)
      {
        'id': 't::ORIGINAL',
        'key': 'ORIGINAL',
        'task_name': '测试任务',
        'exists': true,
        'version': _version,
      }
    else
      {'key': 'ORIGINAL', 'version': _version},
  ],
};

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _confirmSave(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '确认'));
}

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=env-widget',
    csrfToken: 'env-csrf',
  );

  testWidgets(
    'conflict preserves draft and explicitly rebases against current value',
    (tester) async {
      var reads = 0;
      var writes = 0;
      final ids = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient((request) async {
          if (request.url.path == '/api/env/variables') {
            return utf8Response(jsonEncode(_page()), 200);
          }
          if (request.url.path == '/api/env/variable/ORIGINAL') {
            reads++;
            return utf8Response(
              jsonEncode({
                'ok': true,
                'value': reads == 1 ? 'initial-secret' : 'concurrent-value',
                'version': reads == 1 ? _version : _newVersion,
              }),
              200,
            );
          }
          expect(request.url.path, '/api/env/mutate');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          ids.add(body['request_id'] as String);
          expect(body['value'], 'preserved-draft');
          writes++;
          if (writes == 1) {
            return utf8Response(
              jsonEncode({
                'ok': false,
                'saved': false,
                'resolved': true,
                'conflict': true,
                'msg': '变量已变化，未覆盖当前内容',
              }),
              409,
            );
          }
          expect(body['version'], _newVersion);
          return utf8Response(
            jsonEncode({
              'ok': true,
              'request_id': body['request_id'],
              'saved': true,
              'changed_count': 1,
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PanelGlobalEnvView(
            manager: PanelGlobalEnvManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('ORIGINAL'));
      expect(find.text('initial-secret'), findsNothing);
      await tester.tap(find.text('ORIGINAL'));
      await pumpUntil(tester, () => reads == 1);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('显示变量值'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('变量值'), 'preserved-draft');
      await _confirmSave(tester, '保存变量');
      await pumpUntilFound(tester, find.text('核对当前内容'));
      expect(
        tester.widget<TextField>(_field('变量值')).controller!.text,
        'preserved-draft',
      );
      await tester.tap(find.text('核对当前内容'));
      await pumpUntilFound(tester, find.text('concurrent-value'));
      await tester.tap(find.text('保留草稿并继续'));
      await tester.pumpAndSettle();
      await _confirmSave(tester, '保存变量');
      await pumpUntil(tester, () => writes == 2);
      await pumpUntilFound(tester, find.text('全局变量'));
      expect(ids[0], isNot(ids[1]));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('lost write response recovers through GET without another POST', (
    tester,
  ) async {
    var writes = 0;
    var statusReads = 0;
    String? requestId;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        if (request.url.path == '/api/env/variables') {
          return utf8Response(jsonEncode(_page()), 200);
        }
        if (request.url.path == '/api/env/mutate') {
          writes++;
          requestId = (jsonDecode(request.body) as Map)['request_id'] as String;
          return utf8Response('gateway unavailable', 502);
        }
        expect(request.method, 'GET');
        expect(request.url.path, '/api/env/requests/$requestId');
        statusReads++;
        return utf8Response(
          jsonEncode({
            'ok': true,
            'request_id': requestId,
            'saved': true,
            'state': 'completed',
            'changed_count': 1,
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelGlobalEnvView(
          manager: PanelGlobalEnvManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('ORIGINAL'));
    await tester.tap(find.byTooltip('ORIGINAL 操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除变量'));
    await tester.pumpAndSettle();
    await _confirmSave(tester, '删除变量');
    await pumpUntilFound(tester, find.text('查询原提交'));
    await tester.tap(find.text('查询原提交'));
    await pumpUntilFound(tester, find.text('全局变量'));
    expect(writes, 1);
    expect(statusReads, 1);
  });

  testWidgets('task imports hide values and send selected source revisions', (
    tester,
  ) async {
    var imported = false;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        if (request.url.path == '/api/env/variables') {
          return utf8Response(jsonEncode(_page()), 200);
        }
        if (request.url.path == '/api/env/task-sources') {
          return utf8Response(jsonEncode(_page(sources: true)), 200);
        }
        expect(request.url.path, '/api/env/mutate');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['items'], ['t::ORIGINAL']);
        expect(body['sources'], {'t::ORIGINAL': _version});
        expect(body['overwrite'], false);
        imported = true;
        return utf8Response(
          jsonEncode({
            'ok': true,
            'request_id': body['request_id'],
            'saved': true,
            'skipped_count': 1,
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelGlobalEnvView(
          manager: PanelGlobalEnvManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('ORIGINAL'));
    await tester.tap(find.byTooltip('变量操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从任务导入'));
    await pumpUntilFound(tester, find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await _confirmSave(tester, '导入所选变量');
    await pumpUntil(tester, () => imported);
    await pumpUntilFound(tester, find.text('全局变量'));
  });

  testWidgets('failed detail load cannot overwrite value with an empty draft', (
    tester,
  ) async {
    tester.view.reset();
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        expect(request.method, 'GET');
        return request.url.path.endsWith('/variables')
            ? utf8Response(jsonEncode(_page()), 200)
            : utf8Response(jsonEncode({'ok': false, 'msg': '读取失败'}), 503);
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: PanelGlobalEnvView(
          manager: PanelGlobalEnvManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('ORIGINAL'));
    await tester.tap(find.text('ORIGINAL'));
    await pumpUntilFound(tester, find.text('读取失败'));
    final button = tester.widget<FilledButton>(
      find
          .ancestor(
            of: find.text('保存变量'),
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton,
            ),
          )
          .first,
    );
    expect(button.onPressed, isNull);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
