import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_backup_view.dart';
import 'package:fls_for_android/features/panel_dependency_maintenance_view.dart';
import 'package:fls_for_android/models/panel_backup.dart';
import 'package:fls_for_android/models/panel_dependency_maintenance.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_backup_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

Map<String, dynamic> _row({String state = 'pending', String operation = 'b'}) =>
    {
      'request_id': 'a' * 32,
      'operation_id': operation * 32,
      'version': (state == 'finalized' ? 'f' : 'c') * 64,
      'state': state,
      'resource_state': const {'finalizing', 'finalized'}.contains(state)
          ? 'cleaned'
          : 'pending',
      'original_result': 'unknown',
      'receipt_state': 'unavailable',
      'owner_active': const {'requested', 'cleaning', 'active'}.contains(state),
      'cleanup_allowed': !const {
        'requested',
        'cleaning',
        'active',
        'finalized',
      }.contains(state),
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
  if (supported) 'dependency_maintenance_enabled': true,
};

http.Response _json(Object value, [int status = 200]) =>
    utf8Response(jsonEncode(value), status);

PanelBackupManager _manager(
  Future<http.Response> Function(http.Request) handler,
) {
  final api = PanelApiClient(
    baseUrl: 'https://panel.example/prefix',
    credentials: const PanelSessionCredentials(
      cookie: 'fls_native_session=session',
      csrfToken: 'csrf',
    ),
    client: panelMockClient(handler),
  );
  addTearDown(api.close);
  return PanelBackupManager(api);
}

Widget _view(
  PanelBackupManager manager, {
  Future<void> Function(Object)? onUnauthorized,
  double scale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: PanelDependencyMaintenanceView(
      manager: manager,
      onUnauthorized: onUnauthorized ?? (_) async {},
    ),
  ),
);

