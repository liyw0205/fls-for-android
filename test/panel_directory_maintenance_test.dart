import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_backup_view.dart';
import 'package:fls_for_android/features/panel_directory_maintenance_view.dart';
import 'package:fls_for_android/models/panel_backup.dart';
import 'package:fls_for_android/models/panel_directory_maintenance.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_backup_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'panel_test_http.dart';

Map<String, dynamic> _row({bool recovered = false}) => {
  'request_id': 'a' * 32,
  'version': (recovered ? 'd' : 'c') * 64,
  'state': recovered ? 'rolled_back' : 'prepared',
  'outcome': recovered ? 'not_applied' : 'pending',
  'restore_items': ['data'],
  'receipt_state': 'unavailable',
  'active': false,
  'recover_allowed': true,
  'evidence_retained': true,
};

Map<String, dynamic> _page(Map<String, dynamic> row) => {
  'ok': true,
  'items': [row],
  'total': 1,
  'limit': 25,
  'offset': 0,
  'has_more': false,
};

Map<String, dynamic> _capabilities({bool supported = true}) => {
  'ok': true,
  'items': ['data', 'scripts'],
  'formats': ['zip'],
  'upload_limit_bytes': 100,
  'extracted_limit_bytes': 200,
  'entry_limit': 30,
  'preflight_enabled': true,
  'restore_enabled': true,
  if (supported) 'directory_maintenance_enabled': true,
};

http.Response _json(Object value, [int status = 200]) =>
    utf8Response(jsonEncode(value), status);

PanelBackupManager _manager(
  Future<http.Response> Function(http.Request request) handler,
) {
  final api = PanelApiClient(
    baseUrl: 'https://panel.example/prefix',
    credentials: const PanelSessionCredentials(
      cookie: 'fls_native_session=session',
      csrfToken: 'csrf',
    ),
    client: MockClient(handler),
  );
  addTearDown(api.close);
  return PanelBackupManager(api);
}

Widget _view(
  PanelBackupManager manager, {
  Future<void> Function(Object)? onUnauthorized,
}) => MaterialApp(
  home: Scaffold(
    body: PanelDirectoryMaintenanceView(
      manager: manager,
      onUnauthorized: onUnauthorized ?? (_) async {},
    ),
  ),
);

Future<void> _confirm(WidgetTester tester) async {
  final action = find.text('恢复目录现场');
  await tester.pumpAndSettle();
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  expect(action.hitTestable(), findsOneWidget);
  await tester.tap(action.hitTestable());
  await pumpUntilFound(tester, find.text('确认恢复现场'));
  await tester.tap(find.text('确认恢复现场'));
}

