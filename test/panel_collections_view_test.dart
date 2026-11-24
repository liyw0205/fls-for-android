import 'dart:convert';

import 'panel_test_http.dart';

import 'package:fls_for_android/features/panel_collections_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_tasks_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

void main() {
  testWidgets('enables save after entering a collection name and opens it', (
    tester,
  ) async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=collections-session',
        csrfToken: 'collections-csrf',
      ),
      client: MockClient((request) async {
        if (request.url.path == '/api/collections' && request.method == 'GET') {
          return utf8Response(
            '{"ok":true,"items":[{"id":"group-new","name":"新建合集","remark":"","member_count":0}],"page":1,"pages":1,"total":1}',
            200,
          );
        }
        if (request.url.path == '/api/collection/save') {
          expect(request.headers['x-csrf-token'], 'collections-csrf');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['name'], '新建合集');
          expect(body['remark'], '');
          return utf8Response(
            '{"ok":true,"collection_id":"group-new","created":true}',
            201,
          );
        }
        if (request.url.path == '/api/collection/group-new') {
          return utf8Response(
            '{"ok":true,"collection":{"id":"group-new","name":"新建合集","remark":"","member_count":0},"collection_version":"revision-new","view":"members","member_ids":[],"items":[],"page":1,"pages":1,"total":0}',
            200,
            headers: {'cache-control': 'no-store'},
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelCollectionsView(
            manager: PanelTasksManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.byTooltip('新建合集'));
    await tester.tap(find.byTooltip('新建合集'));
    await tester.pumpAndSettle();

    final saveButton = find.widgetWithText(FilledButton, '保存');
    final nameField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '合集名称',
    );
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
    await tester.enterText(nameField, '新建合集');
    await tester.pump();
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
    await tester.tap(saveButton);
    await pumpUntilFound(tester, find.text('新建合集'));
    await pumpUntilFound(tester, find.text('合集暂无任务'));

    expect(tester.takeException(), isNull);
  });
}
