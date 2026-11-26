const notifyDeliveryStates = ['running', 'succeeded', 'failed', 'unknown'];
const notifyDeliveryCodes = [
  '',
  'accepted',
  'invalid_config',
  'upstream_rejected',
  'invalid_response',
  'network_error',
  'timeout',
  'response_limit',
  'redirect',
  'start_failed',
  'interrupted',
];

String notifyDeliveryLabel(String status) => switch (status) {
  'running' => '发送中',
  'succeeded' => '上游已受理',
  'failed' => '发送失败',
  'missing' => '回执不存在，结果未知',
  _ => '结果未知',
};

String notifyDeliveryMessage(String code) => switch (code) {
  'accepted' => '上游已受理，不代表接收端已读',
  'invalid_config' => '渠道配置不完整，未启动发送',
  'start_failed' => '工作线程未启动，未发送',
  'response_limit' => '上游响应超过限制，投递结果未知',
  'redirect' => '上游返回重定向，未继续请求，投递结果未知',
  'timeout' => '等待响应超时，可能已经发送，请核对接收端',
  '' => '',
  _ => '投递结果无法确认，请核对接收端后再决定是否重试',
};

class NotifyDeliveryRequest {
  const NotifyDeliveryRequest({
    required this.id,
    required this.status,
    required this.active,
    required this.historical,
    this.deliveryId = '',
    this.itemId = '',
    this.attempt = 0,
    this.currentAttempt,
    this.code = '',
    this.historyAvailable = false,
    this.currentMatches = false,
  });
  final String id, status, deliveryId, itemId, code;
  final bool active, historical, historyAvailable, currentMatches;
  final int attempt;
  final int? currentAttempt;
  bool get unresolved => status == 'missing' || status == 'unknown';

  factory NotifyDeliveryRequest.parse(Object? raw, String id) {
    final data = _map(raw);
    final row = _map(data['request']);
    if (data['ok'] != true ||
        row['request_id'] != id ||
        !_requestId.hasMatch(id) ||
        ![...notifyDeliveryStates, 'missing'].contains(row['status']) ||
        row['active'] is! bool ||
        row['historical'] is! bool) {
      throw const FormatException('通知投递回执无效');
    }
    if (row['status'] == 'missing') {
      if (row['active'] != false || row['historical'] != false) {
        throw const FormatException('通知缺失回执状态无效');
      }
      return NotifyDeliveryRequest(
        id: id,
        status: 'missing',
        active: false,
        historical: false,
      );
    }
    if (!notifyDeliveryCodes.contains(row['code']) ||
        !const ['test', 'retry'].contains(row['kind']) ||
        row['history_available'] is! bool ||
        row['current_matches'] is! bool ||
        (row['current_attempt'] != null &&
            !_validAttempt(row['current_attempt'])) ||
        !_validAttempt(row['attempt']) ||
        (row['active'] == true && row['status'] != 'running') ||
        (row['status'] == 'running' && row['active'] != true) ||
        (row['status'] == 'succeeded' &&
            (row['code'] != 'accepted' || row['historical'] != true)) ||
        (row['status'] == 'failed' &&
            !const ['invalid_config', 'start_failed'].contains(row['code']))) {
      throw const FormatException('通知投递结果不一致');
    }
    return NotifyDeliveryRequest(
      id: id,
      status: row['status'] as String,
      active: row['active'] as bool,
      historical: row['historical'] as bool,
      code: row['code'] as String,
      deliveryId: _text(row['delivery_id'], 200),
      itemId: _text(row['item_id'], 200),
      attempt: row['attempt'] as int,
      currentAttempt: row['current_attempt'] as int?,
      historyAvailable: row['history_available'] as bool,
      currentMatches: row['current_matches'] as bool,
    );
  }
}

class NotifyDelivery {
  const NotifyDelivery({
    required this.id,
    required this.itemId,
    required this.name,
    required this.channel,
    required this.status,
    required this.version,
    required this.attempt,
    required this.retryAllowed,
    required this.truncated,
    required this.createdAt,
    required this.updatedAt,
    this.itemVersion = '',
    this.itemEnabled = false,
    this.itemExists = false,
    this.title,
    this.content,
  });
  final String id,
      itemId,
      name,
      channel,
      status,
      version,
      createdAt,
      updatedAt,
      itemVersion;
  final int attempt;
  final bool retryAllowed, truncated, itemEnabled, itemExists;
  final String? title, content;

