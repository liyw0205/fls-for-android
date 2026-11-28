import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fls_for_android/models/panel_backup.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_backup_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _backendRevision = '24a85ee06046e1424f4b5ce0324699951cdda550';
const _legacyRevision = 'ec318d8659fad6c9fd75b97e18fe6978c735e8a1';
const _token = 'bulk-workflow-token';

String _id(int number) => number.toRadixString(16).padLeft(32, '0');

class _DropAcceptedResponse extends http.BaseClient {
  final _inner = http.Client();
  String? dropPath;
  final dropped = <String>[];
  final _busyReads = <String>{};

  bool isBusyRead(PanelApiException error) =>
      error.statusCode == 503 && _busyReads.contains(error.path);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('x-token')),
    );
    _busyReads.remove(request.url.path);
    final response = await _inner.send(request);
    if (request.method == 'GET' && response.statusCode == 503) {
      final bytes = await response.stream.toBytes();
      final payload = jsonDecode(utf8.decode(bytes));
      if (payload is Map && payload['code'] == 'panel_storage_busy') {
        expect(response.headers['retry-after'], '1');
        expect(response.headers['cache-control'], 'no-store');
        _busyReads.add(request.url.path);
      }
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        headers: response.headers,
        contentLength: bytes.length,
        request: request,
      );
    }
    if (request.method == 'POST' && request.url.path == dropPath) {
      expect(response.statusCode, inInclusiveRange(200, 299));
      dropPath = null;
      dropped.add(request.url.path);
      await response.stream.drain<void>();
      throw http.ClientException(
        'Dropped accepted fixture response',
        request.url,
      );
    }
    return response;
  }

  @override
  void close() => _inner.close();
}

