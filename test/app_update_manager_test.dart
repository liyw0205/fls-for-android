import 'dart:convert';

import 'package:fls_for_android/services/app_update_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'compares installed and latest releases and reads commits between tags',
    () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            jsonEncode({
              'tag_name': 'v0.1.10+11',
              'name': 'FLS for Android v0.1.10',
              'body': 'Release notes',
              'html_url':
                  'https://github.com/liyw0205/fls-for-android/releases/tag/v0.1.10',
              'assets': [
                {
                  'name': 'fls-for-android-0.1.10+11-arm64.apk',
                  'browser_download_url':
                      'https://github.com/liyw0205/fls-for-android/releases/download/v0.1.10/app-arm64.apk',
                },
              ],
            }),
            200,
          );
        }
        expect(
          request.url.toString(),
          contains('/compare/v0.1.9%2B10...v0.1.10%2B11'),
        );
        return http.Response(
          jsonEncode({
            'commits': [
              {
                'sha': '0123456789abcdef0123456789abcdef01234567',
                'html_url':
                    'https://github.com/liyw0205/fls-for-android/commit/0123456789abcdef0123456789abcdef01234567',
                'commit': {
                  'message': 'feat: improve native script install\n\nDetails',
                },
              },
            ],
          }),
          200,
        );
      });
      final manager = AppUpdateManager(
        client: client,
        versionLoader: () async => '0.1.9+10',
      );
      addTearDown(manager.close);

      final result = await manager.checkForUpdates();

      expect(result.currentVersion, '0.1.9+10');
      expect(result.updateAvailable, isTrue);
      expect(result.latest.tagName, 'v0.1.10+11');
      expect(result.latest.apkUrl?.path, endsWith('app-arm64.apk'));
      expect(result.latest.commits, hasLength(1));
      expect(
        result.latest.commits.single.message,
        'feat: improve native script install',
      );
    },
  );

  test('uses release notes when the installed version is current', () async {
    final client = MockClient((request) async {
      expect(request.url.path, endsWith('/releases/latest'));
      return http.Response(
        jsonEncode({
          'tag_name': 'v0.1.9+10',
          'html_url':
              'https://github.com/liyw0205/fls-for-android/releases/tag/v0.1.9',
          'body': 'No pending changes',
          'assets': [],
        }),
        200,
      );
    });
    final manager = AppUpdateManager(
      client: client,
      versionLoader: () async => '0.1.9+10',
    );
    addTearDown(manager.close);

    final result = await manager.checkForUpdates();

    expect(result.updateAvailable, isFalse);
    expect(result.latest.commits, isEmpty);
  });
}
