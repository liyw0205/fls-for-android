import 'dart:async';

import 'package:fls_for_android/features/online_scripts_view.dart';
import 'package:fls_for_android/services/local_install_manager.dart';
import 'package:fls_for_android/services/online_scripts_manager.dart';
import 'package:fls_for_android/services/operation_cancellation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('script detail shows progress, cancellation and log controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final manager = await _pumpScriptsView(tester);
    await tester.tap(find.text('Daily check-in'));
    await tester.pump();
    await _pumpUntilVisible(tester, find.text('脚本文档'));

    expect(find.text('安装脚本'), findsOneWidget);
    expect(find.text('Script instructions'), findsOneWidget);
    await tester.tap(find.text('安装脚本'));
    await tester.pump();
    expect(find.text('安装在线脚本？'), findsOneWidget);
    await tester.tap(find.text('确认安装'));
    await tester.pump();
    await manager.installStarted.future;
    await tester.pump();

    expect(find.textContaining('0.5 MB / 1.0 MB'), findsOneWidget);
    expect(find.textContaining('50%'), findsOneWidget);
    expect(find.text('下载脚本'), findsOneWidget);
    expect(find.byTooltip('暂停自动滚动'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump();
    await _pumpUntilVisible(tester, find.text('已取消'));
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('操作已取消'), findsNothing);

    await tester.tap(find.byTooltip('暂停自动滚动'));
    await tester.pump();
    expect(find.byTooltip('恢复自动滚动'), findsOneWidget);
    await tester.tap(find.byTooltip('复制日志'));
    await tester.pump();
    expect(clipboardText, 'download started');
    expect(tester.takeException(), isNull);
  });
}

Future<_TestOnlineScriptsManager> _pumpScriptsView(
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
  return manager;
}

Future<void> _pumpUntilVisible(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 20 && finder.evaluate().isEmpty; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _TestOnlineScriptsManager extends OnlineScriptsManager {
  _TestOnlineScriptsManager({required this.offline});

  final bool offline;
  final Completer<void> installStarted = Completer<void>();
  final Completer<void> installGate = Completer<void>();

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
  Future<String> fetchDocument(OnlineScript script) async =>
      '# Script instructions\n\nInstall safely.';

  @override
  Future<bool> hasInstallTarget(
    OnlineScript script,
    LocalInstallManager installManager,
  ) async => false;

  @override
  Future<void> installOrUpdateNative({
    required OnlineScript script,
    required LocalInstallManager installManager,
    required bool overwriteExisting,
    required OperationCancellation cancellation,
    required OnlineScriptsStatusCallback onStatus,
    OnlineScriptsLogCallback? onLog,
    OnlineScriptsProgressCallback? onProgress,
  }) async {
    onStatus('下载脚本');
    onProgress?.call(524288, 1048576);
    onLog?.call('download started');
    installStarted.complete();
    await Future.any<void>([
      installGate.future,
      cancellation.whenCancelled.then<void>(
        (_) => throw const OperationCancelled(),
      ),
    ]);
  }
}
