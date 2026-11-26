import 'package:fls_for_android/features/panel_backup_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_backup_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'panel_test_http.dart';

void main() {
  testWidgets('backup screen fits a compact viewport with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=screen-session',
        csrfToken: 'csrf',
      ),
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/capabilities')) {
          return utf8Response(
            '{"ok":true,"items":["data","scripts"],"formats":["tar.gz"],"upload_limit_bytes":10,"extracted_limit_bytes":20,"entry_limit":30}',
            200,
          );
        }
        if (path.endsWith('/files')) {
          return utf8Response(
            '{"ok":true,"items":[{"name":"fls-backup-config-20261126-long-identifier.tar.gz","version":"${'a' * 64}","size_bytes":1200000,"modified_at":"2026-11-26 10:00:00"}],"page":1,"pages":1,"limit":25,"total":1}',
            200,
          );
        }
        return utf8Response(
          '{"ok":true,"items":[{"id":"${'b' * 32}","items":["data","scripts"],"status":"running","active":true,"cancel_allowed":true,"cancel_requested":false,"filename":"","size_bytes":0,"created_at":"2026-11-26 10:00:00","updated_at":"2026-11-26 10:00:01","cleanup_required":false}],"page":1,"pages":1,"limit":25,"total":1}',
          200,
        );
      }),
    );
    addTearDown(client.close);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: PanelBackupView(
            manager: PanelBackupManager(client),
            onUnauthorized: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('备份恢复'), findsOneWidget);
    expect(find.textContaining('文件 · 1'), findsOneWidget);
    expect(find.textContaining('fls-backup-config'), findsOneWidget);
    await tester.tap(find.textContaining('作业 · 1'));
    await tester.pumpAndSettle();
    expect(find.text('备份中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
