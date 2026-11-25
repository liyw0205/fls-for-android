import 'dart:convert';

import 'package:fls_for_android/models/panel_script_file.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_script_files_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final revision = 'a' * 64;
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=file-session',
    csrfToken: 'file-csrf',
  );

  test(
    'uses native tree, UTF-8 snapshot, create and revision write contracts',
    () async {
      final requests = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/prefix',
        credentials: session,
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url}');
          expect(request.headers['cookie'], session.cookie);
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/scripts/tree')) {
            expect(request.url.queryParameters, {
              'path': 'tasks',
              'q': 'demo file',
              'page': '2',
              'limit': '10',
            });
            return _jsonResponse({
              'ok': true,
              'path': 'tasks',
              'parent': '',
              'items': [
                {
                  'name': 'demo.py',
                  'path': 'tasks/demo.py',
                  'kind': 'file',
                  'size_bytes': 12,
                  'modified_at': '2026-11-25T10:00:00+08:00',
                },
              ],
              'page': 2,
              'pages': 3,
              'total': 21,
              'limit': 10,
            });
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/scripts/file')) {
            expect(request.url.queryParameters, {'path': 'tasks/demo.py'});
            return _jsonResponse({
              'ok': true,
              'file': {
                'path': 'tasks/demo.py',
                'name': 'demo.py',
                'content': 'print("hello")\n',
                'revision': revision,
                'size_bytes': 15,
                'modified_at': '2026-11-25T10:00:00+08:00',
              },
            });
          }
          expect(request.headers['x-csrf-token'], session.csrfToken);
          if (request.method == 'PUT') {
            expect(request.url.path, '/prefix/api/scripts/file');
            expect(jsonDecode(request.body), {
              'path': 'tasks/demo.py',
              'content': 'print("saved")\n',
              'revision': revision,
            });
            return _jsonResponse({
              'ok': true,
              'changed': true,
              'file': {
                'path': 'tasks/demo.py',
                'name': 'demo.py',
                'content': 'print("saved")\n',
                'revision': 'b' * 64,
                'size_bytes': 15,
              },
            });
          }
          expect(request.method, 'POST');
          expect(jsonDecode(request.body), {
            'path': 'tasks/new.py',
            'kind': 'file',
            'content': '',
          });
          return _jsonResponse({
            'ok': true,
            'path': 'tasks/new.py',
            'kind': 'file',
          }, 201);
        }),
      );
      addTearDown(api.close);
      final manager = PanelScriptFilesManager(api);

      final page = await manager.fetchTree(
        path: 'tasks',
        query: 'demo file',
        page: 2,
        limit: 10,
      );
      final file = await manager.fetchFile('tasks/demo.py');
      final saved = await manager.saveFile(
        path: 'tasks/demo.py',
        content: 'print("saved")\n',
        revision: file.revision,
      );
      await manager.createFile(path: 'tasks/new.py', kind: 'file');

      expect(page.items.single.path, 'tasks/demo.py');
      expect(page.items.single.isDirectory, isFalse);
      expect(file.content, 'print("hello")\n');
      expect(saved.content, 'print("saved")\n');
      expect(requests, hasLength(4));
    },
  );

  test(
    'script conflict metadata is limited to a validated relative UTF-8 snapshot',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: MockClient(
          (request) async => _jsonResponse({
            'ok': false,
            'code': 'revision_conflict',
            'msg': '文件已被其他操作修改',
            'current': {
              'path': 'nested/demo.py',
              'name': 'demo.py',
              'content': 'server version',
              'revision': 'c' * 64,
              'size_bytes': 14,
              'modified_at': 'now',
              'absolute_path': '/secret/location',
            },
            'untrusted': 'drop-this',
          }, 409),
        ),
      );
      addTearDown(api.close);

      try {
        await PanelScriptFilesManager(api).saveFile(
          path: 'nested/demo.py',
          content: 'draft',
          revision: revision,
        );
        fail('expected a conflict');
      } on PanelApiException catch (error) {
        expect(error.statusCode, 409);
        expect(error.data?['code'], 'revision_conflict');
        final current = error.data?['current'] as Map<String, dynamic>;
        expect(current['content'], 'server version');
        expect(current.containsKey('absolute_path'), isFalse);
        expect(error.data!.containsKey('untrusted'), isFalse);
      }
    },
  );

  test('rejects absolute, traversal, and malformed server paths', () async {
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      client: MockClient((_) async {
        fail('invalid paths must not issue a request');
      }),
    );
    addTearDown(api.close);
    await expectLater(
      PanelScriptFilesManager(api).fetchFile('/etc/passwd'),
      throwsArgumentError,
    );
    expect(
      () => PanelScriptFileItem.fromJson({
        'name': 'bad',
        'path': '../outside',
        'kind': 'file',
      }),
      throwsFormatException,
    );
  });
}

http.Response _jsonResponse(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);
