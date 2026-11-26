const proxyCheckStates = [
  'queued',
  'running',
  'succeeded',
  'partial',
  'failed',
  'unknown',
];

const _errorCodes = [
  '',
  'timeout',
  'network',
  'invalid_proxy',
  'http_status',
  'body_empty',
  'git_missing',
  'git_failed',
  'output_limit',
  'start_failed',
  'interrupted',
  'legacy_failure',
];

bool validProxyCheckId(String value) =>
    RegExp(r'^(legacy-)?[a-f0-9]{32}$').hasMatch(value);

String proxyCheckStateLabel(String value) => switch (value) {
  'queued' => '等待检测',
  'running' => '检测中',
  'succeeded' => '检测完成',
  'partial' => '部分失败',
  'failed' => '检测失败',
  _ => '结果未知',
};

String proxyCheckErrorLabel(String value) => switch (value) {
  'timeout' => '连接超时',
  'network' => '网络请求失败',
  'invalid_proxy' => '代理配置无效',
  'http_status' => '目标响应不符合检测要求',
  'body_empty' => '目标内容为空或不足',
  'git_missing' => '面板未安装 Git',
  'git_failed' => 'Git 检测失败',
  'output_limit' => 'Git 输出超过限制',
  'start_failed' => '检测未能启动',
  'interrupted' => '面板重启或作业中断，无法确认结果',
  'legacy_failure' => '旧版检测失败，详细错误已隐藏',
  _ => '',
};

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.keys.any((key) => !keys.contains(key))) {
    throw const FormatException('代理检测响应格式无效');
  }
  return value;
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.length > max ||
      value.runes.any((rune) => rune < 32)) {
    throw const FormatException('代理检测文本格式无效');
  }
  return value;
}

String _target(Object? value) {
  final text = _text(value, 4096);
  if (text == '历史目标已隐藏') return text;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      RegExp(r'\s|\\').hasMatch(text)) {
    throw const FormatException('代理检测目标格式无效');
  }
  return text;
}

int _integer(Object? value, int max) {
  if (value is! int || value < 0 || value > max) {
    throw const FormatException('代理检测数值无效');
  }
  return value;
}

bool _boolean(Object? value) {
  if (value is! bool) throw const FormatException('代理检测状态无效');
  return value;
}

class PanelProxyCheckItem {
  const PanelProxyCheckItem({
    required this.target,
    required this.mode,
    required this.status,
    required this.errorCode,
    this.reachable,
    this.httpSuccess,
    this.statusCode,
    this.elapsedMs,
  });
  final String target, mode, status, errorCode;
  final bool? reachable, httpSuccess;
  final int? statusCode, elapsedMs;

  factory PanelProxyCheckItem.fromJson(Object? value) {
    final data = _object(value, {
      'target',
      'mode',
      'status',
      'error_code',
      'reachable',
      'http_success',
      'status_code',
      'elapsed_ms',
    });
    final mode = _text(data['mode'], 20),
        status = _text(data['status'], 20),
        error = _text(data['error_code'], 30);
    if (!const [
          'http',
          'github_ping',
          'github_raw',
          'github_git',
        ].contains(mode) ||
        !const [
          'pending',
          'running',
          'succeeded',
          'failed',
          'unknown',
        ].contains(status) ||
        !_errorCodes.contains(error)) {
      throw const FormatException('代理检测分项状态无效');
    }
    final code = data['status_code'] == null
        ? null
        : _integer(data['status_code'], 599);
    if (code != null && code < 100) {
      throw const FormatException('代理检测 HTTP 状态码无效');
    }
    return PanelProxyCheckItem(
      target: _target(data['target']),
      mode: mode,
      status: status,
      errorCode: error,
      reachable: data['reachable'] == null ? null : _boolean(data['reachable']),
      httpSuccess: data['http_success'] == null
          ? null
          : _boolean(data['http_success']),
      statusCode: code,
      elapsedMs: data['elapsed_ms'] == null
          ? null
          : _integer(data['elapsed_ms'], 86400000),
    );
  }
}

