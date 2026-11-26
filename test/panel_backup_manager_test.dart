import 'dart:convert';

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
}
