import '../models/panel_script_file.dart';
import 'panel_api_client.dart';

class PanelScriptFilesManager {
  const PanelScriptFilesManager(this._api);

  final PanelApiClient _api;

  Future<PanelScriptFilePage> fetchTree({
    String path = '',
    String query = '',
    int page = 1,
    int limit = 50,
  }) async {
    if (page < 1 || limit < 1 || limit > 100) {
      throw ArgumentError('脚本目录分页参数无效');
    }
    final uri = Uri(
      path: '/api/scripts/tree',
      queryParameters: {
        'path': path,
        'q': query,
        'page': '$page',
        'limit': '$limit',
      },
    );
    final payload = await _api.getJson(uri.toString());
    try {
      return PanelScriptFilePage.fromJson(payload);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/scripts/tree');
    }
  }

  Future<PanelScriptFileSnapshot> fetchFile(String path) async {
    _requireRelativePath(path);
    final uri = Uri(path: '/api/scripts/file', queryParameters: {'path': path});
    final payload = await _api.getJson(uri.toString());
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本文件响应格式无效');
      }
      return PanelScriptFileSnapshot.fromJson(payload['file']);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/scripts/file');
    }
  }

  Future<PanelScriptFileSnapshot> saveFile({
    required String path,
    required String content,
    required String revision,
  }) async {
    _requireRelativePath(path);
    final payload = await _api.putJson('/api/scripts/file', {
      'path': path,
      'content': content,
      'revision': revision,
    });
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本保存响应格式无效');
      }
      return PanelScriptFileSnapshot.fromJson(payload['file']);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/scripts/file');
    }
  }

  Future<void> createFile({
    required String path,
    required String kind,
    String content = '',
  }) async {
    _requireRelativePath(path);
    if (!const {'file', 'directory'}.contains(kind)) {
      throw ArgumentError.value(kind, 'kind');
    }
    final payload = await _api.postJson('/api/scripts/file', {
      'path': path,
      'kind': kind,
      'content': content,
    });
    if (payload is! Map<String, dynamic> ||
        payload['ok'] != true ||
        payload['path'] != path ||
        payload['kind'] != kind) {
      throw const PanelApiException('脚本创建响应格式无效');
    }
  }

  static void _requireRelativePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(path, 'path', '脚本路径无效');
    }
  }
}