Future<T> _wait<T>(
  Future<T> Function() read,
  bool Function(T) finished, {
  required bool Function(PanelApiException) retryRead,
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 20)) {
    try {
      final value = await read();
      if (finished(value)) return value;
    } on PanelApiException catch (error) {
      if (!retryRead(error)) rethrow;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Isolated backend operation did not settle');
}

void main() {
  final backend = Platform.environment['FLS_PAIR_ROOT'];
  for (final scenario in ['main', 'faults', 'retention', 'dependencies']) {
    _registerPair(backend, scenario: scenario);
  }
  _registerPair(
    Platform.environment['FLS_PAIR_LEGACY_ROOT'],
    scenario: 'legacy',
    revision: _legacyRevision,
  );
}

void _registerPair(
  String? backend, {
  required String scenario,
  String revision = _backendRevision,
}) {
  const names = {
    'main':
        'pinned FLS native session transfers and recovers real backup operations',
    'faults':
        'pinned FLS preflight cancellation and faults clean real staged files',
    'retention':
        'pinned FLS expires snapshots only on writes and retains terminal receipts',
    'dependencies':
        'pinned FLS supervised dependency failure retains snapshots and cleans original resources',
    'legacy':
        'pinned old FLS supports native preflight without newer maintenance requests',
  };
  test(
    names[scenario]!,
    () async {
      final process = await Process.start('python3', [
        'tool/panel_backup_fixture.py',
        '--backend',
        backend!,
        '--revision',
        revision,
      ]);
      final ready = Completer<Map<String, dynamic>>();
      final diagnostics = <String>[];
      void record(String line) {
        diagnostics.add(line);
        if (diagnostics.length > 12) diagnostics.removeAt(0);
      }

      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('{"pair_ready":')) {
              if (!ready.isCompleted) {
                ready.complete(jsonDecode(line) as Map<String, dynamic>);
              }
            } else {
              record(line);
            }
          });
      final errors = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(record);
      unawaited(
        process.exitCode.then((code) {
          if (!ready.isCompleted) {
            ready.completeError(
              StateError('Fixture exited $code: ${diagnostics.join('\n')}'),
            );
          }
        }),
      );
      Map<String, dynamic>? fixture;
      addTearDown(() async {
        try {
          process.stdin.writeln('stop');
          await process.stdin.close();
          final code = await process.exitCode.timeout(
            const Duration(seconds: 20),
            onTimeout: () async {
              process.kill();
              return process.exitCode.timeout(const Duration(seconds: 5));
            },
          );
          expect(code, 0, reason: diagnostics.join('\n'));
          if (fixture != null) {
            expect(
              Directory(fixture['base_dir'] as String).existsSync(),
              isFalse,
            );
          }
        } finally {
          await output.cancel();
          await errors.cancel();
        }
      });
      fixture = await ready.future.timeout(const Duration(seconds: 20));
      expect(fixture['revision'], revision);
      final baseUrl = fixture['base_url'] as String;
      final transport = _DropAcceptedResponse();
      addTearDown(transport.close);
      PanelApiClient client([PanelSessionCredentials? credentials]) {
        final api = PanelApiClient(
          baseUrl: baseUrl,
          credentials: credentials,
          allowInsecureHttp: true,
          client: transport,
          requestTimeout: const Duration(seconds: 5),
        );
        addTearDown(api.close);
        return api;
      }

      Future<Map<String, dynamic>> evidence() async {
        final response = await transport
            .get(Uri.parse(fixture!['evidence_url'] as String))
            .timeout(const Duration(seconds: 5));
        expect(response.statusCode, 200);
        return jsonDecode(response.body) as Map<String, dynamic>;
      }

      final initial = await evidence();
      expect(initial['scheduled_jobs'], isEmpty);
      expect(initial['scheduler_running'], isTrue);
      expect(initial['scheduler_paused'], isTrue);

      var api = client();
      await expectLater(
        api.getJson('/api/backup/native/capabilities'),
        throwsA(
          isA<PanelApiException>().having(
            (error) => error.statusCode,
            'status',
            401,
          ),
        ),
      );
      final auth = await api.authenticate(_token, remember: false);
      expect(auth.authenticated, isTrue);
      expect(api.hasSession, isTrue);
      final invalidCsrf = client(
        PanelSessionCredentials(
          cookie: api.sessionCredentials.cookie,
          csrfToken: 'invalid',
        ),
      );
      await expectLater(
        invalidCsrf.postJson('/api/backup/native/jobs', {
          'request_id': _id(99),
          'items': ['data'],
        }),
        throwsA(
          isA<PanelApiException>().having(
            (error) => error.statusCode,
            'status',
            400,
          ),
        ),
      );
      var manager = PanelBackupManager(api);
      final capabilities = await manager.fetchCapabilities();
      expect(capabilities.restoreEnabled, scenario != 'legacy');
      expect(capabilities.preflightEnabled, isTrue);
      final recovery = manager.recovery;
      if (scenario == 'legacy') {
        await _exerciseLegacy(
          fixture: fixture,
          manager: manager,
          capabilities: capabilities,
          transport: transport,
          evidence: evidence,
        );
        return;
      }
      if (scenario == 'retention') {
        await _exerciseRetention(
          fixture: fixture,
          manager: manager,
          transport: transport,
          uploadLimitBytes: capabilities.uploadLimitBytes,
          evidence: evidence,
        );
        return;
      }
      if (scenario == 'dependencies') {
        await _exerciseDependencies(
          fixture: fixture,
          manager: manager,
          reconnect: () => PanelBackupManager(
            client(api.sessionCredentials),
            recovery: recovery,
          ),
          transport: transport,
          uploadLimitBytes: capabilities.uploadLimitBytes,
          evidence: evidence,
        );
        return;
      }
      if (scenario == 'faults') {
        await _exercisePreflightFaults(
          fixture: fixture,
          manager: manager,
          reconnect: () => PanelBackupManager(
            client(api.sessionCredentials),
            recovery: recovery,
          ),
          transport: transport,
          uploadLimitBytes: capabilities.uploadLimitBytes,
          evidence: evidence,
        );
        return;
      }
      final rootIds = <String>[];
      var index = 0;
      for (final path in (fixture['archives'] as List).cast<String>()) {
        index++;
        final archive = File(path);
        final filename = path.split(Platform.pathSeparator).last;
        final preflightId = _id(index);
        final restoreId = _id(index + 10);
        final childId = _id(index + 20);
        rootIds.add(restoreId);
        var uploaded = 0;
        var uploadTotal = 0;
        transport.dropPath = '/fls-pair/api/backup/native/preflights';
        await expectLater(
          manager.createPreflight(
            filePath: path,
            filename: filename,
            requestId: preflightId,
            maxBytes: capabilities.uploadLimitBytes,
            onProgress: (sent, total) {
              expect(sent, greaterThanOrEqualTo(uploaded));
              uploaded = sent;
              uploadTotal = total;
            },
          ),
          throwsA(isA<PanelApiException>()),
        );
        expect(uploaded, uploadTotal);
        expect(uploaded, greaterThan(await archive.length()));
        expect(recovery.find(preflightId, kind: 'preflight')!.status, isNull);
        api = client(api.sessionCredentials);
        manager = PanelBackupManager(api, recovery: recovery);
        final preflight = await _wait(
          () => manager.fetchPreflight(preflightId),
          (PanelBackupPreflight value) => !value.active,
          retryRead: transport.isBusyRead,
        );
        expect(preflight.status, 'ready');
        expect(
          preflight.archiveSha256,
          sha256.convert(await archive.readAsBytes()).toString(),
        );
        expect(preflight.archiveSizeBytes, await archive.length());
        expect(preflight.items, ['data', 'scripts']);
        expect(preflight.format, filename.endsWith('.zip') ? 'zip' : 'tar.gz');
        await expectLater(
          manager.createPreflight(
            filePath: path,
            filename: filename,
            requestId: preflightId,
            maxBytes: capabilities.uploadLimitBytes,
            onProgress: (_, _) {},
          ),
          throwsStateError,
        );

        transport.dropPath = '/fls-pair/api/backup/native/restores';
        await expectLater(
          manager.createRestore(
            requestId: restoreId,
            preflight: preflight,
            items: preflight.items,
            restoreDependencies: false,
            confirmDataImpact: true,
          ),
          throwsA(isA<PanelApiException>()),
        );
        manager = PanelBackupManager(
          client(api.sessionCredentials),
          recovery: recovery,
        );
        final restored = await _wait(
          () => manager.fetchRestore(restoreId),
          (PanelBackupRestore value) => !value.active,
          retryRead: transport.isBusyRead,
        );
        expect(restored.state, 'restored');
        expect(restored.committed, isTrue);
        expect(restored.scheduler.state, 'pending');
        final restoredEvidence = await evidence();
        expect(restoredEvidence['data_restored'], isTrue);
        expect(restoredEvidence['scripts_restored'], isTrue);
        expect(
          restoredEvidence['scheduled_jobs'],
          index == 1 ? <String>[] : ['log_cleanup'],
        );
        expect(restoredEvidence['scheduler_running'], isTrue);
        expect(restoredEvidence['scheduler_paused'], isTrue);
        transport.dropPath =
            '/fls-pair/api/backup/native/restores/$restoreId/scheduler-reload';
        await expectLater(
          manager.reloadScheduler(
            requestId: restoreId,
            operationId: childId,
            expectedRestore: restored,
          ),
          throwsA(isA<PanelApiException>()),
        );
        final followup = await manager.fetchRestore(
          restoreId,
          expectedSchedulerOperationId: childId,
        );
        expect(followup.scheduler.state, 'succeeded');
        expect(followup.scheduler.operationId, childId);
        final scheduled = await evidence();
        expect(scheduled['scheduled_jobs'], ['log_cleanup']);
        expect(scheduled['scheduler_running'], isTrue);
        expect(scheduled['scheduler_paused'], isTrue);
        expect(recovery.find(childId, kind: 'scheduler')!.canReview, isTrue);
        final before = await evidence();
        await manager.queryOperation(
          recovery.find(restoreId, kind: 'restore')!,
        );
        final history = await manager.fetchRestores();
        expect(
          history.items.map((value) => value.requestId),
          contains(restoreId),
        );
        final after = await evidence();
        expect(after['records'], before['records']);
      }

      final createId = _id(31);
      await manager.create(requestId: createId, items: ['data', 'scripts']);
      final created = await _wait(
        () => manager.fetchJob(createId),
        (PanelBackupJob job) => !job.active,
        retryRead: transport.isBusyRead,
      );
      expect(created.status, 'succeeded');
      final file = (await manager.fetchFiles()).items.single;
      final destination = '${fixture['base_dir']}/download.tar.gz';
      var downloaded = 0;
      final size = await manager.downloadFile(
        file: file,
        destinationPath: destination,
        onProgress: (received, total) {
          expect(received, greaterThanOrEqualTo(downloaded));
          downloaded = received;
          if (total != null) expect(received, lessThanOrEqualTo(total));
        },
      );
      expect(size, file.sizeBytes);
      expect(downloaded, size);
      expect(
        sha256.convert(await File(destination).readAsBytes()).toString(),
        ((await evidence())['backups'] as Map)[file.name],
      );
      await manager.deleteFile(requestId: _id(32), file: file);
      expect((await manager.fetchFiles()).items, isEmpty);

      await api.logout();
      await expectLater(
        manager.fetchCapabilities(),
        throwsA(
          isA<PanelApiException>().having(
            (error) => error.statusCode,
            'status',
            401,
          ),
        ),
      );
      await api.authenticate(_token, remember: false);
      manager = PanelBackupManager(api, recovery: recovery);
      for (final id in rootIds) {
        await manager.queryOperation(recovery.find(id, kind: 'restore')!);
      }
      final observations = (await evidence())['requests'] as List;
      int successfulPosts(String path) => observations
          .where(
            (value) =>
                value['method'] == 'POST' &&
                value['path'] == path &&
                value['status'] >= 200 &&
                value['status'] < 300,
          )
          .length;
      expect(successfulPosts('/api/backup/native/preflights'), 2);
      expect(successfulPosts('/api/backup/native/restores'), 2);
      expect(successfulPosts('/api/backup/native/jobs'), 1);
      expect(successfulPosts('/api/backup/native/files/delete'), 1);
      for (final id in rootIds) {
        expect(
          successfulPosts('/api/backup/native/restores/$id/scheduler-reload'),
          1,
        );
      }
      expect(transport.dropped, hasLength(6));
    },
    skip: backend == null
        ? 'Set the FLS_PAIR_ROOT or FLS_PAIR_LEGACY_ROOT pinned checkout'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _exercisePreflightFaults({
  required Map<String, dynamic> fixture,
  required PanelBackupManager manager,
  required PanelBackupManager Function() reconnect,
  required _DropAcceptedResponse transport,
  required int uploadLimitBytes,
  required Future<Map<String, dynamic>> Function() evidence,
}) async {
  final initial = await evidence();
  final requestStart = (initial['requests'] as List).length;
  final archives = (fixture['archives'] as List).cast<String>();
  final recovery = manager.recovery;

  Future<void> arm(String id, String mode) async {
    final response = await transport
        .post(
          Uri.parse(fixture['fault_url'] as String),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'request_id': id, 'mode': mode}),
        )
        .timeout(const Duration(seconds: 5));
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'ok': true});
  }

  Future<PanelBackupPreflight> upload(String path, String id) =>
      manager.createPreflight(
        filePath: path,
        filename: path.split(Platform.pathSeparator).last,
        requestId: id,
        maxBytes: uploadLimitBytes,
        onProgress: (_, _) {},
      );

  Future<void> expectClean(String id, String status, String error) async {
    final result = await _wait(
      () => manager.fetchPreflight(id),
      (PanelBackupPreflight value) => !value.active,
      retryRead: transport.isBusyRead,
    );
    expect(result.status, status);
    expect(result.errorCode, error);
    expect(result.cancelAllowed, isFalse);
    final operation = recovery.find(id, kind: 'preflight')!;
    expect(operation.status, status);
    expect(operation.canReview, isTrue);
    final before = await _wait(
      evidence,
      (Map<String, dynamic> value) =>
          (value['preflight_active'] as List).isEmpty,
      retryRead: transport.isBusyRead,
    );
    expect(before['preflight_cancel_events'], isEmpty);
    expect(before['staged_archives'], isEmpty);
    expect(before['preflight_workspaces'], isEmpty);
    expect(before['preflight_work_files'], isEmpty);
    expect(before['escaped_files'], isEmpty);
    expect(before['protected_files'], initial['protected_files']);
    expect(before['data_restored'], isFalse);
    expect(before['scripts_restored'], isFalse);
    expect(before['records'], contains('.backup_native_preflights/$id.json'));
    await manager.queryOperation(operation);
    final after = await evidence();
    expect(after['records'], before['records']);
    expect(after['staged_archives'], before['staged_archives']);
    expect(after['preflight_workspaces'], before['preflight_workspaces']);
  }

  final cancelId = _id(101);
  await arm(cancelId, 'cancel');
  final checking = await upload(archives.first, cancelId);
  expect(checking.status, 'checking');
  expect(checking.cancelAllowed, isTrue);
  final held = await _wait(
    evidence,
    (Map<String, dynamic> value) =>
        (value['preflight_faults'] as Map)[cancelId]['entered'] == true,
    retryRead: transport.isBusyRead,
  );
  expect(held['preflight_active'], [cancelId]);
  expect(held['preflight_cancel_events'], [cancelId]);
  expect(held['staged_archives'], {
    '$cancelId.archive': sha256
        .convert(await File(archives.first).readAsBytes())
        .toString(),
  });
  expect(held['preflight_workspaces'], hasLength(1));
  expect(
    (held['preflight_work_files'] as List).where(
      (value) => (value as String).endsWith('/extracted/fls/data/paired.txt'),
    ),
    hasLength(1),
  );
  expect(held['protected_files'], initial['protected_files']);
  transport.dropPath =
      '/fls-pair/api/backup/native/preflights/$cancelId/cancel';
  await expectLater(
    manager.cancelPreflight(cancelId),
    throwsA(isA<PanelApiException>()),
  );
  final cancelOperation = recovery.operations.singleWhere(
    (value) => value.kind == 'preflight-cancel' && value.rootId == cancelId,
  );
  expect(cancelOperation.status, isNull);
  manager = reconnect();
  await _wait(
    () => manager.queryOperation(cancelOperation),
    (Object value) => value is PanelBackupPreflight && !value.active,
    retryRead: transport.isBusyRead,
  );
  await expectClean(cancelId, 'cancelled', 'preflight_cancelled');
  expect(cancelOperation.status, 'cancelled');
  expect(cancelOperation.canReview, isTrue);

  final failedId = _id(102);
  await arm(failedId, 'storage');
  await upload(archives.last, failedId);
  await expectClean(failedId, 'failed', 'insufficient_storage');

  final unsafe = (fixture['unsafe_archives'] as List).cast<String>();
  for (var index = 0; index < unsafe.length; index++) {
    final id = _id(103 + index);
    await upload(unsafe[index], id);
    await expectClean(id, 'failed', 'unsafe_archive_entry');
  }

  // A fresh successful request proves that all failed workers released admission.
  final readyId = _id(105);
  await expectLater(upload(archives.last, readyId), throwsStateError);
  recovery.review(recovery.find(failedId, kind: 'preflight')!);
  await upload(archives.last, readyId);
  final ready = await _wait(
    () => manager.fetchPreflight(readyId),
    (PanelBackupPreflight value) => !value.active,
    retryRead: transport.isBusyRead,
  );
  expect(ready.status, 'ready');
  expect(ready.items, ['data', 'scripts']);
  expect(
    ready.archiveSha256,
    sha256.convert(await File(archives.last).readAsBytes()).toString(),
  );
  final finalEvidence = await evidence();
  expect(finalEvidence['preflight_active'], isEmpty);
  expect(finalEvidence['preflight_cancel_events'], isEmpty);
  expect(finalEvidence['preflight_workspaces'], isEmpty);
  expect(finalEvidence['preflight_work_files'], isEmpty);
  expect(finalEvidence['staged_archives'], {
    '$readyId.archive': ready.archiveSha256,
  });
  expect(finalEvidence['protected_files'], initial['protected_files']);
  expect(finalEvidence['escaped_files'], isEmpty);
  expect((finalEvidence['preflight_faults'] as Map)[cancelId], {
    'mode': 'cancel',
    'entered': true,
    'timed_out': false,
  });
  expect((finalEvidence['preflight_faults'] as Map)[failedId], {
    'mode': 'storage',
    'entered': true,
    'timed_out': false,
  });
  final posts = (finalEvidence['requests'] as List)
      .skip(requestStart)
      .where(
        (value) =>
            value['method'] == 'POST' &&
            (value['path'] as String).startsWith('/api/backup/native/'),
      )
      .toList();
  expect(posts, hasLength(6));
  expect(
    posts.where((value) => value['path'] == '/api/backup/native/preflights'),
    hasLength(5),
  );
  expect(
    posts.where(
      (value) =>
          value['path'] == '/api/backup/native/preflights/$cancelId/cancel',
    ),
    hasLength(1),
  );
  expect(
    posts.every((value) => value['status'] >= 200 && value['status'] < 300),
    isTrue,
  );
  expect(transport.dropped, [
    '/fls-pair/api/backup/native/preflights/$cancelId/cancel',
  ]);
}

