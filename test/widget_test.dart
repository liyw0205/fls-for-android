import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fls_for_android/features/local_setup_view.dart';
import 'package:fls_for_android/main.dart';
import 'package:fls_for_android/services/local_install_manager.dart';

void main() {
  testWidgets('shows the remote and local panel modes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider();
    addTearDown(() => PathProviderPlatform.instance = previousPathProvider);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('top.fls/local_panel'),
          (call) async => switch (call.method) {
            'supportedAbis' => ['arm64-v8a'],
            'isRunning' => false,
            'status' => {
              'state': 'stopped',
              'startedAtMs': 0,
              'restartAttempts': 0,
              'autoRestart': false,
            },
            'notificationsGranted' => true,
            _ => null,
          },
        );
    await tester.pumpWidget(const FLSApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('FLS 面板'), findsOneWidget);
    expect(find.text('远程面板'), findsOneWidget);
    expect(find.text('本机面板'), findsOneWidget);
    expect(find.text('没有已保存的面板'), findsOneWidget);

    await tester.tap(find.text('本机面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('运行'), findsOneWidget);
    expect(find.text('环境'), findsOneWidget);
    expect(find.text('脚本'), findsOneWidget);
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('首次安装镜像'), findsOneWidget);
    expect(find.text('Python 基础'), findsOneWidget);
    expect(find.text('Full 预装'), findsOneWidget);
    await tester.tap(find.text('环境'));
    await tester.pump();
    expect(find.text('容器基础镜像'), findsOneWidget);
    expect(find.text('Python 基础'), findsOneWidget);
    expect(find.text('Full 预装'), findsOneWidget);
    expect(find.text('导入容器'), findsOneWidget);
    expect(find.text('导出容器'), findsOneWidget);
    await tester.tap(find.text('运行'));
    await tester.pump();
    expect(find.text('安装本机 FLS'), findsOneWidget);
  });

  testWidgets('remote panel actions confirm data sync and include remove', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'remote_panels_v1': '[{"name":"Home","url":"http://192.168.1.2:5700"}]',
    });
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider();
    addTearDown(() => PathProviderPlatform.instance = previousPathProvider);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('top.fls/local_panel'),
          (call) async => switch (call.method) {
            'supportedAbis' => ['arm64-v8a'],
            'isRunning' => false,
            'status' => {
              'state': 'stopped',
              'startedAtMs': 0,
              'restartAttempts': 0,
              'autoRestart': false,
            },
            'notificationsGranted' => true,
            _ => null,
          },
        );

    await tester.pumpWidget(const FLSApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Home'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('同步服务器数据到本机'), findsOneWidget);
    expect(find.text('移除'), findsOneWidget);
    await tester.tap(find.text('同步服务器数据到本机'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('同步服务器数据到本机？'), findsOneWidget);
    expect(find.text('同步并覆盖本机 data'), findsOneWidget);
    expect(find.textContaining('本机数据会被覆盖'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('同步服务器数据到本机？'), findsNothing);
  });

  testWidgets('local panel controls and FLS update live on their own tabs', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var running = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('top.fls/local_panel'), (
          call,
        ) async {
          if (call.method == 'stop') {
            running = false;
            return null;
          }
          return switch (call.method) {
            'isRunning' => running,
            'status' => {
              'state': running ? 'running' : 'stopped',
              'startedAtMs': 0,
              'restartAttempts': 0,
              'autoRestart': false,
            },
            'notificationsGranted' => true,
            _ => null,
          };
        });

    await tester.pumpWidget(
      MaterialApp(
        home: LocalSetupView(
          manager: _TestLocalInstallManager(
            profile: RuntimeProfile.python,
            projectInstalled: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('停止面板'), findsOneWidget);
    expect(find.text('打开面板'), findsOneWidget);
    expect(find.text('版本与更新日志'), findsNothing);
    await tester.tap(find.text('停止面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('启动面板'), findsOneWidget);
    expect(find.text('Bad state:本机面板尚未停止，无法安全替换容器'), findsNothing);

    await tester.tap(find.text('环境'));
    await tester.pump();
    expect(find.text('版本与更新日志'), findsOneWidget);
    expect(find.text('打开 FLS 运行环境安装器'), findsNothing);
  });

  for (final size in [const Size(360, 800), const Size(800, 360)]) {
    testWidgets('local environment controls fit $size with enlarged text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      SharedPreferences.setMockInitialValues({});
      const panelChannel = MethodChannel('top.fls/local_panel');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        panelChannel,
        (call) async => switch (call.method) {
          'supportedAbis' => ['arm64-v8a'],
          'status' => {'state': 'stopped'},
          'notificationsGranted' => true,
          _ => null,
        },
      );
      addTearDown(() => messenger.setMockMethodCallHandler(panelChannel, null));

      final manager = _TestLocalInstallManager();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LocalSetupView(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();

      Future<Rect> reveal(Finder target) async {
        await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
        await tester.pumpAndSettle();
        final rect = tester.getRect(target);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(size.height));
        expect(target.hitTestable(), findsOneWidget);
        return rect;
      }

      final environment = find.text('环境');
      await reveal(environment);
      await tester.tap(environment);
      await tester.pumpAndSettle();

      final profiles = find.byType(SegmentedButton<RuntimeProfile>);
      final python = find.descendant(
        of: profiles,
        matching: find.text('Python 基础'),
      );
      final full = find.descendant(
        of: profiles,
        matching: find.text('Full 预装'),
      );
      await reveal(profiles);
      expect(python.hitTestable(), findsOneWidget);
      expect(full.hitTestable(), findsOneWidget);
      expect(tester.getRect(python).overlaps(tester.getRect(full)), isFalse);
      expect(find.textContaining('轻量容器，包含 Python'), findsOneWidget);
      await tester.tap(full);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SegmentedButton<RuntimeProfile>>(profiles).selected,
        {RuntimeProfile.all},
      );
      expect(find.textContaining('镜像预装常用 Linux 工具'), findsOneWidget);

      final toggle = find.widgetWithText(SwitchListTile, '使用 GitHub 加速源');
      await reveal(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(manager.savedMirror, builtinGithubMirrors.first.prefix);
      expect(find.byType(RadioListTile<String>), findsNWidgets(6));

      final measure = find.text('批量测速');
      await reveal(measure);
      await tester.tap(measure);
      await tester.pumpAndSettle();
      final fastest = builtinGithubMirrors.last;
      final fastestTile = find.widgetWithText(
        RadioListTile<String>,
        fastest.name,
      );
      await reveal(fastestTile);
      expect(
        tester
            .widget<RadioListTile<String>>(
              find.byType(RadioListTile<String>).first,
            )
            .value,
        fastest.prefix,
      );
      expect(
        find.descendant(of: fastestTile, matching: find.text('42 ms')),
        findsOneWidget,
      );

      final custom = find.widgetWithText(RadioListTile<String>, '自定义');
      await reveal(custom);
      await tester.tap(custom);
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      await reveal(input);
      const customMirror = 'https://mirror.example/';
      await tester.enterText(input, customMirror);
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      expect(manager.savedMirror, customMirror);
      await reveal(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(manager.savedMirror, isEmpty);
      expect(custom, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed local service exposes its diagnostics', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('top.fls/local_panel'),
          (call) async => switch (call.method) {
            'supportedAbis' => ['arm64-v8a'],
            'isRunning' => false,
            'status' => {
              'state': 'failed',
              'startedAtMs': 0,
              'restartAttempts': 0,
              'autoRestart': false,
            },
            'notificationsGranted' => true,
            'readServiceLog' => '[service] 恢复失败: 容器内 Python 入口缺失',
            _ => null,
          },
        );

    await tester.pumpWidget(
      MaterialApp(home: LocalSetupView(manager: _TestLocalInstallManager())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('启动失败'), findsOneWidget);
    expect(find.text('查看启动诊断'), findsOneWidget);
    await tester.tap(find.text('查看启动诊断'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('容器内 Python 入口缺失'), findsOneWidget);
  });
}

class _TestPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      '/tmp/fls-for-android-test';
}

class _TestLocalInstallManager extends LocalInstallManager {
  _TestLocalInstallManager({this.profile, this.projectInstalled = false});

  final RuntimeProfile? profile;
  final bool projectInstalled;
  String savedMirror = '';

  @override
  Future<RuntimeProfile?> installedRuntimeProfile() async => profile;

  @override
  Future<bool> hasProject() async => projectInstalled;

  @override
  Future<String> loadGithubMirror() async => savedMirror;

  @override
  Future<void> saveGithubMirror(String value) async => savedMirror = value;

  @override
  Future<List<GithubMirrorTestResult>> testGithubMirrors({
    String? customMirror,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final fastest = builtinGithubMirrors.last;
    return [
      GithubMirrorTestResult(
        mirror: fastest.prefix,
        name: fastest.name,
        latency: const Duration(milliseconds: 42),
      ),
    ];
  }

  @override
  Future<String?> currentPanelVersion() async => null;

  @override
  Future<List<PanelRelease>> fetchPanelReleases({
    String? githubMirror,
    int limit = 10,
  }) async => const [];

  @override
  Future<Map<RuntimeProfile, RuntimeAsset>> fetchRuntimeAssets({
    required List<String> supportedAbis,
    String? githubMirror,
  }) async => const {};
}
