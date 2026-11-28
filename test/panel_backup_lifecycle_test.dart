import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_backup_view.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_backup_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'panel_test_http.dart';

void main() {
  testWidgets('switching panels invalidates an open cleanup confirmation', (
    tester,
  ) async {
    final oldPosts = <String>[];
    final newPosts = <String>[];
    final newGets = <String>[];
    final oldManager = _manager('old', posts: oldPosts);
    final newManager = _manager('new', posts: newPosts, gets: newGets);
    await tester.pumpWidget(_view(oldManager));
    await _openRestore(tester);
    await tester.tap(find.text('清理原依赖作业'));
    await pumpUntilFound(tester, find.text('确认清理'));

    await tester.pumpWidget(_view(newManager));
    await pumpUntil(
      tester,
      () => newGets.any((path) => path.endsWith('/restores')),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认清理'), findsNothing);
    expect(find.text('清理原依赖作业'), findsNothing);
    expect(oldPosts, isEmpty);
    expect(newPosts, isEmpty);
    expect(find.text('文件 · 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final status in [200, 401]) {
    testWidgets('old restore response $status cannot affect the new panel', (
      tester,
    ) async {
      final response = Completer<http.Response>();
      var detailRequests = 0;
      var expired = 0;
      final oldManager = _manager(
        'old',
        posts: [],
        detail: () {
          detailRequests++;
          return response.future;
        },
      );
      final newGets = <String>[];
      final newManager = _manager('new', posts: [], gets: newGets);
      Future<void> unauthorized(Object _) async => expired++;
      await tester.pumpWidget(_view(oldManager, onUnauthorized: unauthorized));
      await pumpUntilFound(tester, find.text('文件 · 0'));
      await tester.tap(find.text('恢复'));
      await pumpUntilFound(tester, find.byTooltip('查询此恢复请求'));
      await tester.ensureVisible(find.byTooltip('查询此恢复请求'));
      await tester.tap(find.byTooltip('查询此恢复请求'));
      await pumpUntil(tester, () => detailRequests == 1);

      await tester.pumpWidget(_view(newManager, onUnauthorized: unauthorized));
      await pumpUntil(
        tester,
        () => newGets.any((path) => path.endsWith('/restores')),
      );
      response.complete(
        status == 200
            ? _json({'ok': true, 'restore': _restore('old')})
            : utf8Response('{"ok":false,"msg":"expired"}', 401),
      );
      await tester.pumpAndSettle();
      expect(expired, 0);
      expect(find.text('文件 · 0'), findsOneWidget);
      await tester.tap(find.text('恢复'));
      await pumpUntilFound(tester, find.textContaining('new.zip'));
      expect(find.textContaining('old.zip'), findsNothing);
      expect(find.text('Installation output'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'background invalidates queued consent and hides backup contents',
    (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final posts = <String>[];
      final manager = _manager('original', posts: posts);
      await tester.pumpWidget(_view(manager));
      await _openRestore(tester);
      expect(find.text('Installation output'), findsOneWidget);
      await tester.tap(find.text('清理原依赖作业'));
      await pumpUntilFound(tester, find.text('确认清理'));
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '确认清理'),
      );
      button.onPressed!();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(posts, isEmpty);
      expect(find.text('Installation output'), findsNothing);
      expect(find.textContaining('original.zip'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(posts, isEmpty);
      expect(find.text('确认清理'), findsNothing);
      expect(find.text('清理原依赖作业'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _view(
  PanelBackupManager manager, {
  Future<void> Function(Object)? onUnauthorized,
}) => MaterialApp(
  home: PanelBackupView(
    manager: manager,
    onUnauthorized: onUnauthorized ?? (_) async {},
  ),
);

Future<void> _openRestore(WidgetTester tester) async {
  await pumpUntilFound(tester, find.text('文件 · 0'));
  await tester.tap(find.text('恢复'));
  await pumpUntilFound(tester, find.byTooltip('查询此恢复请求'));
  await tester.ensureVisible(find.byTooltip('查询此恢复请求'));
  await tester.tap(find.byTooltip('查询此恢复请求'));
  await pumpUntilFound(tester, find.text('清理原依赖作业'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('清理原依赖作业'));
}

PanelBackupManager _manager(
  String name, {
  required List<String> posts,
  List<String>? gets,
  Future<http.Response> Function()? detail,
}) {
  final api = PanelApiClient(
    baseUrl: 'https://$name.example',
    credentials: const PanelSessionCredentials(
      cookie: 'fls_native_session=session',
      csrfToken: 'csrf',
    ),
    client: MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST') {
        posts.add(path);
        return _json({'ok': true, 'restore': _restore(name)});
      }
      gets?.add(path);
      if (path.endsWith('/capabilities')) {
        return _json({
          'ok': true,
          'items': ['data', 'scripts'],
          'formats': ['zip'],
          'upload_limit_bytes': 10,
          'extracted_limit_bytes': 20,
          'entry_limit': 30,
          'preflight_enabled': true,
          'restore_enabled': true,
        });
      }
      if (path.endsWith('/restore-maintenance')) {
        return _json({'ok': true, 'maintenance': null});
      }
      if (path.endsWith('/restores')) {
        return _json({
          'ok': true,
          'items': [_restore(name)],
          'total': 1,
          'limit': 25,
          'offset': 0,
          'has_more': false,
        });
      }
      if (path.endsWith('/restores/${'c' * 32}')) {
        return detail != null
            ? detail()
            : _json({'ok': true, 'restore': _restore(name)});
      }
      return _json({
        'ok': true,
        'items': [],
        'page': 1,
        'pages': 1,
        'total': 0,
      });
    }),
  );
  addTearDown(api.close);
  return PanelBackupManager(api);
}

http.Response _json(Map<String, dynamic> body) =>
    utf8Response(jsonEncode(body), 200);

Map<String, dynamic> _restore(String name) => {
  'request_id': 'c' * 32,
  'preflight_id': 'a' * 32,
  'filename': '$name.zip',
  'archive_sha256': 'b' * 64,
  'archive_size_bytes': 13,
  'restore_items': ['data'],
  'restore_dependencies': true,
  'state': 'restored',
  'phase': 'restored',
  'active': false,
  'committed': true,
  'live_state_unchanged': false,
  'restore_outcome_unknown': false,
  'error': '',
  'created_at': 1795695731,
  'updated_at': 1795695732,
  'scheduler': {
    'state': 'pending',
    'required': true,
    'operation_id': '',
    'error': '',
  },
  'dependencies': {
    'state': 'unknown',
    'operation_id': 'e' * 32,
    'error': 'Cleanup required',
    'output': 'Installation output',
    'cleanup_required': true,
  },
};
