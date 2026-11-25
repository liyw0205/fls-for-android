import 'dart:convert';

import 'package:fls_for_android/features/panel_script_files_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_script_files_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'opens a panel file, compares a revision conflict, and preserves the draft',
    (tester) async {
      final putBodies = <Map<String, dynamic>>[];
      var putCount = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=file-session',
          csrfToken: 'file-csrf',
        ),
        client: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/api/scripts/tree') {
            return _jsonResponse(_tree());
          }
          if (request.method == 'GET') {
            return _jsonResponse({
              'ok': true,
              'file': _file('print("before")\n', 'a' * 64),
            });
          }
          expect(request.headers['x-csrf-token'], 'file-csrf');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          putBodies.add(body);
          putCount++;
          if (putCount == 1) {
            return _jsonResponse({
              'ok': false,
              'code': 'revision_conflict',
              'msg': '文件已被其他操作修改',
              'current': _file('print("server")\n', 'b' * 64),
            }, 409);
          }
          return _jsonResponse({
            'ok': true,
            'changed': true,
            'file': _file(body['content'] as String, 'c' * 64),
          });
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: PanelScriptFilesView(
            manager: PanelScriptFilesManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            find.text('demo.py').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(find.text('demo.py'), findsOneWidget);
      await tester.tap(find.text('demo.py'));
      await _pumpUntil(tester, () {
        final fields = find.byType(TextField);
        return fields.evaluate().length > 1 &&
            tester.widget<TextField>(fields.last).enabled == true;
      });

      await tester.enterText(find.byType(TextField).last, 'print("draft")\n');
      await tester.tap(find.byTooltip('保存文件'));
      await _pumpUntil(tester, () => find.text('文件版本冲突').evaluate().isNotEmpty);

      expect(find.text('文件版本冲突'), findsOneWidget);
      expect(find.textContaining('draft'), findsOneWidget);
      expect(find.textContaining('server'), findsOneWidget);
      await tester.tap(find.text('保留草稿'));
      await _pumpUntil(
        tester,
        () => find.textContaining('草稿已保留').evaluate().isNotEmpty,
      );
      expect(find.textContaining('草稿已保留'), findsOneWidget);

      await tester.tap(find.byTooltip('保存文件'));
      await _pumpUntil(
        tester,
        () => find.byTooltip('新建文件或目录').evaluate().isNotEmpty,
      );
      expect(putBodies, hasLength(2));
      expect(putBodies.last['content'], 'print("draft")\n');
      expect(putBodies.last['revision'], 'b' * 64);
      expect(find.text('面板文件'), findsOneWidget);
    },
  );

  testWidgets('verifies a saved draft after the write response is unknown', (
    tester,
  ) async {
    var fileReads = 0;
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=file-session',
        csrfToken: 'file-csrf',
      ),
      client: MockClient((request) async {
        if (request.url.path == '/api/scripts/tree') {
          return _jsonResponse(_tree());
        }
        if (request.method == 'GET') {
          fileReads++;
          return _jsonResponse({
            'ok': true,
            'file': fileReads == 1
                ? _file('print("before")\n', 'a' * 64)
                : _file('print("draft")\n', 'b' * 64),
          });
        }
        return _jsonResponse({
          'ok': false,
          'saved': true,
          'code': 'write_result_unknown',
          'msg': '文件已保存，请重新读取确认',
        }, 503);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PanelScriptFilesView(
          manager: PanelScriptFilesManager(api),
          onUnauthorized: (_) async {},
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find.text('demo.py').evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    await tester.tap(find.text('demo.py'));
    await _pumpUntil(tester, () {
      final fields = find.byType(TextField);
      return fields.evaluate().length > 1 &&
          tester.widget<TextField>(fields.last).enabled == true;
    });
    await tester.enterText(find.byType(TextField).last, 'print("draft")\n');
    await tester.tap(find.byTooltip('保存文件'));
    await _pumpUntil(
      tester,
      () => find.byTooltip('新建文件或目录').evaluate().isNotEmpty,
    );

    expect(fileReads, 2);
    expect(find.text('面板文件'), findsOneWidget);
  });
}

Map<String, dynamic> _tree() => {
  'ok': true,
  'path': '',
  'parent': null,
  'page': 1,
  'pages': 1,
  'total': 1,
  'limit': 50,
  'items': [
    {
      'name': 'demo.py',
      'path': 'demo.py',
      'kind': 'file',
      'size_bytes': 10,
      'modified_at': 'now',
    },
  ],
};

Map<String, dynamic> _file(String content, String revision) => {
  'path': 'demo.py',
  'name': 'demo.py',
  'content': content,
  'revision': revision,
  'size_bytes': content.length,
  'modified_at': 'now',
};

http.Response _jsonResponse(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  final banners = tester
      .widgetList<MaterialBanner>(find.byType(MaterialBanner))
      .map((banner) => banner.content)
      .whereType<Text>()
      .map((text) => text.data)
      .join(' | ');
  fail(
    'widget state did not reach the expected condition; '
    'file=${find.text("demo.py").evaluate().length}, '
    'progress=${find.byType(LinearProgressIndicator).evaluate().length}, '
    'banners=$banners',
  );
}