Future<void> _agePreflight(
  http.Client transport,
  Map<String, dynamic> fixture,
  String id, {
  bool terminal = false,
}) async {
  final response = await transport
      .post(
        Uri.parse(fixture['age_url'] as String),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'request_id': id, 'terminal': terminal}),
      )
      .timeout(const Duration(seconds: 5));
  expect(response.statusCode, 200);
  expect(jsonDecode(response.body), {'ok': true});
}

Future<void> _exerciseRetention({
  required Map<String, dynamic> fixture,
  required PanelBackupManager manager,
  required _DropAcceptedResponse transport,
  required int uploadLimitBytes,
  required Future<Map<String, dynamic>> Function() evidence,
}) async {
  final initial = await evidence();
  final archives = (fixture['archives'] as List).cast<String>();
  Future<PanelBackupPreflight> upload(
    String id,
    String path,
    String name,
  ) async {
    await manager.createPreflight(
      filePath: path,
      filename: name,
      requestId: id,
      maxBytes: uploadLimitBytes,
      onProgress: (_, _) {},
    );
    return _wait(
      () => manager.fetchPreflight(id),
      (PanelBackupPreflight value) => !value.active,
      retryRead: transport.isBusyRead,
    );
  }

  final first = _id(201);
  expect(
    (await upload(first, archives.first, 'original.tar.gz')).status,
    'ready',
  );
  await _agePreflight(transport, fixture, first);
  final aged = await evidence();
  expect((await manager.fetchPreflight(first)).status, 'expired');
  final readOnly = await evidence();
  expect(readOnly['records'], aged['records']);
  expect(readOnly['staged_archives'], aged['staged_archives']);
  expect(readOnly['staged_archives'], contains('$first.archive'));

  final second = _id(202);
  expect((await upload(second, archives.last, 'second.zip')).status, 'ready');
  final expired = await evidence();
  expect(expired['staged_archives'], isNot(contains('$first.archive')));
  expect(expired['records'], contains('.backup_native_preflights/$first.json'));
  final expiredRecords = expired['records'] as Map;
  expect(
    expiredRecords['.backup_native_preflights/$first.json'],
    isNot((aged['records'] as Map)['.backup_native_preflights/$first.json']),
  );
  expect((await manager.fetchPreflight(first)).status, 'expired');
  expect((await evidence())['records'], expired['records']);

  await _agePreflight(transport, fixture, first, terminal: true);
  final retained = await evidence();
  expect((await manager.fetchPreflight(first)).status, 'expired');
  expect((await evidence())['records'], retained['records']);
  expect(
    (await upload(_id(203), archives.first, 'third.tar.gz')).status,
    'ready',
  );
  final cleaned = await evidence();
  expect(
    cleaned['records'],
    isNot(contains('.backup_native_preflights/$first.json')),
  );
  await expectLater(
    manager.fetchPreflight(first),
    throwsA(
      isA<PanelApiException>().having(
        (value) => value.statusCode,
        'status',
        404,
      ),
    ),
  );
  expect(manager.recovery.find(first, kind: 'preflight')!.status, 'expired');
  expect(cleaned['staged_archives'], hasLength(2));
  expect(cleaned['preflight_workspaces'], isEmpty);
  expect(cleaned['protected_files'], initial['protected_files']);
  expect((await evidence())['records'], cleaned['records']);
  final posts = (cleaned['requests'] as List)
      .skip((initial['requests'] as List).length)
      .where((value) => value['method'] == 'POST')
      .toList();
  expect(posts, hasLength(3));
  expect(
    posts.every(
      (value) =>
          value['path'] == '/api/backup/native/preflights' &&
          value['status'] == 202,
    ),
    isTrue,
  );
}

