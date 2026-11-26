import 'dart:math';

import '../models/panel_config.dart';
import 'panel_api_client.dart';

class PanelConfigManager {
  const PanelConfigManager(this._api);
  final PanelApiClient _api;

  static String newRequestId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Future<PanelConfigSettings> fetch({bool revealSource = false}) async {
    final path = revealSource
        ? '/api/config/settings?reveal_source=1'
        : '/api/config/settings';
    try {
      return PanelConfigSettings.fromJson(await _api.getJson(path));
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelConfigResult> save({
    required String requestId,
    required String revision,
    required Map<String, Object?> settings,
    required Map<String, Object?> credentials,
  }) => _write('/api/config/settings', {
    'request_id': requestId,
    'expected_revision': revision,
    'settings': settings,
    'credentials': credentials,
  }, requestId);

  Future<PanelConfigResult> apply({
    required String requestId,
    required String revision,
  }) => _write('/api/config/apply', {
    'request_id': requestId,
    'expected_revision': revision,
  }, requestId);

  Future<PanelConfigResult> _write(
    String path,
    Map<String, Object?> body,
    String requestId,
  ) async {
    _validateId(requestId);
    if (!RegExp(
      r'^[a-f0-9]{64}$',
    ).hasMatch(body['expected_revision'] as String)) {
      throw ArgumentError('配置版本无效');
    }
    try {
      return PanelConfigResult.fromJson(
        await _api.postJson(path, body),
        expectedId: requestId,
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<PanelConfigResult> status(String requestId) async {
    _validateId(requestId);
    final path = '/api/config/requests/$requestId';
    try {
      return PanelConfigResult.fromJson(
        await _api.getJson(path),
        expectedId: requestId,
      );
    } on FormatException catch (error) {
      throw PanelApiException(error.message, path: path);
    }
  }

  Future<String> enrollTotp() async {
    const path = '/api/config/totp/enrollment';
    final payload = await _api.postJson(path, const {});
    if (payload is! Map<String, dynamic> ||
        payload['ok'] != true ||
        payload['secret'] is! String ||
        (payload['secret'] as String).isEmpty) {
      throw const PanelApiException('TOTP 设置响应格式无效', path: path);
    }
    return payload['secret'] as String;
  }

  static void _validateId(String requestId) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId)) {
      throw ArgumentError('配置提交标识无效');
    }
  }
}
