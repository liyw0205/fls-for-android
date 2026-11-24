import '../models/panel_dashboard_snapshot.dart';
import 'panel_api_client.dart';

class PanelDashboardManager {
  const PanelDashboardManager(this._api);

  final PanelApiClient _api;

  Future<PanelDashboardSnapshot> fetch() async {
    final responses = await Future.wait([
      _api.getJson('/api/dashboard/runtime'),
      _api.getJson('/api/scheduler/status'),
      _api.getJson('/api/scheduler/jobs'),
    ]);
    final runtime = _asMap(responses[0], '运行状态');
    final scheduler = _asMap(responses[1], '调度器状态');
    final jobsPayload = _asMap(responses[2], '调度任务');
    final jobs = jobsPayload['jobs'];
    if (jobsPayload['ok'] != true || jobs is! List) {
      throw const FormatException('调度任务列表格式无效');
    }
    return PanelDashboardSnapshot.fromPayloads(
      runtime: runtime,
      scheduler: scheduler,
      jobs: jobs,
    );
  }

  Map<String, dynamic> _asMap(Object? value, String label) {
    if (value is! Map<String, dynamic>) {
      throw FormatException('$label格式无效');
    }
    return value;
  }
}