void main() {
  test(
    'strict directory evidence rejects unsafe and inconsistent responses',
    () {
      expect(PanelDirectoryMaintenance.fromJson(_row()).recoverAllowed, isTrue);
      for (final change in <Map<String, dynamic>>[
        {'request_id': 'bad'},
        {'version': ''},
        {'state': 'committed'},
        {'outcome': 'restored'},
        {'restore_items': []},
        {
          'restore_items': ['data', 'data'],
        },
        {
          'restore_items': ['outside'],
        },
        {'active': true},
        {'active': 'false'},
        {'receipt_state': 'available'},
        {'recover_allowed': 1},
        {'evidence_retained': false},
        {'evidence_retained': 1},
      ]) {
        expect(
          () => PanelDirectoryMaintenance.fromJson({..._row(), ...change}),
          throwsFormatException,
          reason: change.toString(),
        );
      }
      final damaged = PanelDirectoryMaintenance.fromJson({
        ..._row(),
        'version': '',
        'state': 'unavailable',
        'outcome': 'unknown',
        'restore_items': [],
        'recover_allowed': false,
      });
      expect(damaged.recoverAllowed, isFalse);
      expect(
        PanelBackupCapabilities.fromJson(
          _capabilities(supported: false),
        ).directoryMaintenanceEnabled,
        isFalse,
      );
      expect(
        () => PanelBackupCapabilities.fromJson({
          ..._capabilities(),
          'directory_maintenance_enabled': 1,
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'directory pagination rejects missing, duplicate and mismatched items',
    () {
      for (final change in <Map<String, dynamic>>[
        {'items': []},
        {'total': '1'},
        {'limit': 0},
        {'offset': -1},
        {'has_more': true},
        {
          'items': [_row(), _row()],
          'total': 2,
        },
      ]) {
        expect(
          () => PanelDirectoryMaintenancePage.fromJson({
            ..._page(_row()),
            ...change,
          }),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'manager binds pagination, original ID, CSRF and confirmation version',
    () async {
      final requests = <http.Request>[];
      var wrongIdentity = false;
      final manager = _manager((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/directory-maintenance')) {
          return _json(_page(_row()));
        }
        return _json({
          'ok': true,
          'directory': {
            ..._row(recovered: request.method == 'POST'),
            if (wrongIdentity) 'request_id': 'b' * 32,
          },
        });
      });
      final page = await manager.fetchDirectoryMaintenance();
      await manager.fetchDirectoryEvidence('a' * 32);
      final result = await manager.recoverOrphanDirectory(page.items.single);
      expect(result.outcome, 'not_applied');
      expect(requests.first.url.queryParameters, {
        'offset': '0',
        'limit': '25',
      });
      expect(
        requests.last.url.path,
        '/prefix/api/backup/native/directory-maintenance/${'a' * 32}/recover',
      );
      expect(requests.last.headers['x-csrf-token'], 'csrf');
      expect(requests.last.headers['cookie'], 'fls_native_session=session');
      expect(jsonDecode(requests.last.body), {
        'confirm': true,
        'version': 'c' * 64,
      });
      wrongIdentity = true;
      await expectLater(
        manager.fetchDirectoryEvidence('a' * 32),
        throwsA(isA<PanelApiException>()),
      );
      await expectLater(
        manager.recoverOrphanDirectory(page.items.single),
        throwsA(isA<PanelApiException>()),
      );
      final count = requests.length;
      await expectLater(
        manager.fetchDirectoryEvidence('bad'),
        throwsArgumentError,
      );
      await expectLater(
        manager.fetchDirectoryMaintenance(limit: 101),
        throwsArgumentError,
      );
      expect(requests, hasLength(count));
    },
  );

  testWidgets(
    'maintenance remains accessible when other backup reads fail; lost POST only queries original ID',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var posts = 0;
      var queries = 0;
      var recovered = false;
      final manager = _manager((request) async {
        final path = request.url.path;
        if (path.endsWith('/capabilities')) return _json(_capabilities());
        if (path.endsWith('/directory-maintenance')) {
          return _json(_page(_row(recovered: recovered)));
        }
        if (request.method == 'POST') {
          posts++;
          expect(path, endsWith('/directory-maintenance/${'a' * 32}/recover'));
          recovered = true;
          return _json({'ok': false, 'msg': 'response lost'}, 503);
        }
        if (path.endsWith('/directory-maintenance/${'a' * 32}')) {
          queries++;
          return _json({'ok': true, 'directory': _row(recovered: recovered)});
        }
        return _json({'ok': false, 'msg': 'history unavailable'}, 503);
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: PanelBackupView(manager: manager, onUnauthorized: (_) async {}),
        ),
      );
      await pumpUntilFound(tester, find.text('history unavailable'));
      await tester.ensureVisible(find.text('现场维护'));
      await tester.tap(find.text('现场维护'));
      await pumpUntilFound(tester, find.text('恢复目录现场'));
      await _confirm(tester);
      await pumpUntilFound(tester, find.text('清单记录：原目录已回滚'));
      await pumpUntil(tester, () => queries == 1);
      expect(posts, 1);
      expect(find.textContaining('事务清单和副本保留'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a missing capability uses compatibility state without probing maintenance',
    (tester) async {
      final paths = <String>[];
      final manager = _manager((request) async {
        paths.add(request.url.path);
        return _json(_capabilities(supported: false));
      });
      await tester.pumpWidget(_view(manager));
      await pumpUntilFound(tester, find.text('此面板版本尚不支持独立目录现场维护'));
      expect(paths, ['/prefix/api/backup/native/capabilities']);
    },
  );

  testWidgets('queued confirmation is invalidated by backgrounding', (
    tester,
  ) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    var posts = 0;
    final manager = _manager((request) async {
      if (request.method == 'POST') posts++;
      return request.url.path.endsWith('/capabilities')
          ? _json(_capabilities())
          : _json(_page(_row()));
    });
    await tester.pumpWidget(_view(manager));
    await pumpUntilFound(tester, find.text('恢复目录现场'));
    await tester.tap(find.text('恢复目录现场'));
    await pumpUntilFound(tester, find.text('确认恢复现场'));
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认恢复现场'),
    );
    button.onPressed!();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.textContaining('原恢复回执'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(posts, 0);
    expect(find.text('确认恢复现场'), findsNothing);
  });

  testWidgets(
    'POST across a brief background transition retains manual original query and never repeats recovery',
    (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final response = Completer<http.Response>();
      var posts = 0;
      var queries = 0;
      final manager = _manager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return _json(_capabilities());
        }
        if (request.method == 'POST') {
          posts++;
          return response.future;
        }
        if (request.url.path.endsWith('/directory-maintenance/${'a' * 32}')) {
          queries++;
          return _json({'ok': true, 'directory': _row(recovered: true)});
        }
        return _json(_page(_row()));
      });
      await tester.pumpWidget(_view(manager));
      await pumpUntilFound(tester, find.text('恢复目录现场'));
      await _confirm(tester);
      await pumpUntil(tester, () => posts == 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      response.complete(_json({'ok': false, 'msg': 'lost'}, 503));
      await tester.pumpAndSettle();
      expect(queries, 0);
      await tester.tap(find.text('查询原现场'));
      await pumpUntilFound(tester, find.text('清单记录：原目录已回滚'));
      expect(queries, 1);
      expect(posts, 1);
    },
  );

  testWidgets('old POST 401 cannot expire or query a replacement panel', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    var posts = 0;
    var expired = 0;
    var newQueries = 0;
    final old = _manager((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return _json(_capabilities());
      }
      if (request.method == 'POST') {
        posts++;
        return response.future;
      }
      return _json(_page(_row()));
    });
    final replacement = _manager((request) async {
      newQueries++;
      if (request.url.path.endsWith('/capabilities')) {
        return _json(_capabilities());
      }
      return _json(_page({..._row(), 'request_id': 'b' * 32}));
    });
    Future<void> unauthorized(Object _) async => expired++;
    await tester.pumpWidget(_view(old, onUnauthorized: unauthorized));
    await pumpUntilFound(tester, find.text('恢复目录现场'));
    await _confirm(tester);
    await pumpUntil(tester, () => posts == 1);
    await tester.pumpWidget(_view(replacement, onUnauthorized: unauthorized));
    await pumpUntilFound(tester, find.text('b' * 32));
    response.complete(_json({'ok': false, 'msg': 'old expired'}, 401));
    await tester.pumpAndSettle();
    expect(expired, 0);
    expect(newQueries, 2);
    expect(find.text('a' * 32), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
