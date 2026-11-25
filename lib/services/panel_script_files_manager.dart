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

  Future<PanelScriptDeletePreview> previewDelete(String path) async {
    _requireRelativePath(path);
    final uri = Uri(
      path: '/api/scripts/delete/preview',
      queryParameters: {'path': path},
    );
    final payload = await _api.getJson(uri.toString());
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本删除预览响应格式无效');
      }
      return PanelScriptDeletePreview.fromJson(payload['preview']);
    } on FormatException catch (error) {
      throw PanelApiException(
        error.message,
        path: '/api/scripts/delete/preview',
      );
    }
  }

  Future<void> deleteFile({
    required String path,
    required String revision,
    required bool confirmReferences,
  }) async {
    _requireRelativePath(path);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(revision)) {
      throw ArgumentError('脚本删除确认版本无效');
    }
    final payload = await _api.deleteJson('/api/scripts/file', {
      'path': path,
      'revision': revision,
      'confirm_references': confirmReferences,
    });
    if (payload is! Map<String, dynamic> ||
        payload['ok'] != true ||
        payload['deleted'] != true ||
        payload['path'] != path) {
      throw const PanelApiException('脚本删除响应格式无效');
    }
  }

  Future<PanelScriptRenamePreview> previewRename({
    required String path,
    required String newName,
  }) async {
    _requireRelativePath(path);
    _requireName(newName);
    final uri = Uri(
      path: '/api/scripts/rename/preview',
      queryParameters: {'path': path, 'new_name': newName},
    );
    final payload = await _api.getJson(uri.toString());
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本改名预览响应格式无效');
      }
      return PanelScriptRenamePreview.fromJson(payload['preview']);
    } on FormatException catch (error) {
      throw PanelApiException(
        error.message,
        path: '/api/scripts/rename/preview',
      );
    }
  }

  Future<PanelScriptRenameOperation> renameFile({
    required String path,
    required String newName,
    required String revision,
    required String operationId,
    required List<PanelScriptRenameReferenceUpdate> references,
  }) async {
    _requireRelativePath(path);
    _requireName(newName);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(revision) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(operationId) ||
        references.length > 200) {
      throw ArgumentError('脚本改名确认信息无效');
    }
    final payload = await _api.postJson('/api/scripts/rename', {
      'path': path,
      'new_name': newName,
      'revision': revision,
      'operation_id': operationId,
      'references': references
          .map(
            (reference) => {
              'task_id': reference.taskId,
              'command': reference.command,
              'config_path': reference.configPath,
            },
          )
          .toList(growable: false),
    });
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本改名响应格式无效');
      }
      return PanelScriptRenameOperation.fromJson(payload['operation']);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/scripts/rename');
    }
  }

  Future<PanelScriptRenameOperation> fetchRenameOperation(
    String operationId,
  ) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(operationId)) {
      throw ArgumentError.value(operationId, 'operationId');
    }
    final payload = await _api.getJson('/api/scripts/rename/$operationId');
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本改名状态响应格式无效');
      }
      return PanelScriptRenameOperation.fromJson(payload['operation']);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/scripts/rename');
    }
  }

  Future<PanelScriptRenameOperation> recoverRename({
    required String operationId,
    required String action,
  }) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(operationId) ||
        !const {'resume', 'rollback'}.contains(action)) {
      throw ArgumentError('脚本改名恢复参数无效');
    }
    final payload = await _api.postJson(
      '/api/scripts/rename/$operationId/recovery',
      {'action': action},
    );
    try {
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        throw const FormatException('脚本改名恢复响应格式无效');
      }
      return PanelScriptRenameOperation.fromJson(payload['operation']);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: '/api/scripts/rename');
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

  static void _requireName(String name) {
    if (name.trim().isEmpty ||
        name != name.trim() ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        name.endsWith('.') ||
        name.endsWith(' ') ||
        name.contains(':')) {
      throw ArgumentError.value(name, 'name', '脚本名称无效');
    }
  }
}

class PanelScriptRenameReferenceUpdate {
  const PanelScriptRenameReferenceUpdate({
    required this.taskId,
    required this.command,
    required this.configPath,
  });

  final String taskId;
  final String command;
  final String configPath;
}