Future<void> _confirm(WidgetTester tester) async {
  await pumpUntilFound(tester, find.text('清理依赖资源'));
  await tester.ensureVisible(find.text('清理依赖资源'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('清理依赖资源'));
  await pumpUntilFound(tester, find.text('确认清理资源'));
  await tester.tap(find.text('确认清理资源'));
}

void main() {
  testWidgets(
    'pending cleanup stops bounded polling and allows only manual GET',
    (tester) async {
      var posts = 0;
      var queries = 0;
      var finished = false;
      final manager = _manager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return _json(_capabilities());
        }
        if (request.url.path.endsWith('/dependency-maintenance')) {
          return _json(_page(_row()));
        }
        if (request.method == 'POST') {
          posts++;
        } else {
          queries++;
        }
        return _json({
          'ok': true,
          'dependency': _row(state: finished ? 'finalized' : 'requested'),
        }, request.method == 'POST' ? 202 : 200);
      });
      await tester.pumpWidget(_view(manager));
      await _confirm(tester);
      await pumpUntilFound(tester, find.text('结果尚未确认，请查询原依赖现场。'));
      expect(queries, 8);
      expect(posts, 1);
      await tester.pump(const Duration(seconds: 20));
      expect(queries, 8);
      expect(find.text('清理依赖资源'), findsNothing);
      finished = true;
      await tester.tap(find.text('查询原依赖现场'));
      await pumpUntilFound(tester, find.text('依赖资源维护已结束，原始证据保留'));
      expect(queries, 9);
      expect(posts, 1);
    },
  );

  test('optional capability defaults false and requires an actual boolean', () {
    expect(
      PanelBackupCapabilities.fromJson(
        _capabilities(supported: false),
      ).dependencyMaintenanceEnabled,
      isFalse,
    );
    expect(
      PanelBackupCapabilities.fromJson(
        _capabilities(),
      ).dependencyMaintenanceEnabled,
      isTrue,
    );
    for (final value in ['true', 1, null]) {
      expect(
        () => PanelBackupCapabilities.fromJson({
          ..._capabilities(),
          'dependency_maintenance_enabled': value,
        }),
        throwsFormatException,
      );
    }
  });

  test(
    'DTO never promotes cleanup into installation success and binds both identities',
    () {
      expect(
        PanelDependencyMaintenance.fromJson(_row()).cleanupAllowed,
        isTrue,
      );
      expect(
        PanelDependencyMaintenance.fromJson(_row(state: 'finalized')).finalized,
        isTrue,
      );
      for (final change in <Map<String, dynamic>>[
        {'request_id': 'bad'},
        {'operation_id': 'bad'},
        {'version': ''},
        {'original_result': 'succeeded'},
        {'evidence_retained': false},
        {'owner_active': 1},
        {'cleanup_allowed': 1},
        {'state': 'active'},
        {'state': 'requested'},
        {'state': 'finalized', 'cleanup_allowed': false},
        {'receipt_state': 'available'},
        {'state': 'unavailable', 'version': '', 'resource_state': 'unknown'},
      ]) {
        expect(
          () => PanelDependencyMaintenance.fromJson({..._row(), ...change}),
          throwsFormatException,
          reason: '$change',
        );
      }
      final unavailable = PanelDependencyMaintenance.fromJson({
        ..._row(),
        'state': 'unavailable',
        'version': '',
        'resource_state': 'unknown',
        'cleanup_allowed': false,
      });
      expect(unavailable.cleanupAllowed, isFalse);
      expect(
        PanelDependencyMaintenancePage.fromJson({
          ..._page(_row()),
          'total': 2,
          'items': [_row(), _row(operation: 'd')],
        }).items,
        hasLength(2),
      );
      for (final change in <Map<String, dynamic>>[
        {'items': []},
        {'limit': 0},
        {'offset': -1},
        {'total': 1001},
        {'has_more': true},
        {
          'items': [_row(), _row()],
          'total': 2,
        },
      ]) {
        expect(
          () => PanelDependencyMaintenancePage.fromJson({
            ..._page(_row()),
            ...change,
          }),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'manager binds pagination, session, CSRF, original operation and confirmation',
    () async {
      final requests = <http.Request>[];
      final manager = _manager((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/dependency-maintenance')) {
          return _json(_page(_row()));
        }
        return _json({
          'ok': true,
          'dependency': _row(
            state: request.method == 'POST' ? 'requested' : 'pending',
          ),
        }, request.method == 'POST' ? 202 : 200);
      });
      final page = await manager.fetchDependencyMaintenance();
      await manager.fetchDependencyEvidence('a' * 32, 'b' * 32);
      final result = await manager.cleanupOrphanDependency(page.items.single);
      expect(result.state, 'requested');
      expect(requests.first.url.queryParameters, {
        'offset': '0',
        'limit': '25',
      });
      expect(
        requests.last.url.path,
        '/prefix/api/backup/native/dependency-maintenance/${'a' * 32}/${'b' * 32}/cleanup',
      );
      expect(requests.last.headers['x-csrf-token'], 'csrf');
      expect(requests.last.headers['cookie'], 'fls_native_session=session');
      expect(jsonDecode(requests.last.body), {
        'confirm': true,
        'version': 'c' * 64,
      });
      final count = requests.length;
      await expectLater(
        manager.fetchDependencyEvidence('bad', 'b' * 32),
        throwsArgumentError,
      );
      await expectLater(
        manager.fetchDependencyEvidence('a' * 32, 'bad'),
        throwsArgumentError,
      );
      await expectLater(
        manager.fetchDependencyMaintenance(limit: 101),
        throwsArgumentError,
      );
      await expectLater(
        manager.cleanupOrphanDependency(
          PanelDependencyMaintenance.fromJson(_row(state: 'active')),
        ),
        throwsArgumentError,
      );
      expect(requests, hasLength(count));
    },
  );

  test(
    'manager rejects wrong request, wrong operation, invented result and wrong page',
    () async {
      var change = <String, dynamic>{};
      final manager = _manager(
        (request) async => request.url.path.endsWith('/dependency-maintenance')
            ? _json({..._page(_row()), 'offset': 25})
            : _json({
                'ok': true,
                'dependency': {..._row(), ...change},
              }),
      );
      await expectLater(
        manager.fetchDependencyMaintenance(),
        throwsA(isA<PanelApiException>()),
      );
      for (final mismatch in [
        {'request_id': 'd' * 32},
        {'operation_id': 'd' * 32},
        {'original_result': 'succeeded'},
      ]) {
        change = mismatch;
        await expectLater(
          manager.fetchDependencyEvidence('a' * 32, 'b' * 32),
          throwsA(isA<PanelApiException>()),
        );
        await expectLater(
          manager.cleanupOrphanDependency(
            PanelDependencyMaintenance.fromJson(_row()),
          ),
          throwsA(isA<PanelApiException>()),
        );
      }
    },
  );

  testWidgets('old panels do not receive maintenance requests', (tester) async {
    final paths = <String>[];
    final manager = _manager((request) async {
      paths.add(request.url.path);
      return _json(_capabilities(supported: false));
    });
    await tester.pumpWidget(_view(manager));
    await pumpUntilFound(tester, find.text('此面板版本尚不支持独立依赖现场维护'));
    expect(paths, everyElement(endsWith('/capabilities')));
  });

  testWidgets(
    'confirmed asynchronous cleanup polls GET and preserves unknown original result',
    (tester) async {
      var posts = 0;
      var queries = 0;
      final manager = _manager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return _json(_capabilities());
        }
        if (request.url.path.endsWith('/dependency-maintenance')) {
          return _json(_page(_row()));
        }
        if (request.method == 'POST') {
          posts++;
          return _json({
            'ok': true,
            'dependency': _row(state: 'requested'),
          }, 202);
        }
        queries++;
        return _json({'ok': true, 'dependency': _row(state: 'finalized')});
      });
      await tester.pumpWidget(_view(manager));
      await pumpUntilFound(tester, find.text('清理依赖资源'));
      expect(posts, 0);
      expect(queries, 0);
      await _confirm(tester);
      await pumpUntilFound(tester, find.text('依赖资源维护已结束，原始证据保留'));
      expect(find.text('原安装与恢复结果未知'), findsOneWidget);
      expect(posts, 1);
      expect(queries, 1);
      expect(find.text('查询原依赖现场'), findsNothing);
    },
  );

  testWidgets('lost POST response only queries the original operation', (
    tester,
  ) async {
    var posts = 0;
    var queries = 0;
    final manager = _manager((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return _json(_capabilities());
      }
      if (request.url.path.endsWith('/dependency-maintenance')) {
        return _json(_page(_row()));
      }
      if (request.method == 'POST') {
        posts++;
        return _json({'ok': false, 'msg': 'response lost'}, 503);
      }
      queries++;
      expect(request.url.path, endsWith('/${'a' * 32}/${'b' * 32}'));
      return _json({'ok': true, 'dependency': _row(state: 'finalized')});
    });
    await tester.pumpWidget(_view(manager));
    await _confirm(tester);
    await pumpUntilFound(tester, find.text('依赖资源维护已结束，原始证据保留'));
    expect(posts, 1);
    expect(queries, 1);
  });

  testWidgets(
    'wrong operation responses preserve pending query and forbid another POST',
    (tester) async {
      var posts = 0;
      final manager = _manager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return _json(_capabilities());
        }
        if (request.url.path.endsWith('/dependency-maintenance')) {
          return _json(_page(_row()));
        }
        if (request.method == 'POST') posts++;
        return _json({
          'ok': true,
          'dependency': _row(state: 'finalized', operation: 'd'),
        });
      });
      await tester.pumpWidget(_view(manager));
      await _confirm(tester);
      await pumpUntilFound(tester, find.text('清理结果尚未确认，请查询原依赖现场。'));
      expect(find.text('查询原依赖现场'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '清理依赖资源'),
            )
            .onPressed,
        isNull,
      );
      expect(posts, 1);
    },
  );

  testWidgets(
    'background drops late POST 401 and resumes with manual original GET only',
    (tester) async {
      final response = Completer<http.Response>();
      var posts = 0;
      var queries = 0;
      var unauthorized = 0;
      final manager = _manager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return _json(_capabilities());
        }
        if (request.url.path.endsWith('/dependency-maintenance')) {
          return _json(_page(_row()));
        }
        if (request.method == 'POST') {
          posts++;
          return response.future;
        }
        queries++;
        return _json({'ok': true, 'dependency': _row(state: 'finalized')});
      });
      await tester.pumpWidget(
        _view(
          manager,
          onUnauthorized: (_) async {
            unauthorized++;
          },
        ),
      );
      await _confirm(tester);
      await pumpUntil(tester, () => posts == 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(find.text('原安装与恢复结果未知'), findsNothing);
      response.complete(
        _json({'ok': false, 'msg': 'expired old request'}, 401),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(unauthorized, 0);
      expect(queries, 0);
      await tester.tap(find.text('查询原依赖现场'));
      await pumpUntilFound(tester, find.text('依赖资源维护已结束，原始证据保留'));
      expect(queries, 1);
      expect(posts, 1);
    },
  );

  testWidgets('background invalidates the confirmation dialog', (tester) async {
    var posts = 0;
    final manager = _manager((request) async {
      if (request.method == 'POST') posts++;
      return request.url.path.endsWith('/capabilities')
          ? _json(_capabilities())
          : _json(_page(_row()));
    });
    await tester.pumpWidget(_view(manager));
    await pumpUntilFound(tester, find.text('清理依赖资源'));
    await tester.tap(find.text('清理依赖资源'));
    await pumpUntilFound(tester, find.text('确认清理资源'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('确认清理资源'), findsNothing);
    expect(posts, 0);
  });

  testWidgets('switching panel isolates an old POST and its late 401', (
    tester,
  ) async {
    final oldResponse = Completer<http.Response>();
    var posts = 0;
    var unauthorized = 0;
    final old = _manager((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return _json(_capabilities());
      }
      if (request.url.path.endsWith('/dependency-maintenance')) {
        return _json(_page(_row()));
      }
      posts++;
      return oldResponse.future;
    });
    final next = _manager(
      (request) async => request.url.path.endsWith('/capabilities')
          ? _json(_capabilities())
          : _json(_page(_row(operation: 'd'))),
    );
    await tester.pumpWidget(
      _view(
        old,
        onUnauthorized: (_) async {
          unauthorized++;
        },
      ),
    );
    await _confirm(tester);
    await pumpUntil(tester, () => posts == 1);
    await tester.pumpWidget(
      _view(
        next,
        onUnauthorized: (_) async {
          unauthorized++;
        },
      ),
    );
    await pumpUntilFound(tester, find.text('依赖操作：${'d' * 32}'));
    oldResponse.complete(_json({'ok': false, 'msg': 'expired old panel'}, 401));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(unauthorized, 0);
    expect(find.text('查询原依赖现场'), findsNothing);
    expect(find.text('依赖操作：${'d' * 32}'), findsOneWidget);
  });

  testWidgets('current 401 expires the view and stops followup requests', (
    tester,
  ) async {
    var unauthorized = 0;
    final requests = <http.Request>[];
    final manager = _manager((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/capabilities')) {
        return _json(_capabilities());
      }
      if (request.url.path.endsWith('/dependency-maintenance')) {
        return _json(_page(_row()));
      }
      return _json({'ok': false, 'msg': 'session expired'}, 401);
    });
    await tester.pumpWidget(
      _view(
        manager,
        onUnauthorized: (_) async {
          unauthorized++;
        },
      ),
    );
    await _confirm(tester);
    await pumpUntil(tester, () => unauthorized == 1);
    expect(requests.where((request) => request.method == 'POST'), hasLength(1));
    expect(
      requests.where(
        (request) =>
            request.method == 'GET' &&
            !request.url.path.endsWith('/capabilities') &&
            !request.url.path.endsWith('/dependency-maintenance'),
      ),
      isEmpty,
    );
    expect(find.text('原安装与恢复结果未知'), findsNothing);
  });

  testWidgets(
    '320dp large text and failed restore history retain independent maintenance',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manager = _manager((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return _json(_capabilities());
        }
        if (request.url.path.endsWith('/dependency-maintenance')) {
          return _json(_page(_row()));
        }
        if (request.method == 'POST') {
          return _json({'ok': true, 'dependency': _row(state: 'finalized')});
        }
        return _json({'ok': false, 'msg': 'restore history unreadable'}, 503);
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
      await pumpUntilFound(tester, find.text('restore history unreadable'));
      await tester.ensureVisible(find.text('现场维护'));
      await tester.pumpAndSettle();
      expect(find.text('现场维护').hitTestable(), findsOneWidget);
      await tester.tap(find.text('现场维护').hitTestable());
      await pumpUntilFound(tester, find.text('依赖资源'));
      await tester.tap(find.text('依赖资源'));
      await _confirm(tester);
      await pumpUntilFound(tester, find.text('依赖资源维护已结束，原始证据保留'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_view(manager, scale: 2));
      await pumpUntilFound(tester, find.text('清理依赖资源'));
      await _confirm(tester);
      await pumpUntilFound(tester, find.text('依赖资源维护已结束，原始证据保留'));
      expect(tester.takeException(), isNull);
    },
  );
}
