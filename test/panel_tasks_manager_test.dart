import 'dart:convert';

import 'panel_test_http.dart';

import 'package:fls_for_android/models/panel_task_draft.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_tasks_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

void main() {
  test('loads native collection pages with encoded search parameters', () async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=collection-session',
        csrfToken: 'collection-csrf',
      ),
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.headers['cookie'],
          'fls_native_session=collection-session',
        );
        if (request.url.path == '/api/collections') {
          expect(request.url.queryParameters, {
            'q': '签到 + 监控',
            'page': '2',
            'limit': '25',
          });
          return utf8Response(
            '{"ok":true,"items":[{"id":"group-a","name":"签到","remark":"每日任务","member_count":3}],"page":2,"pages":2,"total":30}',
            200,
          );
        }
        expect(request.url.path, '/api/collection/group-a');
        expect(request.url.queryParameters, {
          'view': 'members',
          'q': '每日签到',
          'page': '1',
          'limit': '50',
        });
        return utf8Response(
          '{"ok":true,"collection":{"id":"group-a","name":"签到","remark":"每日任务","member_count":1},"collection_version":"revision-a","view":"members","member_ids":["task-a"],"items":[{"id":"task-a","name":"每日签到","command":"python checkin.py","cron":"0 8 * * *","enabled":true,"running":false,"run_count":1,"collection_id":"group-a"}],"page":1,"pages":1,"total":1}',
          200,
          headers: {'cache-control': 'no-store'},
        );
      }),
    );
    addTearDown(api.close);
    final manager = PanelTasksManager(api);

    final page = await manager.fetchCollections(
      query: '签到 + 监控',
      page: 2,
      limit: 25,
    );
    final members = await manager.fetchCollectionTasks(
      'group-a',
      query: '每日签到',
    );

    expect(page.items.single.memberCount, 3);
    expect(page.page, 2);
    expect(members.collectionVersion, 'revision-a');
    expect(members.collection.memberCount, 1);
    expect(members.memberIds, ['task-a']);
    expect(members.items.single.name, '每日签到');
  });

  test(
    'sends collection revisions and expected memberships on mutations',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=collection-session',
          csrfToken: 'collection-csrf',
        ),
        client: MockClient((request) async {
          expect(request.headers['x-csrf-token'], 'collection-csrf');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          switch (request.url.path) {
            case '/api/collection/save':
              expect(body['collection_id'], 'group-a');
              expect(body['collection_version'], 'revision-a');
              expect(body['name'], '签到与监控');
            case '/api/collection/add-task/group-a':
              expect(body['task_ids'], ['task-b']);
              expect(body['expected_collections'], {'task-b': 'group-old'});
            case '/api/collection/delete/group-a':
              expect(body['expected_members'], ['task-a', 'task-b']);
              expect(body['collection_version'], 'revision-b');
            default:
              fail('Unexpected collection request: ${request.url.path}');
          }
          expect(body['request_id'], 'a' * 32);
          return utf8Response('{"ok":true,"changed":true}', 200);
        }),
      );
      addTearDown(api.close);
      final manager = PanelTasksManager(api);

      await manager.saveCollection(
        requestId: 'a' * 32,
        collectionId: 'group-a',
        collectionVersion: 'revision-a',
        name: '签到与监控',
        remark: '日报',
      );
      await manager.addTasksToCollection(
        collectionId: 'group-a',
        taskIds: ['task-b'],
        expectedCollections: {'task-b': 'group-old'},
        requestId: 'a' * 32,
      );
      await manager.deleteCollection(
        collectionId: 'group-a',
        expectedMembers: ['task-a', 'task-b'],
        collectionVersion: 'revision-b',
        requestId: 'a' * 32,
      );
    },
  );

  test('loads safe task form options without channel credentials', () async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=detail-session',
        csrfToken: 'detail-csrf',
      ),
      client: MockClient((request) async {
        expect(request.url.path, '/api/tasks/form-options');
        return utf8Response(
          '{"ok":true,"collections":[{"id":"group-1","name":"签到"}],"proxies":[{"id":"proxy-1","name":"家用","type":"http"}],"notifications":[{"id":"notify-1","name":"通知","channel":"serverj","channel_name":"Server 酱"}]}',
          200,
        );
      }),
    );
    addTearDown(api.close);

    final options = await PanelTasksManager(api).fetchTaskFormOptions();

    expect(options.collections.single.id, 'group-1');
    expect(options.proxies.single.detail, 'http');
    expect(options.notifications.single.detail, 'Server 酱');
  });

  test('creates a task with an idempotency key and CSRF token', () async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=detail-session',
        csrfToken: 'detail-csrf',
      ),
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/tasks');
        expect(request.headers['cookie'], 'fls_native_session=detail-session');
        expect(request.headers['x-csrf-token'], 'detail-csrf');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['request_id'], 'a' * 32);
        expect(body['task']['name'], '新任务');
        return utf8Response(
          '{"ok":true,"created":true,"task":{"id":"${'a' * 32}","name":"新任务"}}',
          201,
        );
      }),
    );
    addTearDown(api.close);

    final response = await PanelTasksManager(api).createTask(
      const PanelTaskDraft(
        name: '新任务',
        remark: '',
        command: 'python task.py',
        cron: '',
        configPath: '',
        collectionId: '',
        enabled: true,
        environment: {},
        proxyId: '',
        notifyMode: 'none',
        notifyIds: [],
        randomDelayMode: 'none',
        randomDelaySeconds: 1,
        retryAttempts: 0,
        retryIntervalSeconds: 60,
      ),
      requestId: 'a' * 32,
    );

    expect(response['created'], isTrue);
  });

  test('updates task using optimistic revision and CSRF token', () async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=detail-session',
        csrfToken: 'detail-csrf',
      ),
      client: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/tasks/daily');
        expect(request.headers['x-csrf-token'], 'detail-csrf');
        expect(jsonDecode(request.body)['expected_updated_at'], 'revision-1');
        return utf8Response(
          '{"ok":true,"changed":true,"task":{"id":"daily"}}',
          200,
        );
      }),
    );
    addTearDown(api.close);

    final response = await PanelTasksManager(api).updateTask(
      'daily',
      PanelTaskDraft.empty(),
      expectedUpdatedAt: 'revision-1',
    );

    expect(response['changed'], isTrue);
  });

  test(
    'reloads the scheduler through the authenticated panel session',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=detail-session',
          csrfToken: 'detail-csrf',
        ),
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/scheduler/reload');
          expect(
            request.headers['cookie'],
            'fls_native_session=detail-session',
          );
          expect(request.headers['x-csrf-token'], 'detail-csrf');
          return utf8Response(
            '{"ok":true,"status":"succeeded","state":{"task_count":3}}',
            200,
          );
        }),
      );
      addTearDown(api.close);

      final response = await PanelTasksManager(api).reloadScheduler();

      expect(response['status'], 'succeeded');
    },
  );

  test(
    'loads task details and recent history through the panel session',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=detail-session',
          csrfToken: 'detail-csrf',
        ),
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.pathSegments.last, 'daily task');
          expect(
            request.headers['cookie'],
            'fls_native_session=detail-session',
          );
          expect(request.headers['x-token'], isNull);
          return utf8Response(
            jsonEncode({
              'ok': true,
              'task': {
                'id': 'daily task',
                'name': '每日任务',
                'command': 'python daily.py',
                'env': {'API_KEY': 'hidden'},
              },
              'runtime': {'running': false, 'status': 'stopped'},
              'history': [
                {'id': 'history-1', 'status': 'success', 'duration_seconds': 2},
              ],
            }),
            200,
            headers: {'cache-control': 'no-store'},
          );
        }),
      );
      addTearDown(api.close);

      final detail = await PanelTasksManager(api).fetchTaskDetail('daily task');

      expect(detail.task['name'], '每日任务');
      expect(detail.task['env'], {'API_KEY': 'hidden'});
      expect(detail.runtime['running'], isFalse);
      expect(detail.history.single['status'], 'success');
      expect(() => detail.task['name'] = 'changed', throwsUnsupportedError);
    },
  );

  test('loads a bounded JSON task-log response', () async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=detail-session',
        csrfToken: 'detail-csrf',
      ),
      client: MockClient((request) async {
        expect(request.url.pathSegments, ['api', 'task', 'daily', 'log']);
        expect(request.url.queryParameters['lines'], '120');
        return utf8Response(
          '{"ok":true,"task_id":"daily","running":false,"lines":120,"log":"line one\\nline two"}',
          200,
        );
      }),
    );
    addTearDown(api.close);

    final log = await PanelTasksManager(api).fetchTaskLog('daily', lines: 120);

    expect(log, 'line one\nline two');
    await expectLater(
      PanelTasksManager(api).fetchTaskLog('daily', lines: 1001),
      throwsArgumentError,
    );
  });
}
