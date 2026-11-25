import 'package:flutter/services.dart';

class LocalFileBridge {
  static const _channel = MethodChannel('top.fls/file_bridge');

  static Future<String?> pickContainer() =>
      _channel.invokeMethod<String>('pickContainer');

  static Future<PickedImportFile?> pickScriptImport() async {
    final value = await _channel.invokeMapMethod<String, String>(
      'pickScriptImport',
    );
    final uri = value?['uri'];
    final name = value?['name'];
    if (uri == null || uri.isEmpty || name == null || name.isEmpty) return null;
    return PickedImportFile(uri: uri, name: name);
  }

  static Future<bool> copyUriToPath({
    required String uri,
    required String path,
    int? maxBytes,
  }) async {
    final arguments = <String, Object>{'uri': uri, 'path': path};
    if (maxBytes != null) arguments['maxBytes'] = maxBytes;
    return await _channel.invokeMethod<bool>('copyUriToPath', arguments) ??
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

class PickedImportFile {
  const PickedImportFile({required this.uri, required this.name});

  final String uri;
  final String name;
}
