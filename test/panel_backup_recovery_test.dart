import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/features/panel_backup_view.dart';
import 'package:fls_for_android/models/panel_backup.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_backup_manager.dart';
import 'package:fls_for_android/services/panel_backup_recovery.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

const _panel = 'https://panel.example/prefix';
final _requestId = 'a' * 32;

Map<String, dynamic> _summary({bool deleting = false}) => {
  'request_id': _requestId,
  'kind': deleting ? 'delete' : 'create',
  'status': 'succeeded',
  'active': false,
  'accepted': true,
  if (deleting) ...{
    'filename': 'config.tar.gz',
    'version': 'b' * 64,
    'deleted': true,
  } else
    'items': ['data', 'scripts'],
};

PanelBackupFile _file({String name = 'config.tar.gz', String version = 'b'}) =>
    PanelBackupFile.fromJson({
      'name': name,
      'version': version * 64,
      'size_bytes': 42,
      'modified_at': '2026-11-28 16:00:00',
    });

http.Response _json(Object value, [int code = 200]) =>
    utf8Response(jsonEncode(value), code);

PanelBackupManager _manager(
  Future<http.Response> Function(http.Request) handler, {
  PanelBackupRecovery? recovery,
  String panel = _panel,
}) {
  final api = PanelApiClient(
    baseUrl: panel,
    credentials: const PanelSessionCredentials(
      cookie: 'fls_native_session=session',
      csrfToken: 'csrf',
    ),
    client: panelMockClient(handler),
  );
  addTearDown(api.close);
  return PanelBackupManager(api, recovery: recovery);
}

http.Response _lists(http.Request request, {bool fail = false}) {
  if (fail) return _json({'ok': false, 'msg': 'list unavailable'}, 503);
  if (request.url.path.endsWith('/capabilities')) {
    return _json({
      'ok': true,
      'items': ['data', 'scripts'],
      'formats': ['tar.gz'],
      'upload_limit_bytes': 100,
      'extracted_limit_bytes': 200,
      'entry_limit': 30,
    });
  }
  return _json({'ok': true, 'items': [], 'page': 1, 'pages': 1, 'total': 0});
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
  home: PanelBackupView(
    manager: manager,
    onUnauthorized: onUnauthorized ?? (_) async {},
  ),
);

