import 'dart:math';

import '../models/panel_notify.dart';
import 'panel_api_client.dart';

class PanelNotifyManager {
  const PanelNotifyManager(this._api);
  final PanelApiClient _api;
  static String newRequestId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  Future<T> _decode<T>(
    String path,
    Future<Object?> Function() request,
    T Function(Object?) parse,
  ) async {
    try {
      return parse(await request());
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<List<NotifyChannel>> schema() {
    const path = '/api/notify/settings/schema';
    return _decode(path, () => _api.getJson(path), NotifyChannel.schema);
  }

  Future<PanelNotifyPage> fetchPage({
    String query = '',
    String channel = '',
    String enabled = '',
    int page = 1,
  }) {
    final path = Uri(
      path: '/api/notify/settings',
      queryParameters: {
        'q': query,
        'channel': channel,
        'enabled': enabled,
        'page': '$page',
        'limit': '50',
      },
    ).toString();
    return _decode(path, () => _api.getJson(path), PanelNotifyPage.parse);
  }

  Future<PanelNotifyItem> fetch(String id) {
    final path = '/api/notify/settings/${Uri.encodeComponent(id)}';
    return _decode(path, () => _api.getJson(path), (value) {
      if (value is! Map<String, dynamic> || value['ok'] != true) {
        throw const FormatException('通知详情响应无效');
      }
      final item = PanelNotifyItem.parse(value['item'], detail: true);
      if (item.id != id) throw const FormatException('通知渠道标识不匹配');
      return item;
    });
  }

  Future<NotifyDefaults> defaults() {
    const path = '/api/notify/settings/defaults';
    return _decode(path, () => _api.getJson(path), NotifyDefaults.parse);
  }

  Future<NotifyResult> submit(Map<String, Object?> body) {
    final id = body['request_id'];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw ArgumentError('通知提交标识无效');
    }
    const path = '/api/notify/settings';
    return _decode(
      path,
      () => _api.postJson(path, body),
      (value) => NotifyResult.parse(value, id),
    );
  }

  Future<NotifyResult> status(String id) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw ArgumentError('通知提交标识无效');
    }
    final path = '/api/notify/requests/$id';
    return _decode(
      path,
      () => _api.getJson(path),
      (value) => NotifyResult.parse(value, id, query: true),
    );
  }
}