  factory NotifyDelivery.parse(
    Object? raw, {
    bool detail = false,
    bool reveal = false,
  }) {
    final row = _map(raw);
    if (!notifyDeliveryStates.contains(row['status']) ||
        !_validAttempt(row['attempt']) ||
        row['retry_allowed'] is! bool ||
        row['content_truncated'] is! bool ||
        !const [
          'manual',
          'test',
          'task',
          'system',
          'other',
        ].contains(row['source']) ||
        (row['retry_allowed'] == true &&
            !const ['failed', 'unknown'].contains(row['status'])) ||
        (!reveal && (row.containsKey('title') || row.containsKey('content'))) ||
        row.containsKey('message') ||
        row.containsKey('config')) {
      throw const FormatException('通知投递记录无效');
    }
    if (detail &&
        (row['item_exists'] is! bool || row['item_enabled'] is! bool)) {
      throw const FormatException('通知渠道状态无效');
    }
    final itemVersion = detail
        ? _text(row['item_version'], 64, empty: true)
        : '';
    if (itemVersion.isNotEmpty && !_version.hasMatch(itemVersion)) {
      throw const FormatException('通知渠道版本无效');
    }
    final version = _text(row['version'], 64);
    if (!_version.hasMatch(version)) {
      throw const FormatException('投递版本无效');
    }
    return NotifyDelivery(
      id: _text(row['id'], 200),
      itemId: _text(row['item_id'], 200, empty: true),
      name: _text(row['item_name'], 200, empty: true),
      channel: _text(row['channel'], 50, empty: true),
      status: row['status'] as String,
      version: version,
      attempt: row['attempt'] as int,
      retryAllowed: row['retry_allowed'] as bool,
      truncated: row['content_truncated'] as bool,
      createdAt: _text(row['created_at'], 32, empty: true),
      updatedAt: _text(row['updated_at'], 32, empty: true),
      itemVersion: itemVersion,
      itemEnabled: detail && row['item_enabled'] == true,
      itemExists: detail && row['item_exists'] == true,
      title: reveal
          ? _text(row['title'], 1000, empty: true, multiline: true)
          : null,
      content: reveal
          ? _text(row['content'], 12000, empty: true, multiline: true)
          : null,
    );
  }
}

class NotifyDeliveryPage {
  const NotifyDeliveryPage(this.items, this.page, this.pages, this.total);
  final List<NotifyDelivery> items;
  final int page, pages, total;
  factory NotifyDeliveryPage.parse(Object? raw) {
    final row = _map(raw);
    if (row['ok'] != true ||
        row['items'] is! List ||
        (row['items'] as List).length > 100 ||
        row['page'] is! int ||
        row['pages'] is! int ||
        row['total'] is! int ||
        (row['page'] as int) < 1 ||
        (row['pages'] as int) < (row['page'] as int) ||
        (row['total'] as int) < (row['items'] as List).length) {
      throw const FormatException('通知历史分页无效');
    }
    return NotifyDeliveryPage(
      List.unmodifiable(
        (row['items'] as List).map((value) => NotifyDelivery.parse(value)),
      ),
      row['page'] as int,
      row['pages'] as int,
      row['total'] as int,
    );
  }
}

final _requestId = RegExp(r'^[a-f0-9]{32}$');
final _version = RegExp(r'^[a-f0-9]{64}$');
bool _validAttempt(Object? value) =>
    value is int && value >= 1 && value < 1000000000;
Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('通知投递响应必须为对象');
  }
  return value;
}

String _text(
  Object? value,
  int limit, {
  bool empty = false,
  bool multiline = false,
}) {
  if (value is! String ||
      (!empty && value.isEmpty) ||
      value.length > limit ||
      value.runes.any(
        (r) => r < 32 && !(multiline && const [9, 10, 13].contains(r)),
      )) {
    throw const FormatException('通知投递文本无效');
  }
  return value;
}
