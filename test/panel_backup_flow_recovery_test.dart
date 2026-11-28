import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
final _preflightId = 'a' * 32;
final _restoreId = 'c' * 32;
final _childId = 'e' * 32;

Map<String, dynamic> _preflight({bool active = false}) => {
  'preflight_id': _preflightId,
  'status': active ? 'checking' : 'ready',
  'active': active,
  'cancel_allowed': active,
  'filename': 'full.zip',
  'format': 'zip',
  'archive_size_bytes': 13,
  'archive_sha256': 'b' * 64,
  'items': ['data'],
  'entry_count': 2,
  'expanded_bytes': 20,
  'dependency_files': ['requirements.txt'],
  'warnings': [],
  'error_code': '',
  'expires_at': 1796000000,
};

PanelBackupPreflight _ready() =>
    PanelBackupPreflight.fromJson({'ok': true, 'preflight': _preflight()});

Map<String, dynamic> _restore({
  String state = 'restored',
  String? child,
  bool dependencies = false,
  String followup = 'succeeded',
}) => {
  'request_id': _restoreId,
  'preflight_id': _preflightId,
  'filename': 'full.zip',
  'archive_sha256': 'b' * 64,
  'archive_size_bytes': 13,
  'restore_items': ['data'],
  'restore_dependencies': dependencies,
  'state': state,
  'phase': state,
  'active': state == 'accepted',
  'committed': state == 'restored',
  'live_state_unchanged': false,
  'restore_outcome_unknown': state == 'unknown',
  'error': '',
  'created_at': 1,
  'updated_at': 2,
  'scheduler': {
    'state': !dependencies && child != null ? followup : 'pending',
    'required': true,
    'operation_id': !dependencies ? child ?? '' : '',
    'error': '',
  },
  'dependencies': {
    'state': dependencies
        ? (child == null ? 'pending' : followup)
        : 'not_requested',
    'operation_id': dependencies ? child ?? '' : '',
    'error': '',
    'output': child == null ? '' : 'Sensitive installation output',
  },
};

http.Response _json(Object value, [int status = 200]) =>
    utf8Response(jsonEncode(value), status);

PanelBackupManager _manager(
  Future<http.Response> Function(http.Request) handler, {
  PanelBackupRecovery? recovery,
}) {
  final api = PanelApiClient(
    baseUrl: _panel,
    credentials: const PanelSessionCredentials(
      cookie: 'fls_native_session=session',
      csrfToken: 'csrf',
    ),
    client: panelMockClient(handler),
  );
  addTearDown(api.close);
  return PanelBackupManager(api, recovery: recovery);
}

PanelBackupRecovery _restoreRecovery({bool dependencies = false}) {
  final recovery = PanelBackupRecovery(_panel);
  recovery.admitRestore(
    requestId: _restoreId,
    preflight: _ready(),
    items: ['data'],
    restoreDependencies: dependencies,
  );
  return recovery;
}

http.Response _lists(
  http.Request request, {
  bool fail = false,
  bool history = false,
}) {
  if (fail) return _json({'ok': false}, 503);
  if (request.url.path.endsWith('/capabilities')) {
    return _json({
      'ok': true,
      'items': ['data', 'scripts'],
      'formats': ['zip'],
      'upload_limit_bytes': 100,
      'extracted_limit_bytes': 200,
      'entry_limit': 30,
      'preflight_enabled': true,
      'restore_enabled': true,
    });
  }
  if (request.url.path.endsWith('/restore-maintenance')) {
    return _json({'ok': true, 'maintenance': null});
  }
  if (request.url.path.endsWith('/restores')) {
    return _json({
      'ok': true,
      'items': history ? [_restore()] : [],
      'total': history ? 1 : 0,
      'limit': 25,
      'offset': 0,
      'has_more': false,
    });
  }
  return _json({'ok': true, 'items': [], 'page': 1, 'pages': 1, 'total': 0});
}