Future<void> _exerciseDependencies({
  required Map<String, dynamic> fixture,
  required PanelBackupManager manager,
  required PanelBackupManager Function() reconnect,
  required _DropAcceptedResponse transport,
  required int uploadLimitBytes,
  required Future<Map<String, dynamic>> Function() evidence,
}) async {
  final initial = await evidence();
  final preflightId = _id(301), rootId = _id(311), childId = _id(321);
  await manager.createPreflight(
    filePath: fixture['dependency_archive'] as String,
    filename: 'dependencies.zip',
    requestId: preflightId,
    maxBytes: uploadLimitBytes,
    onProgress: (_, _) {},
  );
  final preflight = await _wait(
    () => manager.fetchPreflight(preflightId),
    (PanelBackupPreflight value) => !value.active,
    retryRead: transport.isBusyRead,
  );
  expect(preflight.status, 'ready');
  expect(preflight.dependencyFiles, ['requirements.txt']);
  await manager.createRestore(
    requestId: rootId,
    preflight: preflight,
    items: ['scripts'],
    restoreDependencies: true,
    confirmDataImpact: false,
  );
  final restored = await _wait(
    () => manager.fetchRestore(rootId),
    (PanelBackupRestore value) => !value.active,
    retryRead: transport.isBusyRead,
  );
  expect(restored.state, 'restored');
  expect(restored.dependencies.state, 'pending');
  transport.dropPath =
      '/fls-pair/api/backup/native/restores/$rootId/dependencies';
  await expectLater(
    manager.installRestoreDependencies(
      requestId: rootId,
      operationId: childId,
      expectedRestore: restored,
    ),
    throwsA(isA<PanelApiException>()),
  );
  manager = reconnect();
  final pending = await _wait(
    () => manager.fetchRestore(rootId, expectedDependencyOperationId: childId),
    (PanelBackupRestore value) => value.dependencies.cleanupRequired,
    retryRead: transport.isBusyRead,
  );
  expect(pending.state, 'restored');
  expect(pending.dependencies.state, 'unknown');
  expect(
    manager.recovery.find(childId, kind: 'dependencies')!.canReview,
    isFalse,
  );
  final held = await evidence();
  expect(held['restore_lease_held'], isTrue);
  expect(held['dependency_evidence_states'], ['cleanup_pending']);
  expect((held['dependency_runs'] as List).single['cleanup_attempts'], 1);
  expect((held['dependency_runs'] as List).single['workspace_exists'], isTrue);
  expect(held['preflight_workspaces'], hasLength(1));
  await manager.queryOperation(
    manager.recovery.find(childId, kind: 'dependencies')!,
  );
  expect((await evidence())['records'], held['records']);
  expect((await evidence())['dependency_runs'], held['dependency_runs']);

  await _agePreflight(transport, fixture, preflightId);
  final archive = (fixture['archives'] as List).last as String;
  await manager.createPreflight(
    filePath: archive,
    filename: 'second.zip',
    requestId: _id(302),
    maxBytes: uploadLimitBytes,
    onProgress: (_, _) {},
  );
  await _wait(
    () => manager.fetchPreflight(_id(302)),
    (PanelBackupPreflight value) => !value.active,
    retryRead: transport.isBusyRead,
  );
  final retained = await evidence();
  expect(
    (retained['staged_archives'] as Map)['$preflightId.archive'],
    preflight.archiveSha256,
  );
  expect(
    retained['records'],
    contains('.backup_native_preflights/$preflightId.json'),
  );
  await expectLater(
    manager.createPreflight(
      filePath: archive,
      filename: 'capacity.zip',
      requestId: _id(303),
      maxBytes: uploadLimitBytes,
      onProgress: (_, _) {},
    ),
    throwsA(
      isA<PanelApiException>().having(
        (value) => value.statusCode,
        'status',
        429,
      ),
    ),
  );
  expect((await evidence())['staged_archives'], retained['staged_archives']);

  transport.dropPath =
      '/fls-pair/api/backup/native/restores/$rootId/dependencies/cleanup';
  await expectLater(
    manager.cleanupRestoreDependencies(
      requestId: rootId,
      operationId: childId,
      expectedRestore: pending,
    ),
    throwsA(isA<PanelApiException>()),
  );
  manager = reconnect();
  final cleanup = manager.recovery.find(childId, kind: 'dependency-cleanup')!;
  final result = await manager.queryOperation(cleanup) as PanelBackupRestore;
  expect(result.dependencies.operationId, childId);
  expect(result.dependencies.cleanupRequired, isFalse);
  expect(result.dependencies.state, 'failed');
  expect(result.state, 'restored');
  expect(cleanup.status, 'resources_cleaned');
  expect(cleanup.canReview, isTrue);
  expect(
    manager.recovery.find(childId, kind: 'dependencies')!.status,
    'failed',
  );
  final cleaned = await evidence();
  expect(cleaned['restore_lease_held'], isFalse);
  expect(cleaned['dependency_evidence_states'], ['cleaned']);
  expect(cleaned['preflight_workspaces'], isEmpty);
  expect(cleaned['dependency_runs'], [
    {
      'cleanup_attempts': 2,
      'process_stopped': true,
      'stdout_closed': true,
      'reader_alive': false,
      'workspace_exists': false,
    },
  ]);
  expect(cleaned['scripts_restored'], isTrue);
  expect(cleaned['data_restored'], isFalse);
  await manager.queryOperation(cleanup);
  expect((await evidence())['records'], cleaned['records']);
  expect((await evidence())['dependency_runs'], cleaned['dependency_runs']);
  final posts = (cleaned['requests'] as List)
      .skip((initial['requests'] as List).length)
      .where((value) => value['method'] == 'POST')
      .toList();
  expect(posts, hasLength(6));
  expect(
    posts.where((value) => value['path'] == '/api/backup/native/preflights'),
    hasLength(3),
  );
  expect(posts.where((value) => value['status'] == 429), hasLength(1));
  for (final path in [
    'restores',
    'restores/$rootId/dependencies',
    'restores/$rootId/dependencies/cleanup',
  ]) {
    final operationPosts = posts.where(
      (value) => value['path'] == '/api/backup/native/$path',
    );
    expect(operationPosts, hasLength(1));
    expect(operationPosts.single['status'], inInclusiveRange(200, 299));
  }
  expect(transport.dropped, [
    '/fls-pair/api/backup/native/restores/$rootId/dependencies',
    '/fls-pair/api/backup/native/restores/$rootId/dependencies/cleanup',
  ]);
}

