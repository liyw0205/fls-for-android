import 'package:flutter/services.dart';

class LocalPanelHost {
  static const _channel = MethodChannel('top.fls/local_panel');

  static Future<List<String>> supportedAbis() async {
    final values = await _channel.invokeListMethod<String>('supportedAbis');
    return values ?? const [];
  }

  static Future<bool> start({
    required String runtimeDir,
    required String projectDir,
    required String dataDir,
    required String logDir,
    required String scriptsDir,
  }) async {
    return await _channel.invokeMethod<bool>('start', {
          'runtimeDir': runtimeDir,
          'projectDir': projectDir,
          'dataDir': dataDir,
          'logDir': logDir,
          'scriptsDir': scriptsDir,
          'port': 5700,
        }) ??
        false;
  }

  static Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
    for (var attempt = 0; attempt < 50; attempt++) {
      if (!await isRunning()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('本机面板尚未停止，无法安全替换容器');
  }

  static Future<bool> isRunning() async =>
      await _channel.invokeMethod<bool>('isRunning') ?? false;
}
