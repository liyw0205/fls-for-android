import 'package:fls_for_android/features/online_scripts_view.dart';
import 'package:fls_for_android/services/local_install_manager.dart';
import 'package:fls_for_android/services/online_scripts_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

    await _pumpScriptsView(tester, offlineAfterCache: true);

    expect(find.text('Daily check-in'), findsOneWidget);
    expect(find.text('Weather tools'), findsOneWidget);
    await _pumpUntilVisible(tester, find.textContaining('正在显示缓存'));
    expect(find.textContaining('缓存同步于'), findsOneWidget);
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
  bool offlineAfterCache = false,
}) async {
  final manager = _TestOnlineScriptsManager(offline: offlineAfterCache);
  addTearDown(manager.close);
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
  await _pumpUntilVisible(tester, find.text('Daily check-in'));
  if (find.text('Daily check-in').evaluate().isEmpty) {
    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    fail('Online catalog did not load. Visible text: $visibleText');
  }
}

Future<void> _pumpUntilVisible(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 20 && finder.evaluate().isEmpty; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _TestOnlineScriptsManager extends OnlineScriptsManager {
  _TestOnlineScriptsManager({required this.offline});

  final bool offline;

  static final _scripts = [
    OnlineScript(
      id: 'daily_checkin',
      name: 'Daily check-in',
      type: 'raw',
      link: Uri(scheme: 'https', host: 'example.com', path: '/checkin.py'),
      linkName: 'checkin.py',
      installCommand: '',
    ),
    OnlineScript(
      id: 'weather_tools',
      name: 'Weather tools',
      type: 'repo',
      link: Uri(
        scheme: 'https',
        host: 'github.com',
        path: '/example/weather-tools',
      ),
      linkName: 'weather-tools',
      installCommand: '',
    ),
  ];

  OnlineScriptsCatalogSnapshot get _snapshot => OnlineScriptsCatalogSnapshot(
    scripts: _scripts,
    lastCheckedAt: DateTime.utc(2026, 11, 24, 8),
    lastSyncedAt: DateTime.utc(2026, 11, 24, 7, 30),
    fromCache: offline,
    refreshError: offline ? 'offline' : null,
  );

  @override
  Future<OnlineScriptsCatalogSnapshot?> readCachedCatalog() async => _snapshot;

  @override
  Future<OnlineScriptsCatalogSnapshot> fetchCatalogSnapshot() async =>
      _snapshot;

  @override
  Future<bool> hasInstallTarget(
    OnlineScript script,
    LocalInstallManager installManager,
  ) async => false;
}
