import 'dart:convert';

import 'package:fls_for_android/features/panel_backup_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_backup_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'panel_test_http.dart';

void main() {
  testWidgets(
    'dependency cleanup uses the original operation after a lost response',
    (tester) async {
      final posts = <String>[];
      var cleanupRequired = true;
      Map<String, dynamic> restore() => {
        ...jsonDecode(_restore()) as Map<String, dynamic>,
        'restore_dependencies': true,
        'dependencies': {
          'state': 'unknown',
          'operation_id': 'e' * 32,
          'error': cleanupRequired ? 'Cleanup required' : '',
          'output': 'Installation output',
          'cleanup_required': cleanupRequired,
        },
      };
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=session',
          csrfToken: 'csrf',
        ),
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST') {
            posts.add(path);
            expect(path, endsWith('/dependencies/cleanup'));
            expect(jsonDecode(request.body), {'operation_id': 'e' * 32});
            cleanupRequired = false;
            return utf8Response('{"ok":false,"msg":"response lost"}', 503);
          }
          if (path.endsWith('/capabilities')) {
            return utf8Response(
              '{"ok":true,"items":["data","scripts"],"formats":["zip"],"upload_limit_bytes":10,"extracted_limit_bytes":20,"entry_limit":30,"preflight_enabled":true,"restore_enabled":true}',
              200,
            );
          }
          if (path.endsWith('/restore-maintenance')) {
            return utf8Response('{"ok":true,"maintenance":null}', 200);
          }
          if (path.endsWith('/restores')) {
            return utf8Response(
              jsonEncode({
                'ok': true,
                'items': [restore()],
                'total': 1,
                'limit': 25,
                'offset': 0,
                'has_more': false,
              }),
              200,
            );
          }
          if (path.endsWith('/restores/${'c' * 32}')) {
            return utf8Response(
              jsonEncode({'ok': true, 'restore': restore()}),
              200,
            );
          }
          return utf8Response(
            '{"ok":true,"items":[],"page":1,"pages":1,"total":0}',
            200,
          );
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PanelBackupView(
            manager: PanelBackupManager(api),
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('文件 · 0'));
      await tester.tap(find.text('恢复'));
      await pumpUntilFound(tester, find.byTooltip('查询此恢复请求'));
      await tester.pumpAndSettle();
      final history = find.byTooltip('查询此恢复请求');
      await tester.ensureVisible(history);
      await tester.tap(history);
      await pumpUntilFound(tester, find.text('清理原依赖作业'));
      await tester.pumpAndSettle();
      expect(find.text('单独安装恢复依赖'), findsNothing);
      final scheduler = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '仅重新加载调度器'),
      );
      expect(scheduler.onPressed, isNull);
      final cleanup = find.text('清理原依赖作业');
      await tester.ensureVisible(cleanup);
      await tester.tap(cleanup);
      await tester.pumpAndSettle();
      expect(posts, isEmpty);
      await tester.tap(find.text('确认清理'));
      await pumpUntilFound(tester, find.text('单独安装恢复依赖'));
      await tester.pumpAndSettle();
      expect(posts, [
        '/api/backup/native/restores/${'c' * 32}/dependencies/cleanup',
      ]);
      expect(find.text('清理原依赖作业'), findsNothing);
      expect(find.text('单独安装恢复依赖'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restore history paginates and retains the page on a failed refresh',
    (tester) async {
      final offsets = <int>[];
      var failHistory = false;
      final client = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=session',
          csrfToken: 'csrf',
        ),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/capabilities')) {
            return utf8Response(
              '{"ok":true,"items":["data","scripts"],"formats":["zip"],"upload_limit_bytes":10,"extracted_limit_bytes":20,"entry_limit":30,"preflight_enabled":true,"restore_enabled":true}',
              200,
            );
          }
          if (path.endsWith('/restore-maintenance')) {
            return utf8Response('{"ok":true,"maintenance":null}', 200);
          }
          if (path.endsWith('/restores')) {
            final offset = int.parse(request.url.queryParameters['offset']!);
            offsets.add(offset);
            if (failHistory) {
              return utf8Response('{"ok":false,"msg":"unavailable"}', 503);
            }
            final all = List.generate(
              27,
              (index) => {
                ...jsonDecode(_restore()) as Map<String, dynamic>,
                'request_id': index.toRadixString(16).padLeft(32, '0'),
                'filename': 'archive-$index.zip',
              },
            );
            return utf8Response(
              jsonEncode({
                'ok': true,
                'items': all.skip(offset).take(25).toList(),
                'total': 27,
                'offset': offset,
                'limit': 25,
                'has_more': offset + 25 < 27,
              }),
              200,
            );
          }
          return utf8Response(
            '{"ok":true,"items":[],"page":1,"pages":1,"total":0}',
            200,
          );
        }),
      );
      addTearDown(client.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PanelBackupView(
            manager: PanelBackupManager(client),
            onUnauthorized: (_) async {},
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('文件 · 0'));
      await tester.tap(find.text('恢复'));
      await pumpUntilFound(tester, find.textContaining('archive-0.zip'));
      await tester.pumpAndSettle();
      final next = find.byIcon(Icons.chevron_right).last;
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      expect(next.hitTestable(), findsOneWidget);
      await tester.tap(next);
      await pumpUntilFound(tester, find.textContaining('archive-25.zip'));
      await tester.pumpAndSettle();
      expect(find.textContaining('archive-25.zip'), findsOneWidget);
      expect(offsets, [0, 25]);
      failHistory = true;
      final refresh = find.descendant(
        of: find.byTooltip('刷新恢复历史'),
        matching: find.byIcon(Icons.refresh),
      );
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await pumpUntilFound(tester, find.text('恢复历史暂不可用，请重试'));
      await tester.pumpAndSettle();
      expect(find.text('恢复历史暂不可用，请重试'), findsOneWidget);
      expect(find.textContaining('archive-25.zip'), findsOneWidget);
      expect(offsets.last, 25);
      expect(tester.takeException(), isNull);
    },
  );

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
            '{"ok":true,"items":["data","scripts"],"formats":["tar.gz"],"upload_limit_bytes":10,"extracted_limit_bytes":20,"entry_limit":30,"preflight_enabled":true,"preflight_limit":2,"preflight_ttl_seconds":3600,"restore_enabled":true}',
            200,
          );
        }
        if (path.endsWith('/files')) {
          return utf8Response(
            '{"ok":true,"items":[{"name":"fls-backup-config-20261126-long-identifier.tar.gz","version":"${'a' * 64}","size_bytes":1200000,"modified_at":"2026-11-26 10:00:00"}],"page":1,"pages":1,"limit":25,"total":1}',
            200,
          );
        }
        if (path.endsWith('/restores')) {
          return utf8Response(
            '{"ok":true,"items":[${_restore()}],"total":1,"limit":25,"offset":0,"has_more":false}',
            200,
          );
        }
        if (path.endsWith('/restores/${'c' * 32}')) {
          return utf8Response('{"ok":true,"restore":${_restore()}}', 200);
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
    await pumpUntilFound(tester, find.textContaining('文件 · 1'));

    expect(find.text('备份恢复'), findsOneWidget);
    expect(find.textContaining('文件 · 1'), findsOneWidget);
    expect(find.textContaining('fls-backup-config'), findsOneWidget);
    await tester.tap(find.textContaining('作业 · 1'));
    await tester.pumpAndSettle();
    expect(find.text('备份中'), findsOneWidget);
    final restoreTab = find.text('恢复');
    await tester.ensureVisible(restoreTab);
    await tester.tap(restoreTab);
    await pumpUntilFound(tester, find.textContaining('已恢复 · full.zip'));
    await tester.pumpAndSettle();
    expect(find.text('选择备份文件'), findsOneWidget);
    expect(find.textContaining('已恢复 · full.zip'), findsOneWidget);
    await tester.tap(find.byTooltip('查询此恢复请求'));
    await pumpUntilFound(tester, find.text('目录已恢复'));
    await tester.pumpAndSettle();
    expect(find.text('目录已恢复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

String _restore() =>
    '{"request_id":"${'c' * 32}","preflight_id":"${'a' * 32}","filename":"full.zip","archive_sha256":"${'b' * 64}","archive_size_bytes":13,"restore_items":["data"],"restore_dependencies":false,"state":"restored","phase":"restored","active":false,"committed":true,"live_state_unchanged":false,"restore_outcome_unknown":false,"error":"","created_at":1795695731,"updated_at":1795695732,"scheduler":{"state":"pending","required":true,"operation_id":"","error":""},"dependencies":{"state":"not_requested","operation_id":"","error":"","output":""}}';