Widget _view(
  PanelBackupManager manager, {
  double scale = 1,
  Future<void> Function(Object)? onUnauthorized,
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

Future<void> _openRecords(WidgetTester tester) async {
  await pumpUntilFound(tester, find.byTooltip('原请求记录'));
  await tester.tap(find.byTooltip('原请求记录'));
  await tester.pumpAndSettle();
}

Future<void> _queryRecord(WidgetTester tester) async {
  final query = find.byTooltip('查询原请求').first;
  await tester.ensureVisible(query);
  await tester.tap(query);
}

Future<void> _openRestoreHistory(WidgetTester tester) async {
  await pumpUntilFound(tester, find.text('文件 · 0'));
  await tester.tap(find.text('恢复'));
  await pumpUntilFound(tester, find.byTooltip('查询此恢复请求'));
  await tester.pumpAndSettle();
  final query = find.byTooltip('查询此恢复请求');
  await tester.ensureVisible(query);
  await tester.tap(query);
  await pumpUntilFound(tester, find.text('仅重新加载调度器'));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'preflight rejects coercion, invalid arrays and contradictory readiness',
    () {
      for (final changes in <Map<String, dynamic>>[
        {'active': 'false'},
        {'cancel_allowed': 1},
        {'archive_size_bytes': '13'},
        {'expanded_bytes': -1},
        {'expires_at': null},
        {
          'items': ['data', 1],
        },
        {
          'warnings': [false],
        },
        {
          'dependency_files': ['requirements.txt', 1],
        },
        {'status': 'ready', 'active': true},
        {'cancel_allowed': true},
        {'archive_sha256': ''},
        {'items': []},
      ]) {
        expect(
          () => PanelBackupPreflight.fromJson({
            'ok': true,
            'preflight': {..._preflight(), ...changes},
          }),
          throwsFormatException,
          reason: changes.toString(),
        );
      }
    },
  );

  test(
    'lost preflight upload keeps identity and only GET recovers after reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp('fls-flow-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/archive.zip');
      await file.writeAsString('archive bytes');
      final recovery = PanelBackupRecovery(_panel);
      var posts = 0;
      var missing = true;
      Future<http.Response> handler(http.Request request) async {
        if (request.method == 'POST') {
          posts++;
          expect(recovery.operations.single.kind, 'preflight');
          return _json({'ok': false}, 503);
        }
        return missing
            ? _json({'ok': false}, 404)
            : _json({'ok': true, 'preflight': _preflight()});
      }

      var manager = _manager(handler, recovery: recovery);
      Future<PanelBackupPreflight> upload(String id) => manager.createPreflight(
        filePath: file.path,
        filename: 'full.zip',
        requestId: id,
        maxBytes: 100,
        onProgress: (_, _) {},
      );
      await expectLater(
        upload(_preflightId),
        throwsA(isA<PanelApiException>()),
      );
      manager = _manager(handler, recovery: recovery);
      await expectLater(
        manager.queryOperation(recovery.operations.single),
        throwsA(
          isA<PanelApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
      expect(
        () => recovery.review(recovery.operations.single),
        throwsStateError,
      );
      await expectLater(upload('d' * 32), throwsStateError);
      missing = false;
      await manager.queryOperation(recovery.operations.single);
      expect(recovery.operations.single.canReview, isTrue);
      expect(posts, 1);
    },
  );

  test(
    'preflight GET and cancel must match original ID and filename',
    () async {
      final recovery = PanelBackupRecovery(_panel)
        ..admitPreflight(_preflightId, 'full.zip');
      var response = _preflight();
      final manager = _manager(
        (_) async => _json({'ok': true, 'preflight': response}),
        recovery: recovery,
      );
      for (final changes in [
        {'preflight_id': 'f' * 32},
        {'filename': 'other.zip'},
      ]) {
        response = {..._preflight(), ...changes};
        await expectLater(
          manager.fetchPreflight(_preflightId),
          throwsA(isA<PanelApiException>()),
        );
        await expectLater(
          manager.cancelPreflight(_preflightId),
          throwsA(isA<PanelApiException>()),
        );
        expect(recovery.operations.every((op) => op.status == null), isTrue);
      }
      response = {..._preflight(), 'status': 'cancelled'};
      await manager.fetchPreflight(_preflightId);
      expect(recovery.operations, hasLength(2));
      expect(recovery.operations.every((op) => op.canReview), isTrue);
    },
  );

  test(
    'lost restore is retained before dispatch and rejects duplicate or wrong intent',
    () async {
      final recovery = PanelBackupRecovery(_panel);
      var posts = 0;
      var response = _restore();
      final manager = _manager((request) async {
        if (request.method == 'POST') {
          posts++;
          expect(recovery.operations.single.preflightId, _preflightId);
          return _json({'ok': false}, 503);
        }
        return _json({'ok': true, 'restore': response});
      }, recovery: recovery);
      Future<PanelBackupRestore> submit(String id) => manager.createRestore(
        requestId: id,
        preflight: _ready(),
        items: ['data'],
        restoreDependencies: false,
        confirmDataImpact: true,
      );
      await expectLater(submit(_restoreId), throwsA(isA<PanelApiException>()));
      await expectLater(submit('d' * 32), throwsStateError);
      for (final changes in <Map<String, dynamic>>[
        {'request_id': 'f' * 32},
        {'preflight_id': 'd' * 32},
        {'filename': 'other.zip'},
        {'archive_sha256': 'f' * 64},
        {
          'restore_items': ['data', 'scripts'],
        },
      ]) {
        response = {..._restore(), ...changes};
        await expectLater(
          manager.fetchRestore(_restoreId),
          throwsA(isA<PanelApiException>()),
        );
        expect(recovery.operations.single.status, isNull);
      }
      response = _restore();
      await manager.queryOperation(recovery.operations.single);
      expect(recovery.operations.single.canReview, isTrue);
      expect(posts, 1);
    },
  );

  for (final dependencies in [false, true]) {
    test(
      'followup $dependencies binds exact child and preserves unknown without replay',
      () async {
        final recovery = _restoreRecovery(dependencies: dependencies);
        var posts = 0;
        var response = _restore(dependencies: dependencies, child: 'f' * 32);
        final manager = _manager((request) async {
          if (request.method == 'POST') posts++;
          return _json({'ok': true, 'restore': response});
        }, recovery: recovery);
        Future<PanelBackupRestore> submit(String id) => dependencies
            ? manager.installRestoreDependencies(
                requestId: _restoreId,
                operationId: id,
              )
            : manager.reloadScheduler(requestId: _restoreId, operationId: id);
        await expectLater(submit(_childId), throwsA(isA<PanelApiException>()));
        final operation = recovery.operations.first;
        expect(operation.requestId, _childId);
        expect(operation.status, isNull);
        await expectLater(
          manager.queryOperation(operation),
          throwsA(isA<PanelApiException>()),
        );
        await expectLater(submit('d' * 32), throwsStateError);
        response = _restore(dependencies: dependencies, child: _childId);
        await manager.queryOperation(operation);
        expect(operation.canReview, isTrue);
        expect(posts, 1);
        expect(operation.result, isNull);
        expect(operation.items, ['data']);
        expect(operation.archiveSha256, 'b' * 64);
      },
    );
  }

  test(
    'invalidated and older preflight observations never replace new state',
    () async {
      final recovery = PanelBackupRecovery(_panel)
        ..admitPreflight(_preflightId, 'full.zip');
      final first = Completer<http.Response>();
      var count = 0;
      final manager = _manager(
        (_) async => ++count == 1
            ? first.future
            : _json({'ok': true, 'preflight': _preflight()}),
        recovery: recovery,
      );
      final old = manager.fetchPreflight(_preflightId);
      await Future<void>.delayed(Duration.zero);
      recovery.invalidateObservations();
      await manager.fetchPreflight(_preflightId);
      first.complete(
        _json({'ok': true, 'preflight': _preflight(active: true)}),
      );
      await old;
      expect(recovery.operations.single.status, 'ready');
    },
  );

  for (final preflight in [true, false]) {
    testWidgets(
      'reopened ${preflight ? 'preflight' : 'restore'} opens native details with unavailable lists',
      (tester) async {
        final recovery = preflight
            ? (PanelBackupRecovery(_panel)
                ..admitPreflight(_preflightId, 'full.zip'))
            : _restoreRecovery();
        final methods = <String>[];
        final manager = _manager((request) async {
          methods.add(request.method);
          if (request.url.path.contains('/preflights/')) {
            return _json({'ok': true, 'preflight': _preflight()});
          }
          if (request.url.path.endsWith('/restores/$_restoreId')) {
            return _json({'ok': true, 'restore': _restore()});
          }
          return _lists(request, fail: true);
        }, recovery: recovery);
        await tester.pumpWidget(_view(manager));
        await pumpUntilFound(tester, find.byType(MaterialBanner));
        await _openRecords(tester);
        await _queryRecord(tester);
        await pumpUntilFound(tester, find.byTooltip('查看原请求详情'));
        await tester.tap(find.byTooltip('查看原请求详情'));
        await tester.pumpAndSettle();
        expect(find.text(preflight ? '检查并提交恢复' : '目录已恢复'), findsOneWidget);
        expect(methods.every((method) => method == 'GET'), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final status in [200, 401]) {
    testWidgets(
      'preflight GET $status after brief background cannot update records or credentials',
      (tester) async {
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        final gate = Completer<http.Response>();
        var queries = 0;
        var expired = 0;
        final recovery = PanelBackupRecovery(_panel)
          ..admitPreflight(_preflightId, 'full.zip');
        final manager = _manager((request) async {
          if (request.url.path.contains('/preflights/')) {
            queries++;
            return gate.future;
          }
          return _lists(request);
        }, recovery: recovery);
        await tester.pumpWidget(
          _view(manager, onUnauthorized: (_) async => expired++),
        );
        await pumpUntilFound(tester, find.text('文件 · 0'));
        await _openRecords(tester);
        await _queryRecord(tester);
        await pumpUntil(tester, () => queries == 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        gate.complete(
          status == 200
              ? _json({'ok': true, 'preflight': _preflight()})
              : _json({'ok': false}, 401),
        );
        await tester.pumpAndSettle();
        expect(recovery.operations.single.status, isNull);
        expect(expired, 0);
        expect(queries, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final status in [200, 401]) {
    testWidgets(
      'followup POST $status after brief background retains child and stops observation',
      (tester) async {
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        final gate = Completer<http.Response>();
        var posts = 0;
        var queries = 0;
        var expired = 0;
        String? child;
        final manager = _manager((request) async {
          if (request.method == 'POST') {
            posts++;
            child = (jsonDecode(request.body) as Map)['operation_id'] as String;
            return gate.future;
          }
          if (request.url.path.endsWith('/restores/$_restoreId')) {
            queries++;
            return _json({'ok': true, 'restore': _restore()});
          }
          return _lists(request, history: true);
        });
        await tester.pumpWidget(
          _view(manager, onUnauthorized: (_) async => expired++),
        );
        await _openRestoreHistory(tester);
        await tester.ensureVisible(find.text('仅重新加载调度器'));
        await tester.tap(find.text('仅重新加载调度器'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认执行'));
        await pumpUntil(tester, () => posts == 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        gate.complete(
          status == 200
              ? _json({
                  'ok': true,
                  'restore': _restore(child: child, followup: 'running'),
                })
              : _json({'ok': false}, 401),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        expect(manager.recovery.operations.single.requestId, child);
        expect(manager.recovery.operations.single.status, isNull);
        expect(queries, 1);
        expect(posts, 1);
        expect(expired, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'restore polling ends after fifteen queries and remains manually queryable',
    (tester) async {
      var queries = 0;
      var posts = 0;
      final manager = _manager((request) async {
        if (request.method == 'POST') posts++;
        if (request.url.path.endsWith('/restores/$_restoreId')) {
          queries++;
          return _json({'ok': true, 'restore': _restore(state: 'accepted')});
        }
        return _lists(request, history: true);
      });
      await tester.pumpWidget(_view(manager));
      await pumpUntilFound(tester, find.text('文件 · 0'));
      await tester.tap(find.text('恢复'));
      await pumpUntilFound(tester, find.byTooltip('查询此恢复请求'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('查询此恢复请求'));
      await tester.tap(find.byTooltip('查询此恢复请求'));
      await pumpUntil(tester, () => queries == 1);
      for (var attempt = 0; attempt < 20 && queries < 16; attempt++) {
        await tester.pump(const Duration(seconds: 2));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await pumpUntil(
        tester,
        () =>
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, '查询原恢复请求'))
                .onPressed !=
            null,
      );
      expect(queries, 16);
      final query = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '查询原恢复请求'),
      );
      expect(query.onPressed, isNotNull);
      expect(posts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preflight polling yields after fifteen reads without reupload', (
    tester,
  ) async {
    var queries = 0;
    var posts = 0;
    final recovery = PanelBackupRecovery(_panel)
      ..admitPreflight(_preflightId, 'full.zip');
    final manager = _manager((request) async {
      if (request.method == 'POST') posts++;
      if (request.url.path.contains('/preflights/')) {
        queries++;
        return _json({'ok': true, 'preflight': _preflight(active: true)});
      }
      return _lists(request);
    }, recovery: recovery);
    await tester.pumpWidget(_view(manager));
    await pumpUntilFound(tester, find.text('文件 · 0'));
    await _openRecords(tester);
    await _queryRecord(tester);
    await pumpUntilFound(tester, find.byTooltip('查看原请求详情'));
    await tester.tap(find.byTooltip('查看原请求详情'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查询原预检查'));
    await tester.tap(find.text('查询原预检查'));
    await pumpUntil(tester, () => queries == 2);
    for (var attempt = 0; attempt < 20 && queries < 17; attempt++) {
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await pumpUntil(
      tester,
      () =>
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '查询原预检查'))
              .onPressed !=
          null,
    );
    expect(queries, 17);
    expect(posts, 0);
    expect(recovery.operations.single.status, 'checking');
    expect(recovery.operations.single.canReview, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'followup polling yields after fifteen reads with original child',
    (tester) async {
      var queries = 0;
      var posts = 0;
      final manager = _manager((request) async {
        if (request.method == 'POST') posts++;
        if (request.url.path.endsWith('/restores/$_restoreId')) {
          queries++;
          return _json({
            'ok': true,
            'restore': _restore(child: _childId, followup: 'running'),
          });
        }
        return _lists(request, history: true);
      });
      await tester.pumpWidget(_view(manager));
      await pumpUntilFound(tester, find.text('文件 · 0'));
      await tester.tap(find.text('恢复'));
      await pumpUntilFound(tester, find.byTooltip('查询此恢复请求'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('查询此恢复请求'));
      await tester.tap(find.byTooltip('查询此恢复请求'));
      await pumpUntil(tester, () => queries == 1);
      for (var attempt = 0; attempt < 20 && queries < 16; attempt++) {
        await tester.pump(const Duration(seconds: 2));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await pumpUntil(
        tester,
        () =>
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, '查询原恢复请求'))
                .onPressed !=
            null,
      );
      expect(queries, 16);
      expect(posts, 0);
      expect(find.textContaining('调度器：处理中'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'lost cancellation keeps the original legacy job ID without replay',
    () async {
      const jobId = 'legacy-backup_1';
      var posts = 0;
      var wrong = true;
      final manager = _manager((request) async {
        if (request.method == 'POST') {
          posts++;
          return _json({'ok': false}, 503);
        }
        return _json({
          'ok': true,
          'job': {
            'id': wrong ? 'other' : jobId,
            'items': ['data'],
            'status': 'cancelled',
            'active': false,
            'cancel_requested': true,
            'cancel_allowed': false,
          },
        });
      });
      await expectLater(
        manager.cancel(jobId),
        throwsA(isA<PanelApiException>()),
      );
      final record = manager.recovery.operations.single;
      expect(record.rootId, jobId);
      await expectLater(
        manager.queryOperation(record),
        throwsA(isA<PanelApiException>()),
      );
      wrong = false;
      await manager.queryOperation(record);
      expect(record.canReview, isTrue);
      expect(record.status, 'cancelled');
      expect(posts, 1);
    },
  );

  test(
    'explicit followup retry retains the previous queried unknown identity',
    () async {
      final recovery = _restoreRecovery();
      var state = 'unknown';
      var child = _childId;
      var posts = 0;
      final manager = _manager((request) async {
        if (request.method == 'POST') {
          posts++;
          child = jsonDecode(request.body)['operation_id'] as String;
        }
        return _json({
          'ok': true,
          'restore': _restore(child: child, followup: state),
        });
      }, recovery: recovery);
      await manager.reloadScheduler(requestId: _restoreId, operationId: child);
      final original = recovery.operations.first;
      await expectLater(
        manager.reloadScheduler(requestId: _restoreId, operationId: 'f' * 32),
        throwsStateError,
      );
      state = 'succeeded';
      await manager.reloadScheduler(
        requestId: _restoreId,
        operationId: 'f' * 32,
        confirmRetry: true,
      );
      expect(posts, 2);
      expect(original.status, 'unknown');
      expect(original.canReview, isFalse);
      expect(recovery.operations.first.status, 'succeeded');
      await expectLater(
        manager.queryOperation(original),
        throwsA(isA<PanelApiException>()),
      );
      expect(original.status, 'unknown');
    },
  );

  for (final status in [200, 401]) {
    testWidgets(
      'restore GET $status after brief background cannot change the current session',
      (tester) async {
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        final gate = Completer<http.Response>();
        var detailReads = 0;
        var expired = 0;
        final manager = _manager((request) async {
          if (request.url.path.endsWith('/restores/$_restoreId')) {
            detailReads++;
            return gate.future;
          }
          return _lists(request, history: true);
        });
        await tester.pumpWidget(
          _view(manager, onUnauthorized: (_) async => expired++),
        );
        await pumpUntilFound(tester, find.text('文件 · 0'));
        await tester.tap(find.text('恢复'));
        await pumpUntilFound(tester, find.byTooltip('查询此恢复请求'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byTooltip('查询此恢复请求'));
        await tester.tap(find.byTooltip('查询此恢复请求'));
        await pumpUntil(tester, () => detailReads == 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        gate.complete(
          status == 200
              ? _json({
                  'ok': true,
                  'restore': _restore(child: _childId, followup: 'running'),
                })
              : _json({'ok': false}, 401),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        expect(expired, 0);
        expect(detailReads, 1);
        expect(find.text('目录已恢复'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('all operation identities fit a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final recovery = _restoreRecovery();
    recovery.admitAction(
      kind: 'scheduler',
      rootId: _restoreId,
      operationId: _childId,
    );
    final manager = _manager(
      (request) async => _lists(request),
      recovery: recovery,
    );
    await tester.pumpWidget(_view(manager, scale: 2));
    await pumpUntilFound(tester, find.text('文件 · 0'));
    await _openRecords(tester);
    expect(find.text('重新加载调度器'), findsOneWidget);
    expect(find.text('恢复目录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final preflight in [true, false]) {
    testWidgets(
      '${preflight ? 'preflight' : 'restore'} remains queryable after 401 and reauthentication',
      (tester) async {
        final recovery = preflight
            ? (PanelBackupRecovery(_panel)
                ..admitPreflight(_preflightId, 'full.zip'))
            : _restoreRecovery();
        var expired = 0;
        var authorized = false;
        var posts = 0;
        Future<http.Response> handler(http.Request request) async {
          if (request.method == 'POST') posts++;
          if (request.url.path.contains('/preflights/') ||
              request.url.path.endsWith('/restores/$_restoreId')) {
            if (!authorized) return _json({'ok': false}, 401);
            return preflight
                ? _json({'ok': true, 'preflight': _preflight()})
                : _json({'ok': true, 'restore': _restore()});
          }
          return _lists(request);
        }

        await tester.pumpWidget(
          _view(
            _manager(handler, recovery: recovery),
            onUnauthorized: (_) async => expired++,
          ),
        );
        await pumpUntilFound(tester, find.text('文件 · 0'));
        await _openRecords(tester);
        await _queryRecord(tester);
        await pumpUntil(tester, () => expired == 1);
        await tester.pumpAndSettle();
        expect(recovery.operations.single.status, isNull);
        authorized = true;
        await tester.pumpWidget(_view(_manager(handler, recovery: recovery)));
        await pumpUntilFound(tester, find.text('文件 · 0'));
        await _openRecords(tester);
        await _queryRecord(tester);
        await pumpUntilFound(tester, find.byTooltip('查看原请求详情'));
        expect(recovery.operations.single.canReview, isTrue);
        expect(posts, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
