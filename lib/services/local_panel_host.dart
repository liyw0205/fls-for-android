import 'package:flutter/services.dart';

enum LocalPanelState {
  stopped,
  stopping,
  starting,
  running,
  retrying,
  crashed,
  failed,
  interrupted,
  unknown,
}

class LocalPanelStatus {
  const LocalPanelStatus({
    required this.state,
    required this.startedAt,
    required this.exitCode,
    required this.restartAttempts,
    required this.autoRestart,
  });

  final LocalPanelState state;
  final DateTime? startedAt;
  final int? exitCode;
  final int restartAttempts;
  final bool autoRestart;

  bool get isRunning => state == LocalPanelState.running;

  factory LocalPanelStatus.fromMap(Map<String, dynamic>? values) {
    final state = LocalPanelState.values.firstWhere(
      (value) => value.name == values?['state'],
      orElse: () => LocalPanelState.unknown,
    );
    final startedAtMs = values?['startedAtMs'];
    final exitCode = values?['exitCode'];
    return LocalPanelStatus(
      state: state,
      startedAt: startedAtMs is num && startedAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(startedAtMs.toInt())
          : null,
      exitCode: exitCode is int ? exitCode : null,
      restartAttempts: values?['restartAttempts'] is int
          ? values!['restartAttempts'] as int
          : 0,
      autoRestart: values?['autoRestart'] == true,
    );
  }
}

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
    // The in-container stop script can take up to eight seconds before the
    // Android service falls back to terminating the PRoot process.
    for (var attempt = 0; attempt < 240; attempt++) {
      final running = await isRunning();
      final status = await LocalPanelHost.status();
      if (!running && status.state == LocalPanelState.stopped) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('本机面板停止超时，进程仍在运行');
  }

  static Future<bool> isRunning() async =>
      await _channel.invokeMethod<bool>('isRunning') ?? false;

  static Future<LocalPanelStatus> status() async {
    final values = await _channel.invokeMapMethod<String, dynamic>('status');
    return LocalPanelStatus.fromMap(values);
  }

  static Future<void> setAutoRestart(bool enabled) =>
      _channel.invokeMethod<void>('setAutoRestart', {'enabled': enabled});

  static Future<bool> notificationsGranted() async =>
      await _channel.invokeMethod<bool>('notificationsGranted') ?? false;

  static Future<void> requestNotificationPermission() =>
      _channel.invokeMethod<void>('requestNotificationPermission');

  static Future<void> openAppSettings() =>
      _channel.invokeMethod<void>('openAppSettings');

  static Future<void> openBatterySettings() =>
      _channel.invokeMethod<void>('openBatterySettings');

  static Future<String> readServiceLog() async =>
      await _channel.invokeMethod<String>('readServiceLog') ?? '暂无本机服务日志';
}
