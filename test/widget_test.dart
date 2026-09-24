import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fls_for_android/main.dart';

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
    expect(find.text('诊断'), findsOneWidget);
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
    await tester.pumpAndSettle();
    expect(find.text('同步服务器数据到本机'), findsOneWidget);
    expect(find.text('移除'), findsOneWidget);
    await tester.tap(find.text('同步服务器数据到本机'));
    await tester.pumpAndSettle();
    expect(find.text('同步服务器数据到本机？'), findsOneWidget);
    expect(find.text('同步并覆盖本机 data'), findsOneWidget);
    expect(find.textContaining('本机数据会被覆盖'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('同步服务器数据到本机？'), findsNothing);
  });

  testWidgets('failed local service exposes its diagnostics', (tester) async {
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

    await tester.pumpWidget(const FLSApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('本机面板'));
    await tester.pumpAndSettle();

    expect(find.text('启动失败'), findsOneWidget);
    expect(find.text('查看启动诊断'), findsOneWidget);
    await tester.tap(find.text('查看启动诊断'));
    await tester.pump();

    expect(find.textContaining('容器内 Python 入口缺失'), findsOneWidget);
  });
}

class _TestPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      '/tmp/fls-for-android-test';
}
