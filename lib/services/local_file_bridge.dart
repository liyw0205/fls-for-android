import 'package:flutter/services.dart';

class LocalFileBridge {
  static const _channel = MethodChannel('top.fls/file_bridge');

  static Future<String?> pickContainer() =>
      _channel.invokeMethod<String>('pickContainer');

  static Future<bool> copyUriToPath({
    required String uri,
    required String path,
  }) async {
    return await _channel.invokeMethod<bool>('copyUriToPath', {
          'uri': uri,
          'path': path,
        }) ??
        false;
  }

  static Future<bool> saveFile({
    required String path,
    required String filename,
  }) async {
    return await _channel.invokeMethod<bool>('saveFile', {
          'path': path,
          'filename': filename,
        }) ??
        false;
  }
}
