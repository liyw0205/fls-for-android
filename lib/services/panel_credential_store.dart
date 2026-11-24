import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PanelSessionCredentials {
  const PanelSessionCredentials({
    required this.cookie,
    required this.csrfToken,
  });

  final String cookie;
  final String csrfToken;

  Map<String, String> toJson() => {'cookie': cookie, 'csrf_token': csrfToken};

  factory PanelSessionCredentials.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('面板会话格式无效');
    }
    final cookie = value['cookie'];
    final csrfToken = value['csrf_token'];
    if (cookie is! String ||
        !RegExp(r'^[A-Za-z0-9_-]+=[^;\r\n]+$').hasMatch(cookie) ||
        csrfToken is! String ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(csrfToken)) {
      throw const FormatException('面板会话凭据无效');
    }
    return PanelSessionCredentials(cookie: cookie, csrfToken: csrfToken);
  }

  @override
  String toString() => 'PanelSessionCredentials(<redacted>)';
}

abstract interface class PanelCredentialStore {
  Future<PanelSessionCredentials?> read(String panelUrl);
  Future<void> write(String panelUrl, PanelSessionCredentials credentials);
  Future<void> delete(String panelUrl);
}

class SecurePanelCredentialStore implements PanelCredentialStore {
  const SecurePanelCredentialStore({
    this.storage = const FlutterSecureStorage(),
  });

  static const _prefix = 'fls_panel_session_';
  static const _legacyTokenPrefix = 'fls_panel_token_';
  final FlutterSecureStorage storage;

  String _key(String panelUrl) =>
      '$_prefix${sha256.convert(utf8.encode(panelUrl)).toString()}';

  String _legacyKey(String panelUrl) =>
      '$_legacyTokenPrefix${sha256.convert(utf8.encode(panelUrl)).toString()}';

  @override
  Future<PanelSessionCredentials?> read(String panelUrl) async {
    final legacyToken = await storage.read(key: _legacyKey(panelUrl));
    if (legacyToken != null) {
      await storage.delete(key: _legacyKey(panelUrl));
    }

    final value = await storage.read(key: _key(panelUrl));
    if (value == null) return null;
    try {
      return PanelSessionCredentials.fromJson(jsonDecode(value));
    } on FormatException {
      await storage.delete(key: _key(panelUrl));
      return null;
    }
  }

  @override
  Future<void> write(
    String panelUrl,
    PanelSessionCredentials credentials,
  ) async {
    await storage.delete(key: _legacyKey(panelUrl));
    await storage.write(
      key: _key(panelUrl),
      value: jsonEncode(credentials.toJson()),
    );
  }

  @override
  Future<void> delete(String panelUrl) async {
    await storage.delete(key: _key(panelUrl));
    await storage.delete(key: _legacyKey(panelUrl));
  }
}
