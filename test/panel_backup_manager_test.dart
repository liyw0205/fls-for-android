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