Future<void> _exerciseLegacy({
  required Map<String, dynamic> fixture,
  required PanelBackupManager manager,
  required PanelBackupCapabilities capabilities,
  required _DropAcceptedResponse transport,
  required Future<Map<String, dynamic>> Function() evidence,
}) async {
  expect(capabilities.preflightEnabled, isTrue);
  expect(capabilities.restoreEnabled, isFalse);
  expect(capabilities.directoryMaintenanceEnabled, isFalse);
  expect(capabilities.dependencyMaintenanceEnabled, isFalse);
  final id = _id(401);
  final path = (fixture['archives'] as List).first as String;
  await manager.createPreflight(
    filePath: path,
    filename: 'legacy.tar.gz',
    requestId: id,
    maxBytes: capabilities.uploadLimitBytes,
    onProgress: (_, _) {},
  );
  final result = await _wait(
    () => manager.fetchPreflight(id),
    (PanelBackupPreflight value) => !value.active,
    retryRead: transport.isBusyRead,
  );
  expect(result.status, 'ready');
  expect(result.items, ['data', 'scripts']);
  expect(
    result.archiveSha256,
    sha256.convert(await File(path).readAsBytes()).toString(),
  );
  expect((await manager.fetchFiles()).items, isEmpty);
  expect((await manager.fetchJobs()).items, isEmpty);
  final before = await evidence();
  await manager.queryOperation(manager.recovery.find(id, kind: 'preflight')!);
  final after = await evidence();
  expect(after['records'], before['records']);
  expect(after['staged_archives'], before['staged_archives']);
  final observations = after['requests'] as List;
  const allowed = {
    '/api/auth/session',
    '/api/backup/native/capabilities',
    '/api/backup/native/jobs',
    '/api/backup/native/files',
    '/api/backup/native/preflights',
  };
  expect(
    observations.every(
      (value) =>
          allowed.contains(value['path']) ||
          value['path'] == '/api/backup/native/preflights/$id',
    ),
    isTrue,
  );
  expect(
    observations.where(
      (value) =>
          value['method'] == 'POST' &&
          value['path'] == '/api/backup/native/preflights',
    ),
    hasLength(1),
  );
}