class PanelProxyCheck {
  const PanelProxyCheck({
    required this.id,
    required this.requestId,
    required this.source,
    required this.proxyId,
    required this.proxyName,
    required this.proxyType,
    required this.version,
    required this.kind,
    required this.status,
    required this.errorCode,
    required this.createdAt,
    required this.updatedAt,
    required this.retryOf,
    required this.proxyExists,
    required this.currentMatches,
    required this.retryAllowed,
    required this.completed,
    required this.total,
    required this.items,
  });
  final String id,
      requestId,
      source,
      proxyId,
      proxyName,
      proxyType,
      version,
      kind,
      status,
      errorCode,
      createdAt,
      updatedAt,
      retryOf;
  final bool proxyExists, currentMatches, retryAllowed;
  final int completed, total;
  final List<PanelProxyCheckItem> items;
  bool get active => status == 'queued' || status == 'running';

  factory PanelProxyCheck.fromJson(Object? value) {
    final data = _object(value, {
      'id',
      'request_id',
      'source',
      'proxy_id',
      'proxy_name',
      'proxy_type',
      'version',
      'kind',
      'targets',
      'items',
      'status',
      'error_code',
      'created_at',
      'updated_at',
      'retry_of',
      'proxy_exists',
      'current_matches',
      'retry_allowed',
      'completed',
      'total',
    });
    final id = _text(data['id'], 39), requestId = _text(data['request_id'], 32);
    final source = _text(data['source'], 10),
        version = _text(data['version'], 64);
    final kind = _text(data['kind'], 10),
        status = _text(data['status'], 20),
        error = _text(data['error_code'], 30);
    final retryOf = _text(data['retry_of'], 39);
    if (!validProxyCheckId(id) ||
        !const ['saved', 'draft', 'legacy'].contains(source) ||
        (source == 'legacy'
            ? !id.startsWith('legacy-') || requestId.isNotEmpty
            : id != requestId) ||
        (version.isNotEmpty && !RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) ||
        !const ['test', 'quality'].contains(kind) ||
        !proxyCheckStates.contains(status) ||
        !_errorCodes.contains(error) ||
        (retryOf.isNotEmpty && !validProxyCheckId(retryOf))) {
      throw const FormatException('代理检测标识或状态无效');
    }
    final items = data['items'], targets = data['targets'];
    if (items is! List ||
        items.length > 8 ||
        targets is! List ||
        targets.length > 5) {
      throw const FormatException('代理检测分项数量无效');
    }
    for (final target in targets) {
      _target(target);
    }
    final parsed = items
        .map(PanelProxyCheckItem.fromJson)
        .toList(growable: false);
    final total = _integer(data['total'], 8),
        completed = _integer(data['completed'], 8);
    if (total != parsed.length ||
        completed !=
            parsed
                .where(
                  (item) => const ['succeeded', 'failed'].contains(item.status),
                )
                .length) {
      throw const FormatException('代理检测进度不匹配');
    }
    return PanelProxyCheck(
      id: id,
      requestId: requestId,
      source: source,
      proxyId: _text(data['proxy_id'], 200),
      proxyName: _text(data['proxy_name'], 200),
      proxyType: _text(data['proxy_type'], 20),
      version: version,
      kind: kind,
      status: status,
      errorCode: error,
      createdAt: _text(data['created_at'], 19),
      updatedAt: _text(data['updated_at'], 19),
      retryOf: retryOf,
      proxyExists: _boolean(data['proxy_exists']),
      currentMatches: _boolean(data['current_matches']),
      retryAllowed: _boolean(data['retry_allowed']),
      completed: completed,
      total: total,
      items: parsed,
    );
  }
}

class PanelProxyCheckPage {
  const PanelProxyCheckPage(this.items, this.page, this.pages, this.total);
  final List<PanelProxyCheck> items;
  final int page, pages, total;

  factory PanelProxyCheckPage.fromJson(Object? value) {
    final data = _object(value, {'ok', 'items', 'page', 'pages', 'total'});
    if (data['ok'] != true ||
        data['items'] is! List ||
        (data['items'] as List).length > 100) {
      throw const FormatException('代理检测历史格式无效');
    }
    final page = _integer(data['page'], 1000000),
        pages = _integer(data['pages'], 1000000),
        total = _integer(data['total'], 1000000);
    if (page < 1 || pages < page) throw const FormatException('代理检测分页无效');
    return PanelProxyCheckPage(
      (data['items'] as List)
          .map(PanelProxyCheck.fromJson)
          .toList(growable: false),
      page,
      pages,
      total,
    );
  }
}
