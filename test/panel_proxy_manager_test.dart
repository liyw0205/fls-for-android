import 'dart:convert';

import 'package:fls_for_android/models/panel_proxy.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_proxy_manager.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_test_http.dart';

Map<String, Object?> proxyFixture({
  String id = 'p',
  String name = 'Alpha',
  String host = 'localhost',
  String? version,
}) => {
  'id': id,
  'name': name,
  'type': 'socks5',
  'host': host,
  'port': '1080',
  'url': '',
  'version': version ?? 'a' * 64,
  'enabled': true,
  'username_configured': true,
  'password_configured': true,
  'host_requires_replace': false,
  'url_requires_replace': false,
  'reference_count': 0,
};

Map<String, Object?> proxyPageFixture(Map<String, Object?> proxy) => {
  'ok': true,
  'items': [proxy],
  'page': 1,
  'pages': 1,
  'total': 1,
  'types': panelProxyTypes,
};

const proxySession = PanelSessionCredentials(
  cookie: 'fls_native_session=proxy-session',
  csrfToken: 'proxy-csrf',
);

void main() {
  test(
    'proxy list and detail enforce white list and redact malformed addresses',
    () {
      final proxy = PanelProxy.fromJson(proxyFixture());
      expect(proxy.address, 'localhost:1080');
      for (final changes in <Map<String, Object?>>[
        {'password': 'secret'},
        {'username': 'secret'},
        {'enabled': 1},
        {'version': 'bad'},
        {'url': 'https://user:secret@example.com/'},
        {'url': 'https://example.com/?token=secret'},
        {'host': 'user:secret@example.com'},
        {'reference_count': -1},
      ]) {
        expect(
          () => PanelProxy.fromJson({...proxyFixture(), ...changes}),
          throwsFormatException,
        );
      }
      expect(
        () => PanelProxyResult.fromJson(
          {
            'ok': true,
            'request_id': 'b' * 32,
            'saved': null,
            'resolved': false,
            'retry_allowed': true,
            'state': 'completed',
          },
          expectedId: 'b' * 32,
          query: true,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'proxy requests retain subdirectory session, CSRF and explicit credential intent',
    () async {
      final methods = <String>[];
      final id = 'b' * 32;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/fls',
        credentials: proxySession,
        client: panelMockClient((request) async {
          methods.add(request.method);
          expect(request.headers['cookie'], proxySession.cookie);
          if (request.method == 'POST') {
            expect(request.headers['x-csrf-token'], proxySession.csrfToken);
            expect(request.url.path, '/fls/api/proxy/settings');
            final body = jsonDecode(request.body) as Map;
            expect(body['credentials'], {
              'password_action': 'replace',
              'password': 'new-secret',
            });
            expect(body['settings'], {'name': 'Edited'});
            return utf8Response(
              jsonEncode({
                'ok': true,
                'request_id': id,
                'saved': true,
                'proxy_id': 'p',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/requests/$id')) {
            return utf8Response(
              jsonEncode({
                'ok': true,
                'request_id': id,
                'saved': null,
                'state': 'unknown',
                'resolved': false,
                'retry_allowed': false,
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/settings/p')) {
            return utf8Response(
              jsonEncode({'ok': true, 'proxy': proxyFixture()}),
              200,
            );
          }
          expect(request.url.queryParameters['q'], 'Alpha');
          expect(request.url.queryParameters['enabled'], '1');
          return utf8Response(
            jsonEncode(proxyPageFixture(proxyFixture())),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelProxyManager(api);
      expect((await manager.fetchPage(query: 'Alpha', enabled: true)).total, 1);
      expect((await manager.fetch('p')).usernameConfigured, true);
      final result = await manager.submit({
        'action': 'edit',
        'request_id': id,
        'proxy_id': 'p',
        'version': 'a' * 64,
        'settings': {'name': 'Edited'},
        'credentials': {'password_action': 'replace', 'password': 'new-secret'},
      });
      expect(result.saved, true);
      expect((await manager.status(id)).saved, isNull);
      expect(methods, ['GET', 'GET', 'POST', 'GET']);
    },
  );

  test(
    'proxy errors exclude current object and credentials with a base URL prefix',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/panel',
        credentials: proxySession,
        client: panelMockClient(
          (request) async => utf8Response(
            jsonEncode({
              'ok': false,
              'msg': 'private-user private-password',
              'saved': false,
              'resolved': true,
              'conflict': true,
              'current': {'password': 'another-secret'},
              'reference_count': 1,
              'references': [
                {'id': 't', 'name': 'Task', 'env': 'secret'},
              ],
            }),
            409,
          ),
        ),
      );
      addTearDown(api.close);
      try {
        await PanelProxyManager(api).submit({
          'action': 'edit',
          'request_id': 'b' * 32,
          'proxy_id': 'p',
          'version': 'a' * 64,
          'settings': <String, Object?>{},
          'credentials': {
            'username_action': 'replace',
            'username': 'private-user',
            'password_action': 'replace',
            'password': 'private-password',
          },
        });
        fail('expected conflict');
      } on PanelApiException catch (error) {
        expect(error.statusCode, 409);
        expect(error.message, isNot(contains('private-user')));
        expect(error.message, isNot(contains('private-password')));
        expect(error.data?['conflict'], true);
        expect(error.data?.containsKey('current'), false);
        expect(error.data?['references'], [
          {'id': 't', 'name': 'Task'},
        ]);
      }
    },
  );
}
