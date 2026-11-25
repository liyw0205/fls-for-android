import 'panel_test_http.dart';

import 'package:fls_for_android/models/panel_records.dart';
import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_records_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'loads filtered paginated task history with a safe response model',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'fls_native_session=records-session',
          csrfToken: 'records-csrf',
        ),
        client: MockClient((request) async {
          expect(request.url.path, '/api/history');
          expect(request.url.queryParameters, {
            'q': '每日 任务',
            'status': 'failed',
            'page': '2',
            'limit': '20',
          });
          expect(
            request.headers['cookie'],
            'fls_native_session=records-session',
          );
          return utf8Response(
            '{"ok":true,"items":[{"id":"history-2","task_id":"task-1","task_name":"每日任务","command":"python task.py","status":"failed","start_at":"2026-11-25 02:00:00","duration_seconds":12,"return_code":1,"source":"manual","retry_attempt":1,"max_retries":2,"message":"failed"}],"page":2,"pages":3,"total":41}',
            200,
          );
        }),
      );
      addTearDown(api.close);

      final page = await PanelRecordsManager(
        api,
      ).fetchHistory(query: '每日 任务', status: 'failed', page: 2, limit: 20);

      expect(page.total, 41);
      expect(page.page, 2);
      expect(page.items.single.id, 'history-2');
      expect(page.items.single.returnCode, 1);
      expect(page.items.single.retryAttempt, 1);
    },
  );

  test('loads paginated log file summaries and bounded file tails', () async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=logs-session',
        csrfToken: 'logs-csrf',
      ),
      client: MockClient((request) async {
        if (request.url.path == '/api/logs') {
          expect(request.url.queryParameters, {
            'q': '签到',
            'page': '1',
            'limit': '30',
          });
          return utf8Response(
            '{"ok":true,"items":[{"filename":"Daily-1.log","group":"Daily","size_bytes":1234,"modified_at":"2026-11-25 02:00:00"}],"page":1,"pages":1,"total":1}',
            200,
          );
        }
        expect(request.url.pathSegments, ['api', 'logfile', 'Daily-1.log']);
        expect(request.url.queryParameters, {'lines': '120', 'format': 'json'});
        return utf8Response(
          '{"ok":true,"filename":"Daily-1.log","lines":120,"log":"line one\\nline two"}',
          200,
        );
      }),
    );
    addTearDown(api.close);

    final manager = PanelRecordsManager(api);
    final page = await manager.fetchLogFiles(query: '签到');
    final content = await manager.fetchLogFile('Daily-1.log', lines: 120);

    expect(page.items.single.filename, 'Daily-1.log');
    expect(page.items.single.sizeBytes, 1234);
    expect(content.text, 'line one\nline two');
    await expectLater(
      manager.fetchLogFile('../outside.log'),
      throwsArgumentError,
    );
  });

  test(
    'downloads history CSV and safely builds a bounded local CSV fallback',
    () async {
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        client: MockClient((request) async {
          expect(request.url.path, '/api/history/export');
          expect(request.url.queryParameters, {'q': '', 'status': 'success'});
          return http.Response.bytes([0xef, 0xbb, 0xbf, 65], 200);
        }),
      );
      addTearDown(api.close);

      final manager = PanelRecordsManager(api);
      final bytes = await manager.exportHistory(status: 'success');
      final csv = PanelRecordsManager.csvFromHistory([
        const PanelHistoryItem(
          id: 'h1',
          taskId: 't1',
          taskName: '日报, task',
          command: '=1+1',
          status: 'success',
          startAt: 'now',
          endAt: 'later',
          durationSeconds: 2,
          returnCode: 0,
          source: 'manual',
          retryAttempt: 0,
          maxRetries: 0,
          message: 'say "ok"',
        ),
      ]);

      expect(bytes, [0xef, 0xbb, 0xbf, 65]);
      expect(csv, startsWith('\uFEFF'));
      expect(csv, contains("'=1+1"));
      expect(csv, contains('"日报, task"'));
      expect(csv, contains('"say ""ok"""'));
    },
  );

  test('downloads a selected log file through the authenticated API', () async {
    final api = PanelApiClient(
      baseUrl: 'https://fls.example',
      credentials: const PanelSessionCredentials(
        cookie: 'fls_native_session=logs-session',
        csrfToken: 'logs-csrf',
      ),
      client: MockClient((request) async {
        expect(request.url.path, '/api/logfile/Daily-1.log/download');
        expect(request.headers['cookie'], 'fls_native_session=logs-session');
        return http.Response.bytes([108, 111, 103], 200);
      }),
    );
    addTearDown(api.close);

    final manager = PanelRecordsManager(api);
    expect(await manager.downloadLogFile('Daily-1.log'), [108, 111, 103]);
    await expectLater(
      manager.downloadLogFile('../outside.log'),
      throwsArgumentError,
    );
  });
}
