import 'dart:convert';
import 'dart:math';

import '../models/panel_global_env.dart';
import 'panel_api_client.dart';

class PanelGlobalEnvManager {
  const PanelGlobalEnvManager(this._api);
  final PanelApiClient _api;

  static String newRequestId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Future<PanelEnvPage> fetchPage({
    String query = '',
    int page = 1,
    bool sources = false,
  }) async {
    if (query.length > 200 || page < 1) throw ArgumentError('变量搜索参数无效');
    final params = Uri(
      queryParameters: {'q': query, 'page': '$page', 'limit': '50'},
    ).query;
    final path = '/api/env/${sources ? 'task-sources' : 'variables'}?$params';
    try {
      return PanelEnvPage.fromJson(await _api.getJson(path), source: sources);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelEnvContent> fetchContent({String? key}) async {
    if (key != null) _key(key);
    final path = key == null
        ? '/api/env/snapshot?reveal=1'
        : '/api/env/variable/${Uri.encodeComponent(key)}?reveal=1';
    try {
      final result = PanelEnvContent.fromJson(
        await _api.getJson(path),
        key == null ? 'env_text' : 'value',
      );
      if (utf8.encode(result.content).length >
          (key == null ? 1024 * 1024 : 64 * 1024)) {
        throw const FormatException('变量内容超过编辑限制');
      }
      return result;
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelEnvResult> status(String requestId) async {
    _id(requestId);
    final path = '/api/env/requests/$requestId';
    final value = await _api.getJson(path);
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['request_id'] != requestId ||
        !const {
          'completed',
          'pending',
          'missing',
          'unknown',
        }.contains(value['state'])) {
      throw PanelApiException('变量提交状态格式无效', path: path);
    }
    return PanelEnvResult.fromJson(value);
  }

  Future<PanelEnvResult> mutate(Map<String, Object?> input) async {
    _id(input['request_id']);
    if (!validEnvVersion(input['version'])) throw ArgumentError('变量版本无效');
    final action = input['action'];
    if (!const {
      'new',
      'edit',
      'delete',
      'replace',
      'import',
    }.contains(action)) {
      throw ArgumentError('变量操作无效');
    }
    if (action == 'new' || action == 'edit') {
      _key(input['key']);
      final value = input['value'];
      if (value is! String ||
          value.contains('\u0000') ||
          utf8.encode(value).length > 65536) {
        throw ArgumentError('变量值无效或超过 64 KiB');
      }
    }
    if (action == 'edit' || action == 'delete') _key(input['original_key']);
    if (action == 'replace' &&
        (input['env_text'] is! String ||
            utf8.encode(input['env_text'] as String).length > 1024 * 1024)) {
      throw ArgumentError('变量文本无效或超过 1 MiB');
    }
    if (action == 'import') {
      final items = input['items'];
      final sources = input['sources'];
      if (items is! List<String> ||
          items.isEmpty ||
          items.length > 200 ||
          sources is! Map<String, String> ||
          sources.length != items.length ||
          items.any((item) => !validEnvVersion(sources[item])) ||
          input['overwrite'] is! bool) {
        throw ArgumentError('任务变量选择无效或超过 200 项');
      }
    }
    const path = '/api/env/mutate';
    try {
      final value = await _api.postJson(path, input);
      if (value is! Map<String, dynamic> ||
          value['ok'] != true ||
          value['request_id'] != input['request_id'] ||
          value['saved'] != true) {
        throw const PanelApiException('变量保存结果未确认', path: path);
      }
      return PanelEnvResult.fromJson(value);
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  static void _id(Object? value) {
    if (value is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
      throw ArgumentError('变量提交标识无效');
    }
  }

  static void _key(Object? value) {
    if (value is! String ||
        value.length > 200 ||
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value)) {
      throw ArgumentError('变量名只能使用字母、数字和下划线，且不能以数字开头');
    }
  }
}
