const panelProxyTypes = [
  'http',
  'https',
  'socks4',
  'socks5',
  'socks5h',
  'github',
];

class PanelProxyRecovery {
  String? requestId;
  final Set<String> checkIds = {};
}

class PanelProxyReference {
  const PanelProxyReference(this.id, this.name);
  final String id;
  final String name;

  factory PanelProxyReference.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_validText(value['id'], 200, required: true) ||
        !_validText(value['name'], 200)) {
      throw const FormatException('代理任务引用格式无效');
    }
    return PanelProxyReference(value['id'] as String, value['name'] as String);
  }
}

class PanelProxy {
  const PanelProxy({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    required this.url,
    required this.enabled,
    required this.version,
    required this.usernameConfigured,
    required this.passwordConfigured,
    required this.hostRequiresReplace,
    required this.urlRequiresReplace,
    required this.referenceCount,
    this.references = const [],
  });

  final String id, name, type, host, port, url, version;
  final bool enabled, usernameConfigured, passwordConfigured;
  final bool hostRequiresReplace, urlRequiresReplace;
  final int referenceCount;
  final List<PanelProxyReference> references;

  String get address => type == 'github'
      ? (urlRequiresReplace ? '地址需要重新设置' : url)
      : (hostRequiresReplace ? '地址需要重新设置' : '$host:$port');

  Map<String, Object?> get settings => {
    'name': name,
    'type': type,
    'host': host,
    'port': port,
    'url': url,
    'enabled': enabled,
  };

  factory PanelProxy.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_validText(value['id'], 200, required: true) ||
        !_validText(value['name'], 200) ||
        !panelProxyTypes.contains(value['type']) ||
        !_validText(value['host'], 255) ||
        !_validText(value['port'], 5) ||
        !_validText(value['url'], 4096) ||
        !_revision(value['version']) ||
        value['reference_count'] is! int ||
        (value['reference_count'] as int) < 0 ||
        const [
          'enabled',
          'username_configured',
          'password_configured',
          'host_requires_replace',
          'url_requires_replace',
        ].any((key) => value[key] is! bool) ||
        value.containsKey('username') ||
        value.containsKey('password')) {
      throw const FormatException('代理设置响应格式无效');
    }
    final url = value['url'] as String;
    final uri = url.isEmpty ? null : Uri.tryParse(url);
    if ((url.isNotEmpty &&
            (uri == null ||
                !const ['http', 'https'].contains(uri.scheme) ||
                uri.host.isEmpty ||
                uri.userInfo.isNotEmpty ||
                uri.hasQuery ||
                uri.hasFragment)) ||
        RegExp(r'[/@?#\\\s]').hasMatch(value['host'] as String) ||
        (value['url_requires_replace'] == true && url.isNotEmpty) ||
        (value['host_requires_replace'] == true &&
            (value['host'] as String).isNotEmpty)) {
      throw const FormatException('代理地址响应包含无效或敏感内容');
    }
    final raw = value['references'] ?? const [];
    if (raw is! List ||
        raw.length > 50 ||
        raw.length > (value['reference_count'] as int)) {
      throw const FormatException('代理引用数量无效');
    }
    return PanelProxy(
      id: value['id'] as String,
      name: value['name'] as String,
      type: value['type'] as String,
      host: value['host'] as String,
      port: value['port'] as String,
      url: url,
      version: value['version'] as String,
      enabled: value['enabled'] as bool,
      usernameConfigured: value['username_configured'] as bool,
      passwordConfigured: value['password_configured'] as bool,
      hostRequiresReplace: value['host_requires_replace'] as bool,
      urlRequiresReplace: value['url_requires_replace'] as bool,
      referenceCount: value['reference_count'] as int,
      references: List.unmodifiable(raw.map(PanelProxyReference.fromJson)),
    );
  }
}

class PanelProxyPage {
  const PanelProxyPage(this.items, this.page, this.pages, this.total);
  final List<PanelProxy> items;
  final int page, pages, total;

  factory PanelProxyPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        (value['items'] as List).length > 100 ||
        value['page'] is! int ||
        value['pages'] is! int ||
        value['total'] is! int ||
        (value['page'] as int) < 1 ||
        (value['pages'] as int) < (value['page'] as int) ||
        (value['total'] as int) < (value['items'] as List).length) {
      throw const FormatException('代理列表响应格式无效');
    }
    return PanelProxyPage(
      List.unmodifiable((value['items'] as List).map(PanelProxy.fromJson)),
      value['page'] as int,
      value['pages'] as int,
      value['total'] as int,
    );
  }
}

class PanelProxyResult {
  const PanelProxyResult({
    required this.requestId,
    required this.saved,
    required this.state,
    required this.proxyId,
    this.currentMatches = false,
    this.confirmRequired = false,
    this.retryAllowed = false,
  });
  final String requestId, state, proxyId;
  final bool? saved;
  final bool currentMatches, confirmRequired, retryAllowed;

  factory PanelProxyResult.fromJson(
    Object? value, {
    required String expectedId,
    bool query = false,
  }) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['request_id'] != expectedId ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(expectedId) ||
        !value.containsKey('saved') ||
        !(value['saved'] == null || value['saved'] is bool) ||
        (value['saved'] != null &&
            !_validText(value['proxy_id'], 200, required: true)) ||
        (query &&
            (!const [
                  'missing',
                  'unknown',
                  'prepared',
                  'failed',
                  'completed',
                ].contains(value['state']) ||
                value['retry_allowed'] is! bool ||
                value['resolved'] is! bool ||
                value['resolved'] != (value['saved'] != null) ||
                (value['state'] == 'completed' && value['saved'] != true) ||
                (const ['missing', 'unknown'].contains(value['state']) &&
                    value['saved'] != null) ||
                (const ['prepared', 'failed'].contains(value['state']) &&
                    value['saved'] != false) ||
                (value['saved'] != null &&
                    (value['current_matches'] is! bool ||
                        value['confirm_required'] is! bool)) ||
                (value['retry_allowed'] == true && value['saved'] != false)))) {
      throw const FormatException('代理操作响应格式无效');
    }
    return PanelProxyResult(
      requestId: expectedId,
      saved: value['saved'] as bool?,
      state: value['state'] as String? ?? '',
      proxyId: value['proxy_id'] as String? ?? '',
      currentMatches: value['current_matches'] == true,
      confirmRequired: value['confirm_required'] == true,
      retryAllowed: value['retry_allowed'] == true,
    );
  }
}

bool _validText(Object? value, int limit, {bool required = false}) =>
    value is String &&
    value.length <= limit &&
    (!required || value.isNotEmpty) &&
    !RegExp(r'[\x00-\x1f]').hasMatch(value);
bool _revision(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
