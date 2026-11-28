import 'dart:convert';
import 'dart:io';

import 'package:fls_for_android/models/panel_backup.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_backup_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'panel_test_http.dart';

void main() {
  test('parses bounded native backup DTOs', () {
    final files = PanelBackupFilesPage.fromJson({
      'ok': true,
      'items': [
        {
          'name': 'config.tar.gz',
          'version': 'a' * 64,
          'size_bytes': 42,
          'modified_at': '2026-11-26 10:00:00',
        },
      ],
      'page': 1,
      'pages': 1,
      'total': 1,
    });
    expect(files.items.single.name, 'config.tar.gz');
    expect(files.items.single.sizeBytes, 42);
    expect(
      () => PanelBackupFile.fromJson({
        'name': '../outside.tar.gz',
        'version': 'a' * 64,
      }),
      throwsFormatException,
    );
    final preflight = PanelBackupPreflight.fromJson({
      'ok': true,
      'preflight': _preflight(),
    });
    expect(preflight.status, 'ready');
    expect(preflight.warnings, ['data_restore_may_change_panel_access']);
    expect(
      () => PanelBackupPreflight.fromJson({
        'ok': true,
        'preflight': {
          ..._preflight(),
          'items': ['data', 'data'],
        },
      }),
      throwsFormatException,
    );
    final restore = PanelBackupRestore.fromJson({
      'ok': true,
      'restore': _restore(),
    });
    expect(restore.state, 'restored');
    expect(restore.scheduler.state, 'pending');
    expect(
      () => PanelBackupRestore.fromJson({
        'ok': true,
        'restore': {..._restore(), 'archive_sha256': 'bad'},
      }),
      throwsFormatException,
    );
  });

  test('uses native endpoints, exact file version, and session CSRF', () async {
    final requests = <http.Request>[];
    final client = PanelApiClient(
      baseUrl: 'https://fls.example/panel',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=panel-session',
        csrfToken: 'csrf-native',
      ),
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/capabilities')) {
          return utf8Response(
            '{"ok":true,"items":["data","scripts"],"formats":["tar.gz"],"upload_limit_bytes":10,"extracted_limit_bytes":20,"entry_limit":30}',
            200,
          );
        }
        if (request.url.path.endsWith('/files')) {
          return utf8Response(
            '{"ok":true,"items":[],"page":1,"pages":1,"limit":25,"total":0}',
            200,
          );
        }
        return utf8Response('{"ok":true,"accepted":true}', 200);
      }),
    );
    addTearDown(client.close);
    final service = PanelBackupManager(client);
    final capabilities = await service.fetchCapabilities();
    final files = await service.fetchFiles();
    await service.create(requestId: 'c' * 32, items: const ['scripts']);

    expect(capabilities.uploadLimitBytes, 10);
    expect(files.total, 0);
    expect(requests[0].url.path, '/panel/api/backup/native/capabilities');
    expect(requests[1].url.queryParameters, {'page': '1', 'limit': '25'});
    expect(requests.last.headers['cookie'], 'fls_native_session=panel-session');
    expect(requests.last.headers['x-csrf-token'], 'csrf-native');
    expect(jsonDecode(requests.last.body), {
      'request_id': 'c' * 32,
      'items': ['scripts'],
    });
  });

  test(
    'rejects malformed or contradictory restore results without coercion',
    () {
      final invalid = <Map<String, dynamic>>[
        {'directory_recovery_required': 'true'},
        {'directory_recovery_required': null},
        {
          'state': 'committing',
          'phase': 'committing',
          'committed': false,
          'active': true,
          'directory_recovery_required': true,
        },
        {'active': 'false'},
        {'committed': 1},
        {'archive_size_bytes': '13'},
        {'archive_size_bytes': -1},
        {'created_at': 1.5},
        {'updated_at': 0},
        {
          'restore_items': ['data', 1],
        },
        {
          'restore_items': ['data', 'data'],
        },
        {
          'state': 'unknown',
          'committed': true,
          'restore_outcome_unknown': true,
        },
        {'state': 'restored', 'active': true},
        {'state': 'restored', 'live_state_unchanged': true},
        {'error': 'x' * 1001},
        {
          'scheduler': {
            'state': 'succeeded',
            'required': true,
            'operation_id': '',
            'error': '',
          },
        },
        {
          'dependencies': {
            'state': 'not_requested',
            'operation_id': '',
            'error': '',
            'output': '中' * 12000,
          },
        },
      ];
      for (final changes in invalid) {
        expect(
          () => PanelBackupRestore.fromJson({
            'ok': true,
            'restore': {..._restore(), ...changes},
          }),
          throwsFormatException,
          reason: changes.keys.join(','),
        );
      }
      expect(
        () => PanelBackupRestoresPage.fromJson({
          'ok': true,
          'items': [_restore()],
          'total': 2,
          'limit': 25,
          'offset': 0,
          'has_more': false,
        }),
        throwsFormatException,
      );
    },
  );

  test('accepts unresolved and explicitly unapplied restore outcomes', () {
    final unknown = PanelBackupRestore.fromJson({
      'ok': true,
      'restore': {
        ..._restore(),
        'state': 'unknown',
        'phase': 'committing',
        'committed': false,
        'restore_outcome_unknown': true,
      },
    });
    expect(unknown.committed, isFalse);
    final unapplied = PanelBackupRestore.fromJson({
      'ok': true,
      'restore': {
        ..._restore(),
        'state': 'failed',
        'phase': 'failed',
        'committed': false,
        'live_state_unchanged': true,
        'scheduler': {
          'state': 'not_required',
          'required': true,
          'operation_id': '',
          'error': '',
        },
      },
    });
    expect(unapplied.liveStateUnchanged, isTrue);
  });

  test('rejects a restore response bound to another request', () async {
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=session',
        csrfToken: 'csrf',
      ),
      client: MockClient(
        (_) async => utf8Response(
          jsonEncode({
            'ok': true,
            'restore': {..._restore(), 'request_id': 'e' * 32},
          }),
          200,
        ),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      PanelBackupManager(api).fetchRestore('f' * 32),
      throwsA(isA<PanelApiException>()),
    );
  });

  test(
    'uploads a bounded preflight and queries the original request read-only',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'fls-backup-preflight-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final source = File('${temp.path}/full.zip');
      await source.writeAsBytes(utf8.encode('archive bytes'));
      final calls = <String>[];
      final progress = <(int, int)>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/prefix',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=backup-session',
          csrfToken: 'backup-csrf',
        ),
        client: panelMockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          expect(
            request.headers['cookie'],
            'fls_native_session=backup-session',
          );
          if (request.method == 'POST' &&
              request.url.path.endsWith('/cancel')) {
            return utf8Response(
              jsonEncode({
                'ok': true,
                'accepted': true,
                'preflight': {
                  ..._preflight(),
                  'status': 'checking',
                  'active': true,
                  'cancel_allowed': true,
                  'archive_sha256': '',
                },
              }),
              202,
            );
          }
          if (request.method == 'POST') {
            expect(request.url.path, '/prefix/api/backup/native/preflights');
            expect(request.headers['x-csrf-token'], 'backup-csrf');
            final body = utf8.decode(request.bodyBytes);
            expect(body, contains('name="preflight_id"'));
            expect(body, contains('a' * 32));
            expect(body, contains('filename="full.zip"'));
            expect(body, contains('archive bytes'));
            return utf8Response(
              jsonEncode({'ok': true, 'preflight': _preflight()}),
              200,
            );
          }
          expect(
            request.url.path,
            '/prefix/api/backup/native/preflights/${'a' * 32}',
          );
          return utf8Response(
            jsonEncode({'ok': true, 'preflight': _preflight()}),
            200,
          );
        }),
      );
      addTearDown(api.close);

      final manager = PanelBackupManager(api);
      final uploaded = await manager.createPreflight(
        filePath: source.path,
        filename: 'full.zip',
        requestId: 'a' * 32,
        maxBytes: 100,
        onProgress: (sent, total) => progress.add((sent, total)),
      );
      final recovered = await manager.fetchPreflight('a' * 32);
      final cancellation = await manager.cancelPreflight('a' * 32);

      expect(uploaded.items, ['data', 'scripts']);
      expect(uploaded.archiveSha256, 'b' * 64);
      expect(recovered.status, 'ready');
      expect(cancellation.cancelAllowed, isTrue);
      expect(progress, isNotEmpty);
      expect(progress.last.$1, progress.last.$2);
      expect(calls, [
        'POST /prefix/api/backup/native/preflights',
        'GET /prefix/api/backup/native/preflights/${'a' * 32}',
        'POST /prefix/api/backup/native/preflights/${'a' * 32}/cancel',
      ]);
    },
  );

  test(
    'submits an idempotent restore and independent follow-up operations',
    () async {
      final requests = <http.Request>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=backup-session',
          csrfToken: 'backup-csrf',
        ),
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET' &&
              request.url.path.endsWith('/restores')) {
            return utf8Response(
              jsonEncode({
                'ok': true,
                'items': [_restore()],
                'total': 1,
                'limit': 10,
                'offset': 0,
                'has_more': false,
              }),
              200,
            );
          }
          if (request.method == 'GET') {
            return utf8Response(
              jsonEncode({'ok': true, 'restore': _restore()}),
              200,
            );
          }
          return utf8Response(
            jsonEncode({'ok': true, 'restore': _restore()}),
            202,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelBackupManager(api);
      final preflight = PanelBackupPreflight.fromJson({
        'ok': true,
        'preflight': _preflight(),
      });

      final restored = await manager.createRestore(
        requestId: 'f' * 32,
        preflight: preflight,
        items: const ['data'],
        restoreDependencies: false,
        confirmDataImpact: true,
      );
      final status = await manager.fetchRestore('f' * 32);
      final history = await manager.fetchRestores(limit: 10);
      await manager.reloadScheduler(requestId: 'f' * 32, operationId: 'e' * 32);

      expect(restored.state, 'restored');
      expect(status.requestId, 'f' * 32);
      expect(history.items.single.requestId, 'f' * 32);
      expect(requests.map((request) => request.method), [
        'POST',
        'GET',
        'GET',
        'POST',
      ]);
      expect(requests.first.url.path, '/api/backup/native/restores');
      expect(jsonDecode(requests.first.body), {
        'request_id': 'f' * 32,
        'preflight_id': 'a' * 32,
        'archive_sha256': 'b' * 64,
        'restore_items': ['data'],
        'restore_dependencies': false,
        'confirm_data_impact': true,
      });
      expect(requests.first.headers['x-csrf-token'], 'backup-csrf');
      expect(
        requests.last.url.path,
        '/api/backup/native/restores/${'f' * 32}/scheduler-reload',
      );
    },
  );

  test(
    'cleans the original dependency operation without starting a new attempt',
    () async {
      final requests = <http.Request>[];
      var wrongOperation = false;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/prefix',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=backup-session',
          csrfToken: 'backup-csrf',
        ),
        client: MockClient((request) async {
          requests.add(request);
          return utf8Response(
            jsonEncode({
              'ok': true,
              'restore': {
                ..._restore(),
                'restore_dependencies': true,
                'dependencies': {
                  'state': 'unknown',
                  'operation_id': (wrongOperation ? 'd' : 'e') * 32,
                  'error': 'The original installation outcome is unknown',
                  'output': '',
                  'cleanup_required': false,
                },
              },
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelBackupManager(api);
      final result = await manager.cleanupRestoreDependencies(
        requestId: 'f' * 32,
        operationId: 'e' * 32,
      );
      expect(result.dependencies.state, 'unknown');
      expect(result.dependencies.cleanupRequired, isFalse);
      expect(requests.single.method, 'POST');
      expect(
        requests.single.url.path,
        '/prefix/api/backup/native/restores/${'f' * 32}/dependencies/cleanup',
      );
      expect(jsonDecode(requests.single.body), {'operation_id': 'e' * 32});
      expect(requests.single.headers['x-csrf-token'], 'backup-csrf');
      wrongOperation = true;
      await expectLater(
        manager.cleanupRestoreDependencies(
          requestId: 'f' * 32,
          operationId: 'e' * 32,
        ),
        throwsA(isA<PanelApiException>()),
      );
      for (final cleanup in <Object>[true, 'true']) {
        expect(
          () => PanelBackupFollowup.fromJson({
            'state': 'succeeded',
            'operation_id': 'e' * 32,
            'error': '',
            'cleanup_required': cleanup,
          }),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'validates accepted cleanup metadata and original query operation',
    () async {
      var metadata = <String, dynamic>{'cleanup_requested': true};
      var operation = 'e' * 32;
      var cleanup = true;
      final requests = <http.Request>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/prefix',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=backup-session',
          csrfToken: 'backup-csrf',
        ),
        client: MockClient((request) async {
          requests.add(request);
          return utf8Response(
            jsonEncode({
              'ok': true,
              ...metadata,
              'restore': {
                ..._restore(),
                'restore_dependencies': true,
                'dependencies': {
                  'state': 'unknown',
                  'operation_id': operation,
                  'error': '',
                  'output': '',
                  'cleanup_required': cleanup,
                },
              },
            }),
            request.method == 'POST' ? 202 : 200,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelBackupManager(api);
      final accepted = await manager.cleanupRestoreDependencies(
        requestId: 'f' * 32,
        operationId: 'e' * 32,
      );
      expect(accepted.dependencyCleanupRequested, isTrue);
      expect(accepted.dependencies.cleanupRequired, isTrue);
      final queried = await manager.fetchRestore(
        'f' * 32,
        expectedDependencyOperationId: 'e' * 32,
      );
      expect(queried.dependencies.operationId, 'e' * 32);
      operation = 'd' * 32;
      await expectLater(
        manager.fetchRestore('f' * 32, expectedDependencyOperationId: 'e' * 32),
        throwsA(isA<PanelApiException>()),
      );
      operation = 'e' * 32;
      for (final invalid in <Object?>[null, 'true', 1]) {
        metadata = {'cleanup_requested': invalid};
        await expectLater(
          manager.cleanupRestoreDependencies(
            requestId: 'f' * 32,
            operationId: 'e' * 32,
          ),
          throwsA(isA<PanelApiException>()),
        );
      }
      metadata = {};
      final synchronous = await manager.cleanupRestoreDependencies(
        requestId: 'f' * 32,
        operationId: 'e' * 32,
      );
      expect(synchronous.dependencyCleanupRequested, isFalse);
      metadata = {'cleanup_requested': true};
      cleanup = false;
      final alreadyFinished = await manager.cleanupRestoreDependencies(
        requestId: 'f' * 32,
        operationId: 'e' * 32,
      );
      expect(alreadyFinished.dependencies.cleanupRequired, isFalse);
      final beforeInvalidId = requests.length;
      await expectLater(
        manager.fetchRestore(
          'f' * 32,
          expectedDependencyOperationId: 'invalid',
        ),
        throwsArgumentError,
      );
      expect(requests, hasLength(beforeInvalidId));
    },
  );

  test(
    'recovers directories using the original request and rejects another identity',
    () async {
      final requests = <http.Request>[];
      var wrongRequest = false;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/prefix',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=backup-session',
          csrfToken: 'backup-csrf',
        ),
        client: MockClient((request) async {
          requests.add(request);
          return utf8Response(
            jsonEncode({
              'ok': true,
              'restore': {
                ..._restore(),
                'request_id': (wrongRequest ? 'e' : 'f') * 32,
                'directory_recovery_required': false,
              },
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelBackupManager(api);
      final legacy = PanelBackupRestore.fromJson({
        'ok': true,
        'restore': _restore(),
      });
      expect(legacy.directoryRecoveryRequired, isFalse);
      final result = await manager.recoverRestoreDirectories('f' * 32);
      expect(result.directoryRecoveryRequired, isFalse);
      expect(requests.single.method, 'POST');
      expect(
        requests.single.url.path,
        '/prefix/api/backup/native/restores/${'f' * 32}/recover-directories',
      );
      expect(jsonDecode(requests.single.body), {'confirm': true});
      expect(requests.single.headers['x-csrf-token'], 'backup-csrf');
      wrongRequest = true;
      await expectLater(
        manager.recoverRestoreDirectories('f' * 32),
        throwsA(isA<PanelApiException>()),
      );
    },
  );

  test(
    'reads restore archive maintenance and acknowledges the original event',
    () async {
      final requests = <http.Request>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=backup-session',
          csrfToken: 'backup-csrf',
        ),
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return utf8Response(
              jsonEncode({
                'ok': true,
                'maintenance': {
                  'event_id': 'a' * 32,
                  'required': false,
                  'kind': 'publication',
                  'acknowledged': false,
                  'notice': '恢复归档索引发布已确认',
                },
              }),
              200,
            );
          }
          return utf8Response(
            jsonEncode({'ok': true, 'maintenance': null}),
            200,
          );
        }),
      );
      addTearDown(api.close);

      final manager = PanelBackupManager(api);
      final state = await manager.fetchRestoreMaintenance();
      final acknowledged = await manager.acknowledgeRestoreMaintenance(
        state.eventId,
      );

      expect(state.eventId, 'a' * 32);
      expect(state.required, isFalse);
      expect(state.kind, 'publication');
      expect(acknowledged.acknowledged, isTrue);
      expect(requests.map((request) => request.method), ['GET', 'POST']);
      expect(
        requests.last.url.path,
        '/api/backup/native/restore-maintenance/${'a' * 32}/ack',
      );
    },
  );
}

Map<String, dynamic> _preflight() => {
  'preflight_id': 'a' * 32,
  'request_id': 'a' * 32,
  'status': 'ready',
  'active': false,
  'cancel_allowed': false,
  'filename': 'full.zip',
  'format': 'zip',
  'archive_size_bytes': 13,
  'archive_sha256': 'b' * 64,
  'items': ['data', 'scripts'],
  'entry_count': 3,
  'expanded_bytes': 30,
  'dependency_files': ['requirements.txt'],
  'warnings': ['data_restore_may_change_panel_access'],
  'error_code': '',
  'created_at': 1795695731,
  'expires_at': 1795699331,
};

Map<String, dynamic> _restore() => {
  'request_id': 'f' * 32,
  'preflight_id': 'a' * 32,
  'filename': 'full.zip',
  'archive_sha256': 'b' * 64,
  'archive_size_bytes': 13,
  'restore_items': ['data'],
  'restore_dependencies': false,
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
    'state': 'not_requested',
    'operation_id': '',
    'error': '',
    'output': '',
  },
};
