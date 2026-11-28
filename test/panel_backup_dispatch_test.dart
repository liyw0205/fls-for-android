import 'dart:convert';
import 'dart:io';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_backup_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_test_http.dart';

void main() {
  test(
    'multipart dispatch guard runs after file assembly and before send',
    () async {
      final directory = await Directory.systemTemp.createTemp('fls-multipart-');
      addTearDown(() => directory.delete(recursive: true));
      final archive = File('${directory.path}/full.zip');
      await archive.writeAsBytes([1, 2, 3]);
      var posts = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/prefix',
        client: panelMockClient((_) async {
          posts++;
          return utf8Response('{}', 200);
        }),
      );
      addTearDown(api.close);
      var guards = 0;
      await expectLater(
        api.postMultipartFile(
          '/api/backup/native/preflights',
          filePath: archive.path,
          filename: 'full.zip',
          fields: const {},
          onProgress: (_, _) => fail('Invalidated upload emitted progress'),
          beforeSend: () {
            guards++;
            throw const PanelApiException('Upload invalidated');
          },
        ),
        throwsA(isA<PanelApiException>()),
      );
      expect(guards, 1);
      expect(posts, 0);
      await archive.delete();
      await expectLater(
        api.postMultipartFile(
          '/api/backup/native/preflights',
          filePath: archive.path,
          filename: 'full.zip',
          fields: const {},
          onProgress: (_, _) {},
          beforeSend: () => guards++,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(guards, 1);
      expect(posts, 0);
    },
  );

  test(
    'invalidated upload preparation sends no POST or unknown record',
    () async {
      final directory = await Directory.systemTemp.createTemp('fls-dispatch-');
      addTearDown(() => directory.delete(recursive: true));
      final archive = File('${directory.path}/full.zip');
      await archive.writeAsBytes([1, 2, 3]);
      final id = 'a' * 32;
      var posts = 0;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/prefix',
        client: panelMockClient((request) async {
          posts++;
          return utf8Response(
            jsonEncode({
              'ok': true,
              'preflight': {
                'preflight_id': id,
                'status': 'ready',
                'active': false,
                'cancel_allowed': false,
                'filename': 'full.zip',
                'format': 'zip',
                'archive_size_bytes': 3,
                'archive_sha256': 'b' * 64,
                'items': ['data'],
                'entry_count': 1,
                'expanded_bytes': 3,
                'dependency_files': <String>[],
                'warnings': <String>[],
                'error_code': '',
                'expires_at': 1796000000,
              },
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelBackupManager(api);
      final pending = manager.createPreflight(
        filePath: archive.path,
        filename: 'full.zip',
        requestId: id,
        maxBytes: 100,
        onProgress: (_, _) {},
      );
      manager.recovery.invalidateObservations();
      await expectLater(pending, throwsA(isA<PanelApiException>()));
      expect(posts, 0);
      expect(manager.recovery.operations, isEmpty);
    },
  );
}
