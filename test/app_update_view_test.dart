import 'dart:convert';

import 'package:fls_for_android/features/app_update_view.dart';
import 'package:fls_for_android/services/app_update_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('renders update commits and keeps the download action visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final manager = AppUpdateManager(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return _release(tag: 'v0.1.21+22');
        }
        return http.Response(
          jsonEncode({
            'commits': [
              {
                'sha': '0123456789abcdef0123456789abcdef01234567',
                'html_url':
                    'https://github.com/liyw0205/fls-for-android/commit/0123456789abcdef0123456789abcdef01234567',
                'commit': {'message': 'feat: render app updates natively'},
              },
            ],
          }),
          200,
        );
      }),
      versionLoader: () async => '0.1.20+21',
    );
    addTearDown(manager.close);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: AppUpdateView(manager: manager),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.textContaining('v0.1.21+22'), findsOneWidget);
    expect(find.text('版本间变更'), findsOneWidget);
    expect(find.text('feat: render app updates natively'), findsOneWidget);
    expect(find.text('下载 APK'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('falls back to release notes when compare is unavailable', (
    tester,
  ) async {
    final manager = AppUpdateManager(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return _release(
            tag: 'v0.1.21+22',
            body: '## Release Notes\n\n- Offline-safe fallback',
          );
        }
        return http.Response('unavailable', 503);
      }),
      versionLoader: () async => '0.1.20+21',
    );
    addTearDown(manager.close);

    await tester.pumpWidget(MaterialApp(home: AppUpdateView(manager: manager)));
    await tester.pumpAndSettle();

    expect(find.text('更新日志'), findsOneWidget);
    expect(_selectableText('Release Notes'), findsOneWidget);
    expect(_selectableText('Offline-safe fallback'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a retry action after release lookup fails', (
    tester,
  ) async {
    var attempts = 0;
    final manager = AppUpdateManager(
      client: MockClient((request) async {
        attempts++;
        if (attempts == 1) return http.Response('unavailable', 503);
        return _release(tag: 'v0.1.20+21');
      }),
      versionLoader: () async => '0.1.20+21',
    );
    addTearDown(manager.close);

    await tester.pumpWidget(MaterialApp(home: AppUpdateView(manager: manager)));
    await tester.pumpAndSettle();

    expect(find.textContaining('HTTP 503'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('当前已是最新版本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

http.Response _release({
  required String tag,
  String body = 'Release notes',
}) => http.Response(
  jsonEncode({
    'tag_name': tag,
    'name': 'FLS for Android $tag',
    'body': body,
    'html_url': 'https://github.com/liyw0205/fls-for-android/releases/tag/$tag',
    'assets': [
      {
        'name': 'fls-for-android-arm64.apk',
        'browser_download_url':
            'https://github.com/liyw0205/fls-for-android/releases/download/$tag/app-arm64.apk',
      },
    ],
  }),
  200,
);

Finder _selectableText(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is SelectableText &&
      (widget.data ?? widget.textSpan?.toPlainText()) == text,
);
