import 'dart:convert';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/models/panel_config.dart';
import 'package:fls_for_android/services/panel_config_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_test_http.dart';

const _session = PanelSessionCredentials(
  cookie: 'fls_native_session=config-session',
  csrfToken: 'config-csrf',
);
final _revision = 'a' * 64;
final _requestId = 'b' * 32;
final _applyRequestId = 'c' * 32;

Map<String, Object?> _settings() => {
  'theme': 'deepseek',
  'port': 5700,
  'online_script_source': 'https://example.invalid/index.json',
  'online_script_source_requires_reveal': false,
  'log_cleanup_minutes': 30,
  'log_max_size_mb': 10,
  'log_keep_per_task': 10,
  'task_timeout_seconds': 1800,
  'random_delay_seconds': 0,
  'task_types': {'py': true, 'sh': true},
};

Map<String, Object?> _payload() => {
  'ok': true,
  'settings': _settings(),
  'revision': _revision,
  'schema': <String, Object?>{},
  'credentials': {
    'token_configured': true,
    'token_managed_by_environment': false,
    'totp_configured': false,
    'security_verify_enabled': false,
    'security_verify_type': 'code',
  },
  'apply': {'status': 'succeeded', 'message': '', 'error_count': 0},
};

void main() {
  test(
    'malformed and secret-bearing configuration is rejected before rendering',
    () {
      for (final changes in <Map<String, Object?>>[
        {'port': true},
        {'port': '5700'},
        {'theme': 'unknown'},
        {
          'task_types': {'py': 'enabled'},
        },
        {'admin_token': 'private-token'},
      ]) {
        final payload = _payload();
        (payload['settings'] as Map).addAll(changes);
        expect(
          () => PanelConfigSettings.fromJson(payload),
          throwsFormatException,
        );
      }
      expect(
        () => PanelConfigResult.fromJson({
          'ok': true,
          'request_id': _requestId,
          'saved': null,
          'apply_status': 'succeeded',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'configuration reads use the panel session and reject secret readback',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: _session,
        client: panelMockClient((request) async {
          expect(request.url.path, '/api/config/settings');
          expect(request.headers['cookie'], _session.cookie);
          return utf8Response(jsonEncode(_payload()), 200);
        }),
      );
      addTearDown(api.close);
      final config = await PanelConfigManager(api).fetch();
      expect(config.revision, _revision);
      expect(config.tokenConfigured, true);
    },
  );

  test(
    'save and apply carry revision, request id, CSRF and recover by GET',
    () async {
      final methods = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: _session,
        client: panelMockClient((request) async {
          methods.add(request.method);
          if (request.method == 'GET') {
            return utf8Response(
              jsonEncode({
                'ok': true,
                'request_id': _applyRequestId,
                'state': 'completed',
                'saved': true,
                'apply_status': 'failed',
                'revision': _revision,
                'reauth_required': false,
              }),
              200,
            );
          }
          expect(request.headers['x-csrf-token'], _session.csrfToken);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(
            body['request_id'],
            request.url.path == '/api/config/settings'
                ? _requestId
                : _applyRequestId,
          );
          expect(body['expected_revision'], _revision);
          if (request.url.path == '/api/config/settings') {
            expect(body['settings'], {'theme': 'editorial'});
            expect(body['credentials'], isEmpty);
          }
          return utf8Response(
            jsonEncode({
              'ok': true,
              'request_id': request.url.path == '/api/config/settings'
                  ? _requestId
                  : _applyRequestId,
              'saved': true,
              'apply_status': 'failed',
              'revision': _revision,
              'reauth_required': false,
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelConfigManager(api);
      final saved = await manager.save(
        requestId: _requestId,
        revision: _revision,
        settings: {'theme': 'editorial'},
        credentials: const {},
      );
      final applied = await manager.apply(
        requestId: _applyRequestId,
        revision: _revision,
      );
      final status = await manager.status(_applyRequestId);
      expect(saved.saved, true);
      expect(applied.applyStatus, 'failed');
      expect(status.state, 'completed');
      expect(methods, ['POST', 'POST', 'GET']);
    },
  );

  test('configuration credentials are redacted from server errors', () async {
    const token = 'private-admin-token';
    const totp = 'private-totp-secret';
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: _session,
      client: panelMockClient(
        (request) async =>
            utf8Response(jsonEncode({'ok': false, 'msg': '$token $totp'}), 400),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      PanelConfigManager(api).save(
        requestId: _requestId,
        revision: _revision,
        settings: const {},
        credentials: const {
          'token_action': 'replace',
          'admin_token': token,
          'totp_action': 'replace',
          'totp_secret': totp,
        },
      ),
      throwsA(
        isA<PanelApiException>().having(
          (error) => error.message,
          'message',
          allOf(isNot(contains(token)), isNot(contains(totp))),
        ),
      ),
    );
  });
}
