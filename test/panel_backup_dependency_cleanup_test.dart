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
  testWidgets('pending cleanup yields to an explicit original-request query', (
    tester,
  ) async {
    final harness = _CleanupHarness('pending');
    await _submit(tester, harness);
    for (
      var attempt = 0;
      attempt < 20 && harness.cleanupQueries < 15;
      attempt++
    ) {
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await pumpUntil(tester, () {
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '清理原依赖作业'),
      );
      return button.onPressed != null;
    });
    expect(harness.cleanupQueries, 15);
    expect(harness.posts, hasLength(1));
    expect(find.text('单独安装恢复依赖'), findsNothing);
    expect(find.text('清理已受理，仍在等待面板确认；可查询原作业'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'background stops accepted cleanup polling without resubmitting',
    (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final harness = _CleanupHarness('pending');
      await _submit(tester, harness);
      await pumpUntil(tester, () => harness.cleanupQueries == 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Installation output'), findsNothing);
      expect(find.text('cleanup.zip'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpUntilFound(tester, find.text('清理原依赖作业'));
      await tester.pumpAndSettle();
      expect(harness.cleanupQueries, 1);
      expect(harness.posts, hasLength(1));
      expect(find.text('单独安装恢复依赖'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('accepted cleanup queries its owner until cleanup is confirmed', (
    tester,
  ) async {
    final harness = _CleanupHarness('complete');
    await _submit(tester, harness);
    await pumpUntil(tester, () => harness.cleanupQueries >= 1);
    expect(find.text('正在清理原依赖作业…'), findsOneWidget);
    expect(find.text('单独安装恢复依赖'), findsNothing);
    final cleanup = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '清理原依赖作业'),
    );
    expect(cleanup.onPressed, isNull);
    await pumpUntilFound(tester, find.text('单独安装恢复依赖'));
    expect(harness.cleanupQueries, 2);
    expect(harness.posts, hasLength(1));
    expect(find.text('清理原依赖作业'), findsNothing);
    expect(find.text('依赖安装：结果未知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final outcome in ['unavailable', 'changed', 'expired']) {
    testWidgets('accepted cleanup preserves its identity after $outcome', (
      tester,
    ) async {
      final harness = _CleanupHarness(outcome);
      await _submit(tester, harness);
      await pumpUntil(tester, () => harness.cleanupQueries >= 1);
      if (outcome == 'expired') {
        await pumpUntil(tester, () => harness.unauthorized == 1);
        expect(find.text('Installation output'), findsNothing);
        expect(find.text('清理原依赖作业'), findsNothing);
      } else {
        await pumpUntil(tester, () {
          final buttons = tester.widgetList<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '清理原依赖作业'),
          );
          return buttons.isNotEmpty && buttons.single.onPressed != null;
        });
        expect(find.text('单独安装恢复依赖'), findsNothing);
        expect(find.text('Other operation output'), findsNothing);
        expect(harness.unauthorized, 0);
      }
      await tester.pump(const Duration(seconds: 4));
      expect(harness.posts, hasLength(1));
      expect(harness.cleanupQueries, lessThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _submit(WidgetTester tester, _CleanupHarness harness) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PanelBackupView(
        manager: harness.manager,
        onUnauthorized: (_) async => harness.unauthorized++,
      ),
    ),
  );
  await pumpUntilFound(tester, find.text('文件 · 0'));
  await tester.tap(find.text('恢复'));
  await pumpUntilFound(tester, find.byTooltip('查询此恢复请求'));
  await tester.ensureVisible(find.byTooltip('查询此恢复请求'));
  await tester.tap(find.byTooltip('查询此恢复请求'));
  await pumpUntilFound(tester, find.text('清理原依赖作业'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('清理原依赖作业'));
  await tester.tap(find.text('清理原依赖作业'));
  await pumpUntilFound(tester, find.text('确认清理'));
  expect(harness.posts, isEmpty);
  await tester.tap(find.text('确认清理'));
  await pumpUntil(tester, () => harness.posts.isNotEmpty);
}

class _CleanupHarness {
  _CleanupHarness(this.outcome) {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example/prefix',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=session',
        csrfToken: 'csrf',
      ),
      client: MockClient(_handle),
    );
    manager = PanelBackupManager(api);
    addTearDown(api.close);
  }

  final String outcome;
  late final PanelBackupManager manager;
  final posts = <http.Request>[];
  int cleanupQueries = 0;
  int unauthorized = 0;

  http.Response _json(Map<String, dynamic> value, [int status = 200]) =>
      utf8Response(jsonEncode(value), status);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'POST') {
      expect(
        path,
        '/prefix/api/backup/native/restores/${'c' * 32}/dependencies/cleanup',
      );
      expect(jsonDecode(request.body), {'operation_id': 'e' * 32});
      expect(request.headers['x-csrf-token'], 'csrf');
      posts.add(request);
      return _json({
        'ok': true,
        'cleanup_requested': true,
        'restore': _restore(),
      }, 202);
    }
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
        'items': [_restore()],
        'total': 1,
        'limit': 25,
        'offset': 0,
        'has_more': false,
      });
    }
    if (path.endsWith('/restores/${'c' * 32}')) {
      if (posts.isNotEmpty) {
        cleanupQueries++;
        if (outcome == 'unavailable' || outcome == 'expired') {
          return _json({
            'ok': false,
            'msg': 'Query unavailable',
          }, outcome == 'expired' ? 401 : 503);
        }
      }
      final changed = posts.isNotEmpty && outcome == 'changed';
      return _json({
        'ok': true,
        'restore': _restore(
          cleanup: outcome == 'pending' || cleanupQueries < 2,
          changed: changed,
        ),
      });
    }
    return _json({'ok': true, 'items': [], 'page': 1, 'pages': 1, 'total': 0});
  }

  Map<String, dynamic> _restore({bool cleanup = true, bool changed = false}) =>
      {
        'request_id': 'c' * 32,
        'preflight_id': 'a' * 32,
        'filename': 'cleanup.zip',
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
          'operation_id': (changed ? 'f' : 'e') * 32,
          'error': cleanup ? 'Cleanup required' : '',
          'output': changed ? 'Other operation output' : 'Installation output',
          'cleanup_required': cleanup,
        },
      };
}
