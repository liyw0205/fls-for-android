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
            _ => null,
          },
        );
    await tester.pumpWidget(const FLSApp());
    await tester.pumpAndSettle();

    expect(find.text('FLS 面板'), findsOneWidget);
    expect(find.text('远程面板'), findsOneWidget);
    expect(find.text('本机面板'), findsOneWidget);
    expect(find.text('没有已保存的面板'), findsOneWidget);
  });
}

class _TestPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      '/tmp/fls-for-android-test';
}
