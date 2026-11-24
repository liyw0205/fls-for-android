import 'panel_test_http.dart';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:fls_for_android/services/panel_dashboard_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

void main() {
  test(
    'loads dashboard runtime and scheduler contracts through the session',
    () async {
      final paths = <String>{};
      final api = PanelApiClient(
        baseUrl: 'https://fls.example',
        credentials: const PanelSessionCredentials(
          cookie: 'session=dashboard-session',
          csrfToken: 'dashboard-csrf',
        ),
        client: MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers['cookie'], 'session=dashboard-session');
          expect(request.headers['x-token'], isNull);
          return switch (request.url.path) {
            '/api/dashboard/runtime' => utf8Response(
              '{"ok":true,"current_time":"2026-11-25 12:00:00","timezone":"UTC+8","panel_uptime":"1 小时","system_cpu_percent":"12.0%","panel_cpu_current":"1.0%","panel_cpu_peak":"5.0%"}',
              200,
            ),
            '/api/scheduler/status' => utf8Response(
              '{"ok":true,"status":"succeeded","status_label":"已完成","task_count":4,"scheduled_count":2,"error":""}',
              200,
            ),
            '/api/scheduler/jobs' => utf8Response(
              '{"ok":true,"jobs":[{"id":"daily","next_run_time":"2026-11-26 08:00:00","trigger":"cron[hour=8]"}]}',
              200,
            ),
            _ => utf8Response('{}', 404),
          };
        }),
      );
      addTearDown(api.close);

      final dashboard = await PanelDashboardManager(api).fetch();

      expect(paths, {
        '/api/dashboard/runtime',
        '/api/scheduler/status',
        '/api/scheduler/jobs',
      });
      expect(dashboard.currentTime, '2026-11-25 12:00:00');
      expect(dashboard.schedulerStatusLabel, '已完成');
      expect(dashboard.schedulerTaskCount, 4);
      expect(dashboard.scheduledCount, 2);
      expect(dashboard.jobs.single.id, 'daily');
      expect(dashboard.jobs.single.nextRunTime, '2026-11-26 08:00:00');
    },
  );
}
