import 'dart:convert';
import 'dart:io';

import 'package:fls_for_android/features/panel_script_import_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_script_import_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=import-widget',
    csrfToken: 'import-widget-csrf',
  );

  testWidgets('selects, uploads, resumes job state, and returns to directory', (
    tester,
  ) async {
    final temp = await Directory.systemTemp.createTemp('fls-import-widget-');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}/bundle.zip');
    await source.writeAsString('archive body');
    final seenPaths = <String>[];
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        if (request.url.path.endsWith('/import-history')) {
          return _json({'ok': true, 'items': <Object>[]});
        }
        if (request.url.path.endsWith('/api/scripts/import')) {
          final body = utf8.decode(request.bodyBytes);
          expect(body, contains('jobs/bundle'));
          expect(body, contains('filename="bundle.zip"'));
          return _json({'ok': true, 'job': _job(status: 'processing')}, 202);
        }
        if (request.url.path.endsWith('/import/${'b' * 32}')) {
          seenPaths.add(request.url.path);
          return _json({'ok': true, 'job': _job(status: 'complete')});
        }
        fail('unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => PanelScriptImportView(
                    manager: PanelScriptImportManager(api),
                    currentPath: 'jobs',
                    onUnauthorized: (_) async {},
                    pickFile: () async => PanelScriptImportSource(
                      path: source.path,
                      filename: 'bundle.zip',
                      sizeBytes: 12,
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, find.byTooltip('选择文件'));

    await tester.tap(find.byTooltip('选择文件'));
    await tester.pumpAndSettle();
    expect(find.text('bundle.zip'), findsOneWidget);
    expect(find.text('scripts/jobs/'), findsOneWidget);

    await tester.tap(find.text('上传并导入'));
    await pumpUntilFound(tester, find.text('已完成'));
    expect(find.text('jobs/bundle'), findsWidgets);
    expect(find.text('返回目录'), findsOneWidget);
    expect(seenPaths, contains('/api/scripts/import/${'b' * 32}'));

    await tester.tap(find.text('返回目录'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });
}

Map<String, dynamic> _job({required String status}) => {
  'id': 'b' * 32,
  'request_id': 'a' * 32,
  'kind': 'zip',
  'path': 'jobs/bundle',
  'source_host': 'local-upload',
  'status': status,
  'progress': {
    'phase': status,
    'uploaded_bytes': 12,
    'processed_bytes': status == 'complete' ? 12 : 0,
    'total_bytes': 12,
    'total_files': status == 'complete' ? 1 : null,
  },
  'error_code': '',
  'created_at': '2026-11-26 01:00:00',
  'updated_at': '2026-11-26 01:00:01',
  'replayed': false,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);
