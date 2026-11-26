import 'dart:math';

import '../models/panel_notify.dart';
import '../models/panel_notify_delivery.dart';
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

  Future<NotifyDeliveryPage> deliveryHistory({
    int page = 1,
    String status = '',
    String channel = '',
    String itemId = '',
  }) {
    final path = Uri(
      path: '/api/notify/deliveries',
      queryParameters: {
        'page': '$page',
        'limit': '25',
        'status': status,
        'channel': channel,
        'item_id': itemId,
      },
    ).toString();
    return _decode(path, () => _api.getJson(path), NotifyDeliveryPage.parse);
  }

  Future<NotifyDelivery> delivery(String id, {bool reveal = false}) {
    final path =
        '/api/notify/deliveries/${Uri.encodeComponent(id)}${reveal ? '?reveal=1' : ''}';
    return _decode(path, () => _api.getJson(path), (value) {
      if (value is! Map<String, dynamic> || value['ok'] != true) {
        throw const FormatException('通知投递详情无效');
      }
      final item = NotifyDelivery.parse(
        value['item'],
        detail: true,
        reveal: reveal,
      );
      if (item.id != id) throw const FormatException('通知投递标识不匹配');
      return item;
    });
  }

  Future<NotifyDeliveryRequest> sendTest(
    PanelNotifyItem item,
    String requestId,
  ) {
    return _deliveryPost('/api/notify/deliveries/test', {
      'request_id': requestId,
      'item_id': item.id,
      'item_version': item.version,
    }, requestId);
  }

  Future<NotifyDeliveryRequest> retryDelivery(
    NotifyDelivery delivery,
    PanelNotifyItem item,
    String requestId, {
    required bool confirmTruncated,
  }) {
    return _deliveryPost(
      '/api/notify/deliveries/${Uri.encodeComponent(delivery.id)}/retry',
      {
        'request_id': requestId,
        'item_id': item.id,
        'item_version': item.version,
        'version': delivery.version,
        'expected_attempt': delivery.attempt,
        'confirm_truncated': confirmTruncated,
      },
      requestId,
    );
  }

  Future<NotifyDeliveryRequest> _deliveryPost(
    String path,
    Map<String, Object?> body,
    String id,
  ) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw ArgumentError('通知投递提交标识无效');
    }
    return _decode(
      path,
      () => _api.postJson(path, body),
      (value) => NotifyDeliveryRequest.parse(value, id),
    );
  }

  Future<NotifyDeliveryRequest> deliveryStatus(String id) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw ArgumentError('通知投递提交标识无效');
    }
    final path = '/api/notify/delivery-requests/$id';
    return _decode(
      path,
      () => _api.getJson(path),
      (value) => NotifyDeliveryRequest.parse(value, id),
    );
  }
}
