import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fls_for_android/services/online_scripts_manager.dart';

void main() {
  test(
    'catalog validates HTTPS sources and ignores duplicate or invalid rows',
    () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'catalog.example');
        return http.Response(
          jsonEncode([
            {
              'id': 'daily_checkin',
              'name': 'Daily check-in',
              'type': 'raw',
              'link': 'https://github.com/example/checkin.py',
              'link_name': 'checkin.py',
              'doc_link': 'https://cdn.example/checkin/README.md',
              'install': 'python -m pip install requests',
            },
            {
              'id': 'daily_checkin',
              'name': 'Duplicate',
              'type': 'raw',
              'link': 'https://github.com/example/duplicate.py',
            },
            {
              'id': 'unsafe',
              'name': 'Unsafe URL',
              'type': 'raw',
              'link': 'http://example.com/script.py',
            },
            {
              'id': 'unsupported',
              'name': 'Unsupported type',
              'type': 'shell',
              'link': 'https://example.com/script.sh',
            },
          ]),
          200,
        );
      });
      final manager = OnlineScriptsManager(
        client: client,
        catalogUri: Uri.parse('https://catalog.example/index.json'),
      );
      addTearDown(manager.close);

      final catalog = await manager.fetchCatalog();

      expect(catalog, hasLength(1));
      expect(catalog.single.id, 'daily_checkin');
      expect(catalog.single.docLink?.host, 'cdn.example');
      expect(catalog.single.installCommand, 'python -m pip install requests');
    },
  );

  test('online script identifiers reject paths and whitespace', () {
    expect(
      () => OnlineScript.fromJson({
        'id': '../unsafe',
        'name': 'Unsafe',
        'type': 'raw',
        'link': 'https://example.com/script.py',
      }),
      throwsFormatException,
    );
  });
}
