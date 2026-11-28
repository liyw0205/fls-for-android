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
  test(
    'pinned FLS native session transfers and recovers real backup operations',
    () async {
      final process = await Process.start('python3', [
        'tool/panel_backup_fixture.py',
        '--backend',
        backend!,
        '--revision',
        _backendRevision,
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
      expect(fixture['revision'], _backendRevision);
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
        final response = await transport.get(
          Uri.parse(fixture!['evidence_url'] as String),
        );
        expect(response.statusCode, 200);
        return jsonDecode(response.body) as Map<String, dynamic>;
      }

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
      expect(capabilities.restoreEnabled, isTrue);
      expect(capabilities.preflightEnabled, isTrue);
      final recovery = manager.recovery;
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
        expect(restoredEvidence['scheduler_running'], isFalse);
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
        expect(scheduled['scheduler_running'], isFalse);
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
        ? 'Set FLS_PAIR_ROOT to the pinned FLS checkout'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
