import 'dart:async';
import 'dart:convert';

import 'package:fls_for_android/models/panel_log_cleanup.dart';
import 'package:fls_for_android/models/panel_records.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_log_cleanup_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'panel_log_cleanup_fixtures.dart';

List<PanelLogFile> files([int count = 2]) => [
  for (var i = 0; i < count; i++)
    PanelLogFile(
      filename: 'worker$i.log',
      group: 'Workers',
      sizeBytes: 12,
      modifiedAt: 'now',
      version: 'd' * 64,
    ),
];

PanelLogCleanupManager managerFor(
  PanelApiClient api, {
  PanelLogCleanupRecovery? recovery,
}) => PanelLogCleanupManager(
  api,
  panelId: 'https://fls.example',
  panelLabel: '测试面板',
  recovery: recovery ?? PanelLogCleanupRecovery('https://fls.example'),
);

void main() {
  test(
    'late queries from a previous session cannot overwrite newer reconciled results',
    () async {
      final payload = cleanupPreview();
      final oldResponse = Completer<http.Response>();
      final api = cleanupApi((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        if (request.url.path.endsWith('/preview')) return cleanupJson(payload);
        return oldResponse.future;
      });
      addTearDown(api.close);
      final manager = managerFor(api);
      final operation = manager.prepare(await manager.preview(files: files()));
      final oldQuery = manager.query(operation);
      final newerApi = cleanupApi(
        (request) async => cleanupJson(
          cleanupResult(
            payload,
            operation.requestId,
            statuses: ['missing', 'conflict'],
          ),
        ),
      );
      addTearDown(newerApi.close);
      final newer = managerFor(newerApi, recovery: manager.recovery);
      await newer.reconcile(operation);
      oldResponse.complete(
        cleanupJson(
          cleanupResult(
            payload,
            operation.requestId,
            statuses: ['unknown', 'unknown'],
          ),
        ),
      );
      await oldQuery;
      expect(operation.result!.status, 'completed');
      expect(operation.result!.counts['conflict'], 1);
    },
  );

  test(
    'binds preview, submission and recovery to fixed targets and sends one delete POST',
    () async {
      final requests = <http.Request>[];
      final previewPayload = cleanupPreview();
      final api = cleanupApi((request) async {
        requests.add(request);
        expect(request.headers['cookie'], 'fls_native_session=cleanup');
        if (request.method == 'POST') {
          expect(request.headers['x-csrf-token'], 'cleanup-csrf');
        }
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        if (request.url.path.endsWith('/preview')) {
          expect(jsonDecode(request.body), {
            'files': [
              for (var i = 0; i < 2; i++)
                {'filename': 'worker$i.log', 'version': 'd' * 64},
            ],
          });
          return cleanupJson(previewPayload);
        }
        final id = request.method == 'GET'
            ? request.url.path.split('/').last
            : (jsonDecode(request.body) as Map)['request_id'] as String;
        return cleanupJson(cleanupResult(previewPayload, id));
      });
      addTearDown(api.close);
      final manager = managerFor(api);
      final preview = await manager.preview(files: files());
      final operation = manager.prepare(preview);
      expect(manager.recovery.operations.single, same(operation));
      expect((await manager.submit(operation)).counts['busy'], 1);
      expect((await manager.query(operation)).counts['deleted'], 1);
      await expectLater(manager.submit(operation), throwsStateError);
      expect(() => manager.prepare(preview), throwsStateError);
      expect(
        requests.where(
          (request) =>
              request.method == 'POST' && request.url.path == cleanupPath,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'uncertain POST and missing receipt retain identity across renewed authentication without replay',
    () async {
      final previewPayload = cleanupPreview();
      var submits = 0;
      final api = cleanupApi((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        if (request.url.path.endsWith('/preview')) {
          return cleanupJson(previewPayload);
        }
        if (request.url.path == cleanupPath) {
          submits++;
          return cleanupJson({'ok': false, 'msg': '连接中断'}, 503);
        }
        return cleanupJson(
          cleanupResult(
            previewPayload,
            request.url.path.split('/').last,
            missing: true,
          ),
        );
      });
      addTearDown(api.close);
      final manager = managerFor(api);
      final operation = manager.prepare(await manager.preview(files: files()));
      await expectLater(
        manager.submit(operation),
        throwsA(isA<PanelApiException>()),
      );
      final renewed = managerFor(api, recovery: manager.recovery);
      expect((await renewed.query(operation)).status, 'missing');
      await expectLater(renewed.submit(operation), throwsStateError);
      manager.recovery.clearCompleted();
      expect(manager.recovery.operations.single, same(operation));
      expect(submits, 1);
    },
  );

  test(
    'only the dedicated capability 404 means unsupported; business 404 and denied requests propagate',
    () async {
      for (final status in [401, 403, 404, 503]) {
        final api = cleanupApi(
          (_) async => cleanupJson({'ok': false, 'msg': 'denied'}, status),
        );
        addTearDown(api.close);
        final manager = managerFor(api);
        if (status == 404) {
          expect((await manager.capabilities()).supported, isFalse);
        } else {
          await expectLater(
            manager.capabilities(),
            throwsA(
              isA<PanelApiException>().having(
                (e) => e.statusCode,
                'status',
                status,
              ),
            ),
          );
        }
      }
      final api = cleanupApi(
        (request) async => request.url.path.endsWith('/capabilities')
            ? cleanupJson(cleanupCapabilities())
            : cleanupJson({'msg': 'not found'}, 404),
      );
      addTearDown(api.close);
      await expectLater(
        managerFor(api).preview(files: files()),
        throwsA(
          isA<PanelApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    },
  );

  test(
    'rejects changed file targets, invalid versions and oversized selection before deletion',
    () async {
      final api = cleanupApi((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        final payload = cleanupPreview();
        ((payload['preview'] as Map)['items'] as List)[0]['filename'] =
            'another.log';
        return cleanupJson(payload);
      });
      addTearDown(api.close);
      final manager = managerFor(api);
      await expectLater(
        manager.preview(files: files()),
        throwsA(isA<PanelApiException>()),
      );
      await expectLater(
        manager.preview(files: files(201)),
        throwsArgumentError,
      );
      await expectLater(
        manager.preview(
          files: [
            const PanelLogFile(
              filename: 'old.log',
              group: '',
              sizeBytes: 0,
              modifiedAt: '',
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(manager.recovery.operations, isEmpty);
    },
  );

  test(
    'strict receipts reject a different request, digest, version, target set, count or status',
    () {
      final payload = cleanupPreview();
      final preview = PanelLogCleanupPreview.fromJson(payload);
      final requestId = 'e' * 32;
      for (final field in [
        'request_id',
        'digest',
        'version',
        'filename',
        'counts',
        'status',
      ]) {
        final row = (cleanupResult(payload, requestId)['request'] as Map);
        switch (field) {
          case 'request_id':
            row[field] = 'f' * 32;
          case 'digest':
            row[field] = 'f' * 64;
          case 'version':
            (row['items'] as List)[0]['version'] = 'f' * 64;
          case 'filename':
            (row['items'] as List)[0]['filename'] = 'other.log';
          case 'counts':
            (row['counts'] as Map)['deleted'] = 2;
          case 'status':
            row['status'] = 'unknown';
        }
        expect(
          () => PanelLogCleanupResult.fromJson(
            {'ok': true, 'request': row},
            requestId: requestId,
            preview: preview,
          ),
          throwsFormatException,
          reason: field,
        );
      }
    },
  );

  test(
    'group snapshots, unknown reconcile and panel boundaries never create a new deletion',
    () async {
      final previewPayload = cleanupPreview(groups: ['Workers']);
      final requests = <http.Request>[];
      final api = cleanupApi((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/capabilities')) {
          return cleanupJson(cleanupCapabilities());
        }
        if (request.url.path.endsWith('/preview')) {
          expect(jsonDecode(request.body), {
            'groups': ['Workers'],
          });
          return cleanupJson(previewPayload);
        }
        final reconcile = request.url.path.endsWith('/reconcile');
        if (reconcile) expect(jsonDecode(request.body), isEmpty);
        final id = request.url.path == cleanupPath
            ? (jsonDecode(request.body) as Map)['request_id'] as String
            : request.url.path.split('/')[request.url.path.split('/').length -
                  (reconcile ? 2 : 1)];
        return cleanupJson(
          cleanupResult(
            previewPayload,
            id,
            statuses: reconcile
                ? ['missing', 'conflict']
                : ['unknown', 'unknown'],
          ),
        );
      });
      addTearDown(api.close);
      final manager = managerFor(api);
      final operation = manager.prepare(
        await manager.preview(groups: ['Workers']),
      );
      expect((await manager.submit(operation)).status, 'unknown');
      final other = managerFor(api);
      expect(() => other.query(operation), throwsArgumentError);
      expect(
        () => PanelLogCleanupManager(
          api,
          panelId: 'other',
          panelLabel: '其他面板',
          recovery: manager.recovery,
        ),
        throwsArgumentError,
      );
      expect((await manager.reconcile(operation)).counts['conflict'], 1);
      expect(
        requests.where((request) => request.url.path == cleanupPath),
        hasLength(1),
      );
      manager.recovery.clearCompleted();
      expect(manager.recovery.operations, isEmpty);
    },
  );

  test(
    'log list versions are optional for reading and strictly typed when present',
    () {
      final legacy = {
        'filename': 'old.log',
        'group': '',
        'size_bytes': 0,
        'modified_at': '',
      };
      expect(PanelLogFile.fromJson(legacy).version, isNull);
      expect(
        () => PanelLogFile.fromJson({...legacy, 'busy': 'false'}),
        throwsFormatException,
      );
      expect(
        () => PanelLogFile.fromJson({...legacy, 'version': '../bad'}),
        throwsFormatException,
      );
    },
  );
}
