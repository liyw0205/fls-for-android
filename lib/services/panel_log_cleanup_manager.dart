import 'dart:convert';
import 'dart:math';

import '../models/panel_log_cleanup.dart';
import '../models/panel_records.dart';
import 'panel_api_client.dart';

class PanelLogCleanupOperation {
  PanelLogCleanupOperation._(this.requestId, this.preview);
  final String requestId;
  final PanelLogCleanupPreview preview;
  PanelLogCleanupResult? _result;
  bool _submitted = false;
  int _generation = 0;
  PanelLogCleanupResult? get result => _result;
}

class PanelLogCleanupRecovery {
  PanelLogCleanupRecovery(this.panelId);
  final String panelId;
  final Map<String, PanelLogCleanupOperation> _operations = {};

  List<PanelLogCleanupOperation> get operations =>
      List.unmodifiable(_operations.values.toList().reversed);

  void clearCompleted() => _operations.removeWhere(
    (_, operation) => operation.result?.status == 'completed',
  );
}

class PanelLogCleanupManager {
  PanelLogCleanupManager(
    this._api, {
    required this.panelId,
    required this.panelLabel,
    required this.recovery,
  }) {
    if (recovery.panelId != panelId) throw ArgumentError('日志清理记录不属于当前面板');
  }

  final PanelApiClient _api;
  final String panelId;
  final String panelLabel;
  final PanelLogCleanupRecovery recovery;
  final Map<String, PanelLogCleanupPreview> _previews = {};
  PanelLogCleanupCapabilities? _capabilities;

  Future<PanelLogCleanupCapabilities> capabilities() async {
    const path = '/api/logs/cleanup/capabilities';
    try {
      return _capabilities = PanelLogCleanupCapabilities.fromJson(
        await _api.getJson(path),
      );
    } on PanelApiException catch (error) {
      if (error.statusCode != 404) rethrow;
      return _capabilities = const PanelLogCleanupCapabilities.unsupported();
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelLogCleanupPreview> preview({
    List<PanelLogFile> files = const [],
    List<String> groups = const [],
  }) async {
    if (files.isEmpty == groups.isEmpty ||
        files.length > 200 ||
        groups.length > 20 ||
        files.any(
          (file) =>
              !validLogCleanupFilename(file.filename) ||
              utf8.encode(file.filename).length > 255 ||
              !validLogCleanupId(file.version, length: 64),
        ) ||
        files.map((file) => file.filename).toSet().length != files.length ||
        groups.any(
          (group) =>
              group.isEmpty ||
              group.trim() != group ||
              group.length > 512 ||
              RegExp(r'[\x00-\x1f]').hasMatch(group),
        ) ||
        groups.toSet().length != groups.length) {
      throw ArgumentError('日志清理选择或文件版本无效');
    }
    final limits = _capabilities ?? await capabilities();
    if (!limits.supported) throw const PanelApiException('当前面板不支持日志清理');
    if (files.length > limits.maxFiles || groups.length > limits.maxGroups) {
      throw ArgumentError('日志清理选择超过面板限制');
    }
    const path = '/api/logs/cleanup/preview';
    try {
      final preview = PanelLogCleanupPreview.fromJson(
        await _api.postJson(path, {
          if (files.isNotEmpty)
            'files': [
              for (final file in files)
                {'filename': file.filename, 'version': file.version},
            ],
          if (groups.isNotEmpty) 'groups': groups,
        }),
      );
      final expected = {for (final file in files) file.filename: file.version};
      if (preview.items.length > limits.maxFiles ||
          (files.isNotEmpty &&
              (preview.groups.isNotEmpty ||
                  preview.items.length != files.length ||
                  preview.items.any(
                    (item) => expected[item.filename] != item.version,
                  ))) ||
          (groups.isNotEmpty &&
              (preview.groups.length != groups.length ||
                  preview.groups.any((group) => !groups.contains(group))))) {
        throw const FormatException('日志预检查与所选目标不匹配');
      }
      _previews.removeWhere((_, value) => value.expired);
      if (_previews.length >= 32) _previews.remove(_previews.keys.first);
      _previews[preview.id] = preview;
      return preview;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  bool owns(PanelLogCleanupOperation operation) =>
      identical(recovery._operations[operation.requestId], operation);

  PanelLogCleanupOperation prepare(PanelLogCleanupPreview preview) {
    if (!identical(_previews[preview.id], preview) || preview.expired) {
      throw StateError('预检查已过期，请重新预检查');
    }
    if (recovery._operations.length >= 32) {
      throw StateError('当前会话清理记录已满，请先清除已完成记录');
    }
    if (recovery._operations.values.any(
      (operation) => operation.preview.id == preview.id,
    )) {
      throw StateError('该预检查已提交，请查询原请求');
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final operation = PanelLogCleanupOperation._(id, preview);
    // Retain the original identity before any network write can be accepted.
    recovery._operations[id] = operation;
    _previews.remove(preview.id);
    return operation;
  }

  Future<PanelLogCleanupResult> submit(
    PanelLogCleanupOperation operation,
  ) async {
    _owned(operation);
    if (operation._submitted) throw StateError('请查询原日志清理请求，不能重复提交');
    operation._submitted = true;
    return _result(
      operation,
      '/api/logs/cleanup',
      body: {
        'request_id': operation.requestId,
        'preview_id': operation.preview.id,
        'digest': operation.preview.digest,
      },
    );
  }

  Future<PanelLogCleanupResult> query(PanelLogCleanupOperation operation) {
    _owned(operation);
    return _result(
      operation,
      '/api/logs/cleanup/requests/${operation.requestId}',
    );
  }

  Future<PanelLogCleanupResult> reconcile(PanelLogCleanupOperation operation) {
    _owned(operation);
    return _result(
      operation,
      '/api/logs/cleanup/requests/${operation.requestId}/reconcile',
      body: const {},
    );
  }

  void _owned(PanelLogCleanupOperation operation) {
    if (!owns(operation)) throw ArgumentError('日志清理请求不属于当前面板');
  }

  Future<PanelLogCleanupResult> _result(
    PanelLogCleanupOperation operation,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final generation = ++operation._generation;
    try {
      final payload = body == null
          ? await _api.getJson(path)
          : await _api.postJson(path, body);
      final result = PanelLogCleanupResult.fromJson(
        payload,
        requestId: operation.requestId,
        preview: operation.preview,
      );
      if (generation == operation._generation) operation._result = result;
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }
}
