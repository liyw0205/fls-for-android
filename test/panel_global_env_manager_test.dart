import 'dart:convert';

import 'package:fls_for_android/models/panel_global_env.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_global_env_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_test_http.dart';

void main() {
  const session = PanelSessionCredentials(
    cookie: 'fls_native_session=env-session',
    csrfToken: 'env-csrf',
  );
  final version = 'a' * 64;
  final requestId = 'b' * 32;

  test(
    'paged reads and explicit content reveal share the panel session',
    () async {
      final calls = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example/sub',
        credentials: session,
        client: panelMockClient((request) async {
          calls.add(request.url.path);
          expect(request.headers['cookie'], session.cookie);
          expect(request.method, 'GET');
          if (request.url.path.endsWith('/variables') ||
              request.url.path.endsWith('/task-sources')) {
            expect(request.url.queryParameters['q'], 'a & b');
            expect(request.url.queryParameters['page'], '2');
            expect(request.url.queryParameters['limit'], '50');
            return utf8Response(
              jsonEncode({
                'ok': true,
                'items': [],
                'version': version,
                'page': 2,
                'pages': 3,
                'total': 101,
              }),
              200,
            );
          }
          expect(request.url.queryParameters['reveal'], '1');
          return utf8Response(
            jsonEncode({
              'ok': true,
              'version': version,
              if (request.url.path.endsWith('/snapshot'))
                'env_text': 'A="secret"'
              else
                'value': 'secret',
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelGlobalEnvManager(api);
      expect((await manager.fetchPage(query: 'a & b', page: 2)).page, 2);
      expect(
        (await manager.fetchPage(query: 'a & b', page: 2, sources: true)).total,
        101,
      );
      expect((await manager.fetchContent(key: 'TOKEN')).content, 'secret');
      expect((await manager.fetchContent()).content, 'A="secret"');
      expect(calls, everyElement(startsWith('/sub/api/env/')));
    },
  );

  test(
    'writes carry exact revisions, source stamps, csrf and request ID',
    () async {
      final actions = <String>[];
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/env/mutate');
          expect(request.headers['x-csrf-token'], session.csrfToken);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['version'], version);
          expect(body['request_id'], requestId);
          actions.add(body['action'] as String);
          if (body['action'] == 'import') {
            expect(body['sources'], {'t::KEY': version});
            expect(body['overwrite'], false);
          }
          return utf8Response(
            jsonEncode({
              'ok': true,
              'request_id': requestId,
              'saved': true,
              'resolved': true,
              'changed_count': 1,
              'skipped_count': 2,
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final manager = PanelGlobalEnvManager(api);
      for (final body in <Map<String, Object?>>[
        {'action': 'new', 'key': 'A', 'value': ''},
        {
          'action': 'edit',
          'original_key': 'A',
          'key': 'B',
          'value': 'line\nnext',
        },
        {'action': 'delete', 'original_key': 'B'},
        {'action': 'replace', 'env_text': 'A="x\\ny"'},
        {
          'action': 'import',
          'items': ['t::KEY'],
          'sources': {'t::KEY': version},
          'overwrite': false,
        },
      ]) {
        final result = await manager.mutate({
          ...body,
          'version': version,
          'request_id': requestId,
        });
        expect(result.saved, true);
        expect(result.skipped, 2);
      }
      expect(actions, ['new', 'edit', 'delete', 'replace', 'import']);
    },
  );

  test(
    'conflict and saved-on-error metadata exclude all current secrets',
    () async {
      var status = 409;
      final api = PanelApiClient(
        baseUrl: 'https://panel.example',
        credentials: session,
        client: panelMockClient(
          (request) async => utf8Response(
            jsonEncode({
              'ok': false,
              'request_id': requestId,
              'saved': status == 503,
              'resolved': true,
              'conflict': true,
              'confirm_required': false,
              'changed_count': 1,
              'msg': '变量已变化',
              'current': {'TOKEN': 'must-not-leak'},
              'env_text': 'TOKEN=must-not-leak',
            }),
            status,
          ),
        ),
      );
      addTearDown(api.close);
      final manager = PanelGlobalEnvManager(api);
      final data = {
        'action': 'edit',
        'original_key': 'A',
        'key': 'A',
        'value': 'draft',
        'version': version,
        'request_id': requestId,
      };
      try {
        await manager.mutate(data);
        fail('expected conflict');
      } on PanelApiException catch (error) {
        expect(error.statusCode, 409);
        expect(error.data?['conflict'], true);
        expect(error.data?['resolved'], true);
        expect(error.data.toString(), isNot(contains('must-not-leak')));
      }
      status = 503;
      await expectLater(
        manager.mutate(data),
        throwsA(
          isA<PanelApiException>().having(
            (error) => error.data?['saved'],
            'saved',
            true,
          ),
        ),
      );
    },
  );

  test('read-only result recovery never resubmits a mutation', () async {
    final states = ['missing', 'pending', 'unknown', 'completed'];
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      credentials: session,
      client: panelMockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/env/requests/$requestId');
        final state = states.removeAt(0);
        return utf8Response(
          jsonEncode({
            'ok': true,
            'request_id': requestId,
            'state': state,
            'saved': state == 'completed'
                ? true
                : state == 'pending'
                ? false
                : null,
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final manager = PanelGlobalEnvManager(api);
    expect((await manager.status(requestId)).saved, isNull);
    expect((await manager.status(requestId)).saved, false);
    expect((await manager.status(requestId)).saved, isNull);
    expect((await manager.status(requestId)).saved, true);
  });

  test('invalid inputs are rejected before network access', () async {
    final api = PanelApiClient(
      baseUrl: 'https://panel.example',
      client: panelMockClient((_) async {
        fail('invalid input reached network');
      }),
    );
    addTearDown(api.close);
    final manager = PanelGlobalEnvManager(api);
    await expectLater(manager.fetchPage(page: 0), throwsArgumentError);
    await expectLater(
      manager.fetchContent(key: '../TOKEN'),
      throwsArgumentError,
    );
    await expectLater(manager.status('x'), throwsArgumentError);
    for (final changes in <Map<String, Object?>>[
      {'value': '\u0000'},
      {'value': 'x' * 65537},
      {'key': '1A'},
      {'version': 'x'},
      {
        'action': 'import',
        'items': <String>[],
        'sources': <String, String>{},
        'overwrite': false,
      },
    ]) {
      await expectLater(
        manager.mutate({
          'action': 'new',
          'key': 'A',
          'value': '',
          'version': version,
          'request_id': requestId,
          ...changes,
        }),
        throwsArgumentError,
      );
    }
  });

  test('DTOs reject malformed pages and never retain list values', () {
    final page = PanelEnvPage.fromJson({
      'ok': true,
      'version': version,
      'page': 1,
      'pages': 1,
      'total': 1,
      'items': [
        {'key': 'TOKEN', 'version': version, 'value': 'ignored-secret'},
      ],
    });
    expect(page.items.single.key, 'TOKEN');
    expect(() => PanelEnvPage.fromJson({'ok': true}), throwsFormatException);
    expect(
      () => PanelEnvContent.fromJson({
        'ok': true,
        'version': version,
        'value': 1,
      }, 'value'),
      throwsFormatException,
    );
  });
}