Future<void> _create(WidgetTester tester) async {
  await pumpUntilFound(tester, find.text('文件 · 0'));
  await tester.tap(find.byTooltip('创建备份'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('开始备份'));
}

void main() {
  test('original request summaries reject invalid or contradictory fields', () {
    final changes = <Map<String, dynamic>>[
      {'request_id': 'not-an-id'},
      {'kind': 'restore'},
      {'status': 'complete'},
      {'active': 'false'},
      {'accepted': 1},
      {
        'items': ['data', 1],
      },
      {
        'items': ['data', 'data'],
      },
      {'items': []},
      {'status': 'running', 'active': false},
      {'status': 'running', 'active': true, 'accepted': false},
      {'status': 'succeeded', 'accepted': null},
      {
        'job': {
          'id': 'c' * 32,
          'items': ['data', 'scripts'],
          'status': 'succeeded',
          'active': false,
        },
      },
    ];
    for (final change in changes) {
      expect(
        () => PanelBackupRequest.fromJson({
          'ok': true,
          'request': {..._summary(), ...change},
        }),
        throwsFormatException,
        reason: change.toString(),
      );
    }
    for (final change in <Map<String, dynamic>>[
      {'filename': '../config.tar.gz'},
      {'version': 'bad'},
      {'deleted': 'true'},
      {'deleted': false},
      {'status': 'unknown', 'deleted': true},
      {
        'items': ['data'],
      },
      {'status': 'failed'},
    ]) {
      expect(
        () => PanelBackupRequest.fromJson({
          'ok': true,
          'request': {..._summary(deleting: true), ...change},
        }),
        throwsFormatException,
        reason: change.toString(),
      );
    }
    expect(
      PanelBackupRequest.fromJson({
        'ok': true,
        'request': {..._summary(), 'status': 'unknown'},
      }).terminal,
      isFalse,
    );
  });

  test(
    'lost creation and 404 remain queryable across manager recreation without replay',
    () async {
      var posts = 0;
      var known = false;
      final recovery = PanelBackupRecovery(_panel);
      Future<http.Response> handler(http.Request request) async {
        if (request.method == 'POST') {
          posts++;
          expect(recovery.operations.single.requestId, _requestId);
          return _json({'ok': false}, 503);
        }
        expect(
          request.url.path,
          '/prefix/api/backup/native/requests/$_requestId',
        );
        return known
            ? _json({'ok': true, 'request': _summary()})
            : _json({'ok': false}, 404);
      }

      var manager = _manager(handler, recovery: recovery);
      await expectLater(
        manager.create(requestId: _requestId, items: ['scripts', 'data']),
        throwsA(isA<PanelApiException>()),
      );
      await expectLater(
        manager.requestStatus(_requestId),
        throwsA(
          isA<PanelApiException>().having((e) => e.statusCode, 'code', 404),
        ),
      );
      expect(
        () => recovery.review(recovery.operations.single),
        throwsStateError,
      );
      manager = _manager(handler, recovery: recovery);
      await expectLater(
        manager.create(requestId: 'c' * 32, items: ['data', 'scripts']),
        throwsStateError,
      );
      known = true;
      await manager.requestStatus(_requestId);
      expect(posts, 1);
      expect(recovery.operations.single.canReview, isTrue);
      recovery.review(recovery.operations.single);
      expect(recovery.operations, isEmpty);
    },
  );

  test('query checks original ID kind and exact immutable intent', () async {
    final recovery = PanelBackupRecovery(_panel);
    final items = ['scripts', 'data'];
    recovery.admitCreate(_requestId, items);
    items.clear();
    var summary = _summary();
    final manager = _manager(
      (_) async => _json({'ok': true, 'request': summary}),
      recovery: recovery,
    );
    for (final wrong in [
      {..._summary(), 'request_id': 'c' * 32},
      _summary(deleting: true),
      {
        ..._summary(),
        'items': ['scripts'],
      },
    ]) {
      summary = wrong;
      await expectLater(
        manager.requestStatus(_requestId),
        throwsA(isA<PanelApiException>()),
      );
      expect(recovery.operations.single.result, isNull);
    }
    summary = _summary();
    await manager.requestStatus(_requestId);
    expect(recovery.operations.single.canReview, isTrue);
  });

  test(
    'delete query never treats a same-name replacement as the original file',
    () async {
      var summary = _summary(deleting: true);
      var posts = 0;
      final manager = _manager((request) async {
        if (request.method == 'POST') {
          posts++;
          expect(jsonDecode(request.body), {
            'request_id': _requestId,
            'filename': 'config.tar.gz',
            'version': 'b' * 64,
          });
          return _json({'ok': false}, 503);
        }
        return _json({'ok': true, 'request': summary});
      });
      await expectLater(
        manager.deleteFile(requestId: _requestId, file: _file()),
        throwsA(isA<PanelApiException>()),
      );
      for (final change in [
        {'version': 'c' * 64},
        {'filename': 'replacement.tar.gz'},
      ]) {
        summary = {..._summary(deleting: true), ...change};
        await expectLater(
          manager.requestStatus(_requestId),
          throwsA(isA<PanelApiException>()),
        );
        expect(manager.recovery.operations.single.canReview, isFalse);
      }
      summary = _summary(deleting: true);
      await manager.requestStatus(_requestId);
      expect(manager.recovery.operations.single.result!.deleted, isTrue);
      expect(posts, 1);
    },
  );

  test(
    'POST responses must confirm original identities and typed results',
    () async {
      for (final change in <Map<String, dynamic>>[
        {'request_id': 'c' * 32},
        {'accepted': 'true'},
        {
          'job': {
            'id': 'c' * 32,
            'status': 'succeeded',
            'active': false,
            'items': ['data'],
          },
        },
        {
          'job': {
            'id': _requestId,
            'status': 'succeeded',
            'active': false,
            'items': ['scripts'],
          },
        },
      ]) {
        final manager = _manager(
          (_) async => _json({
            'ok': true,
            'accepted': true,
            'request_id': _requestId,
            'job': null,
            ...change,
          }),
        );
        await expectLater(
          manager.create(requestId: _requestId, items: ['data']),
          throwsA(isA<PanelApiException>()),
        );
        expect(manager.recovery.operations.single.result, isNull);
      }
      for (final change in <Map<String, dynamic>>[
        {'request_id': 'c' * 32},
        {'filename': 'new.tar.gz'},
        {'version': 'c' * 64},
        {'deleted': 'true'},
        {'status': 'unknown'},
      ]) {
        final manager = _manager(
          (_) async => _json({
            'ok': true,
            'accepted': true,
            'request_id': _requestId,
            'filename': 'config.tar.gz',
            'version': 'b' * 64,
            'deleted': true,
            'status': 'deleted',
            ...change,
          }),
        );
        await expectLater(
          manager.deleteFile(requestId: _requestId, file: _file()),
          throwsA(isA<PanelApiException>()),
        );
        expect(manager.recovery.operations.single.result, isNull);
      }
    },
  );

  test(
    'recovery is bounded and rejects a different panel before any request',
    () {
      final recovery = PanelBackupRecovery(_panel);
      for (var index = 0; index < PanelBackupRecovery.maxOperations; index++) {
        recovery.admitDelete(
          index.toRadixString(16).padLeft(32, '0'),
          _file(name: 'backup-$index.tar.gz'),
        );
      }
      expect(() => recovery.admitDelete('f' * 32, _file()), throwsStateError);
      expect(recovery.operations.length, PanelBackupRecovery.maxOperations);
      expect(
        () => _manager(
          (_) async => throw StateError('must not request'),
          recovery: recovery,
          panel: 'https://other.example',
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'older query completion cannot overwrite a newer original result',
    () async {
      final recovery = PanelBackupRecovery(_panel)
        ..admitCreate(_requestId, ['data', 'scripts']);
      final first = Completer<http.Response>();
      final second = Completer<http.Response>();
      var queries = 0;
      final manager = _manager(
        (_) => ++queries == 1 ? first.future : second.future,
        recovery: recovery,
      );
      final old = manager.requestStatus(_requestId);
      final current = manager.requestStatus(_requestId);
      second.complete(_json({'ok': true, 'request': _summary()}));
      await current;
      first.complete(
        _json({
          'ok': true,
          'request': {..._summary(), 'status': 'unknown'},
        }),
      );
      await old;
      expect(recovery.operations.single.result!.status, 'succeeded');
    },
  );

  for (final code in [401, 503]) {
    testWidgets(
      'create $code survives reopen and reauthentication with failed lists',
      (tester) async {
        final recovery = PanelBackupRecovery(_panel);
        var posts = 0;
        var queries = 0;
        var expired = 0;
        var known = false;
        var failLists = false;
        String? originalId;
        Future<http.Response> handler(http.Request request) async {
          if (request.method == 'POST') {
            posts++;
            originalId =
                (jsonDecode(request.body) as Map)['request_id'] as String;
            return _json({'ok': false}, code);
          }
          if (request.url.path.contains('/requests/')) {
            queries++;
            return known
                ? _json({
                    'ok': true,
                    'request': {..._summary(), 'request_id': originalId},
                  })
                : _json({'ok': false}, 404);
          }
          return _lists(request, fail: failLists);
        }

        await tester.pumpWidget(
          _view(
            _manager(handler, recovery: recovery),
            onUnauthorized: (_) async {
              expired++;
            },
          ),
        );
        await _create(tester);
        await pumpUntil(
          tester,
          () => code == 401 ? expired == 1 : queries == 1,
        );
        await tester.pumpAndSettle();
        expect(recovery.operations.single.requestId, originalId);
        expect(recovery.operations.single.canReview, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        failLists = true;
        known = true;
        await tester.pumpWidget(_view(_manager(handler, recovery: recovery)));
        await pumpUntilFound(tester, find.text('list unavailable'));
        await tester.tap(find.byTooltip('原请求记录'));
        await tester.pumpAndSettle();
        expect(find.text(originalId!), findsOneWidget);
        expect(find.byTooltip('已核对，移除记录'), findsNothing);
        await tester.tap(find.byTooltip('查询原请求'));
        await pumpUntilFound(tester, find.text('已完成'));
        expect(posts, 1);
        expect(queries, code == 401 ? 1 : 2);
        await tester.tap(find.byTooltip('已核对，移除记录'));
        await tester.pump();
        expect(recovery.operations, isEmpty);
        expect(find.text('暂无原请求'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final code in [200, 401]) {
    testWidgets(
      'brief background invalidates POST $code and preserves manual query',
      (tester) async {
        final response = Completer<http.Response>();
        var posts = 0;
        var queries = 0;
        var expired = 0;
        String? id;
        final manager = _manager((request) async {
          if (request.method == 'POST') {
            posts++;
            id = (jsonDecode(request.body) as Map)['request_id'] as String;
            return response.future;
          }
          if (request.url.path.contains('/requests/')) {
            queries++;
            return _json({
              'ok': true,
              'request': {..._summary(), 'request_id': id},
            });
          }
          return _lists(request);
        });
        await tester.pumpWidget(
          _view(
            manager,
            onUnauthorized: (_) async {
              expired++;
            },
          ),
        );
        await _create(tester);
        await pumpUntil(tester, () => posts == 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        response.complete(
          _json(
            code == 200
                ? {'ok': true, 'accepted': true, 'request_id': id, 'job': null}
                : {'ok': false},
            code,
          ),
        );
        await pumpUntil(
          tester,
          () =>
              tester.widget<IconButton>(find.byTooltip('原请求记录')).onPressed !=
              null,
        );
        expect(expired, 0);
        expect(queries, 0);
        expect(manager.recovery.operations.single.result, isNull);
        expect(find.text('备份请求已提交'), findsNothing);
        await tester.tap(find.byTooltip('原请求记录'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('查询原请求'));
        await pumpUntilFound(tester, find.text('已完成'));
        expect(queries, 1);
        expect(posts, 1);
      },
    );

    testWidgets(
      'brief background invalidates query $code and closes its dialog',
      (tester) async {
        final response = Completer<http.Response>();
        final recovery = PanelBackupRecovery(_panel)
          ..admitDelete(_requestId, _file());
        var queries = 0;
        var expired = 0;
        final manager = _manager((request) async {
          if (request.url.path.contains('/requests/')) {
            queries++;
            return queries == 1
                ? response.future
                : _json({'ok': true, 'request': _summary(deleting: true)});
          }
          return _lists(request);
        }, recovery: recovery);
        await tester.pumpWidget(
          _view(
            manager,
            onUnauthorized: (_) async {
              expired++;
            },
          ),
        );
        await pumpUntilFound(tester, find.text('文件 · 0'));
        await tester.tap(find.byTooltip('原请求记录'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('查询原请求'));
        await pumpUntil(tester, () => queries == 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        response.complete(
          _json(
            code == 200
                ? {'ok': true, 'request': _summary(deleting: true)}
                : {'ok': false},
            code,
          ),
        );
        await tester.pumpAndSettle();
        expect(expired, 0);
        expect(find.byType(AlertDialog), findsNothing);
        expect(recovery.operations.single.result, isNull);
        await tester.tap(find.byTooltip('原请求记录'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('查询原请求'));
        await pumpUntilFound(tester, find.text('已完成'));
        expect(queries, 2);
        expect(expired, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'delete retains its exact file version across leaving and failed lists',
    (tester) async {
      final recovery = PanelBackupRecovery(_panel);
      var posts = 0;
      var queries = 0;
      var known = false;
      var failLists = false;
      String? id;
      Future<http.Response> handler(http.Request request) async {
        if (request.method == 'POST') {
          posts++;
          expect(request.url.path, endsWith('/files/delete'));
          final body = jsonDecode(request.body) as Map;
          id = body['request_id'] as String;
          expect(body['filename'], 'config.tar.gz');
          expect(body['version'], 'b' * 64);
          return _json({'ok': false}, 503);
        }
        if (request.url.path.contains('/requests/')) {
          queries++;
          return known
              ? _json({
                  'ok': true,
                  'request': {..._summary(deleting: true), 'request_id': id},
                })
              : _json({'ok': false}, 404);
        }
        if (!failLists && request.url.path.endsWith('/files')) {
          return _json({
            'ok': true,
            'items': [
              {
                'name': 'config.tar.gz',
                'version': 'b' * 64,
                'size_bytes': 42,
                'modified_at': '',
              },
            ],
            'page': 1,
            'pages': 1,
            'total': 1,
          });
        }
        return _lists(request, fail: failLists);
      }

      await tester.pumpWidget(_view(_manager(handler, recovery: recovery)));
      await pumpUntilFound(tester, find.byTooltip('备份操作'));
      await tester.tap(find.byTooltip('备份操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await pumpUntil(tester, () => queries == 1);
      await tester.pumpAndSettle();
      expect(recovery.operations.single.version, 'b' * 64);
      await tester.pumpWidget(const SizedBox.shrink());
      failLists = true;
      known = true;
      await tester.pumpWidget(_view(_manager(handler, recovery: recovery)));
      await pumpUntilFound(tester, find.text('list unavailable'));
      await tester.tap(find.byTooltip('原请求记录'));
      await tester.pumpAndSettle();
      expect(find.text('b' * 64), findsOneWidget);
      await tester.tap(find.byTooltip('查询原请求'));
      await pumpUntilFound(tester, find.text('已完成'));
      expect(posts, 1);
      expect(queries, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final code in [200, 401]) {
    testWidgets('switching panels ignores the old creation response $code', (
      tester,
    ) async {
      final response = Completer<http.Response>();
      var posts = 0;
      var expired = 0;
      String? id;
      final old = _manager((request) async {
        if (request.method == 'POST') {
          posts++;
          id = (jsonDecode(request.body) as Map)['request_id'] as String;
          return response.future;
        }
        return _lists(request);
      });
      await tester.pumpWidget(
        _view(
          old,
          onUnauthorized: (_) async {
            expired++;
          },
        ),
      );
      await _create(tester);
      await pumpUntil(tester, () => posts == 1);
      final current = _manager(
        (request) async => _lists(request),
        panel: 'https://other.example',
      );
      await tester.pumpWidget(_view(current));
      await pumpUntilFound(tester, find.text('文件 · 0'));
      response.complete(
        _json(
          code == 200
              ? {'ok': true, 'accepted': true, 'request_id': id, 'job': null}
              : {'ok': false},
          code,
        ),
      );
      await tester.tap(find.byTooltip('原请求记录'));
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.text('暂无原请求'));
      expect(old.recovery.operations.single.result, isNull);
      expect(expired, 0);
      expect(current.recovery.operations, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.5, 2.0]) {
    testWidgets('original delete receipt fits 320dp at scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final recovery = PanelBackupRecovery(_panel)
        ..admitDelete(_requestId, _file());
      var queries = 0;
      final manager = _manager((request) async {
        if (request.url.path.contains('/requests/')) {
          queries++;
          return _json({'ok': false}, 404);
        }
        return _lists(request, fail: true);
      }, recovery: recovery);
      await tester.pumpWidget(_view(manager, scale: scale));
      await pumpUntilFound(tester, find.text('list unavailable'));
      await tester.tap(find.byTooltip('原请求记录'));
      await tester.pumpAndSettle();
      final query = find.byTooltip('查询原请求');
      await tester.ensureVisible(query);
      await tester.pumpAndSettle();
      expect(query.hitTestable(), findsOneWidget);
      await tester.tap(query);
      await pumpUntilFound(tester, find.text('尚未查到原请求，执行结果仍未确认'));
      expect(queries, 1);
      expect(find.byTooltip('已核对，移除记录'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
