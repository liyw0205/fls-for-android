import 'dart:convert';
import 'dart:io';

import 'package:fls_for_android/features/online_scripts_view.dart';
import 'package:fls_for_android/services/local_install_manager.dart';
import 'package:fls_for_android/services/online_scripts_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('catalog filters script sources on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpScriptsView(tester);

    expect(find.text('Daily check-in'), findsOneWidget);
    expect(find.text('Weather tools'), findsOneWidget);
    await tester.tap(find.text('仓库'));
    await tester.pump();

    expect(find.text('Daily check-in'), findsNothing);
    expect(find.text('Weather tools'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog layout handles landscape and enlarged text', (
    tester,
  ) async {
    for (final size in [const Size(800, 360), const Size(360, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await _pumpScriptsView(
        tester,
        textScaler: size.width < 400
            ? const TextScaler.linear(1.8)
            : const TextScaler.linear(1),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Daily check-in'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}

Future<void> _pumpScriptsView(
  WidgetTester tester, {
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  final previousPathProvider = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _TestPathProvider();
  addTearDown(() => PathProviderPlatform.instance = previousPathProvider);

  final client = MockClient((request) async {
    return http.Response(
      jsonEncode([
        {
          'id': 'daily_checkin',
          'name': 'Daily check-in',
          'type': 'raw',
          'link': 'https://example.com/checkin.py',
        },
        {
          'id': 'weather_tools',
          'name': 'Weather tools',
          'type': 'repo',
          'link': 'https://github.com/example/weather-tools',
        },
      ]),
      200,
    );
  });
  final manager = OnlineScriptsManager(
    client: client,
    catalogUri: Uri.parse('https://catalog.example/index.json'),
  );
  addTearDown(() {
    manager.close();
    client.close();
  });

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: tester.view.physicalSize / tester.view.devicePixelRatio,
          textScaler: textScaler,
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: OnlineScriptsView(
              manager: manager,
              runtimeAvailable: true,
              installManager: LocalInstallManager(),
              onOpenEnvironment: () {},
              onBusyChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  for (
    var frame = 0;
    frame < 20 && find.text('Daily check-in').evaluate().isEmpty;
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (find.text('Daily check-in').evaluate().isEmpty) {
    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    fail('Online catalog did not load. Visible text: $visibleText');
  }
}

class _TestPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      Directory.systemTemp.path;
}
