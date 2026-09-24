class PanelServer {
  const PanelServer({
    required this.name,
    required this.url,
    this.isFavorite = false,
  });

  final String name;
  final String url;
  final bool isFavorite;

  static PanelServer? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final name = value['name'];
    final url = normalizePanelUrl(value['url']?.toString() ?? '');
    if (name is! String || name.trim().isEmpty || url == null) return null;
    return PanelServer(
      name: name.trim(),
      url: url,
      isFavorite: value['isFavorite'] == true,
    );
  }

  Map<String, Object> toJson() => {
    'name': name,
    'url': url,
    'isFavorite': isFavorite,
  };
}

String? normalizePanelUrl(String input) {
  var value = input.trim();
  if (value.isEmpty) return null;
  if (!value.contains('://')) {
    final candidate = Uri.tryParse('http://$value');
    final host = candidate?.host.toLowerCase() ?? '';
    final isLocal =
        host == 'localhost' ||
        host.endsWith('.local') ||
        host == '::1' ||
        host == '0.0.0.0' ||
        host.startsWith('127.') ||
        host.startsWith('10.') ||
        host.startsWith('192.168.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host) ||
        RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(host) ||
        host.contains(':');
    value = '${isLocal ? 'http' : 'https'}://$value';
  }

  final uri = Uri.tryParse(value);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }

  var path = uri.path;
  while (path.endsWith('/') && path.length > 1) {
    path = path.substring(0, path.length - 1);
  }
  return uri.replace(path: path).toString().replaceFirst(RegExp(r'/+$'), '');
}
