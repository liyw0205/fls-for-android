class PanelDashboardSnapshot {
  const PanelDashboardSnapshot({
    required this.currentTime,
    required this.timezone,
    required this.panelUptime,
    required this.systemCpuPercent,
    required this.panelCpuCurrent,
    required this.panelCpuPeak,
    required this.schedulerStatus,
    required this.schedulerStatusLabel,
    required this.schedulerTaskCount,
    required this.scheduledCount,
    required this.schedulerError,
    required this.jobs,
  });

  final String currentTime;
  final String timezone;
  final String panelUptime;
  final String systemCpuPercent;
  final String panelCpuCurrent;
  final String panelCpuPeak;
  final String schedulerStatus;
  final String schedulerStatusLabel;
  final int schedulerTaskCount;
  final int scheduledCount;
  final String schedulerError;
  final List<PanelSchedulerJob> jobs;

  factory PanelDashboardSnapshot.fromPayloads({
    required Map<String, dynamic> runtime,
    required Map<String, dynamic> scheduler,
    required List<Object?> jobs,
  }) {
    if (runtime['ok'] != true || scheduler['ok'] != true) {
      throw const FormatException('仪表盘状态格式无效');
    }
    return PanelDashboardSnapshot(
      currentTime: _asText(runtime['current_time']),
      timezone: _asText(runtime['timezone']),
      panelUptime: _asText(runtime['panel_uptime']),
      systemCpuPercent: _asText(runtime['system_cpu_percent']),
      panelCpuCurrent: _asText(runtime['panel_cpu_current']),
      panelCpuPeak: _asText(runtime['panel_cpu_peak']),
      schedulerStatus: _asText(scheduler['status'], fallback: 'unknown'),
      schedulerStatusLabel: _asText(
        scheduler['status_label'],
        fallback: '结果未知',
      ),
      schedulerTaskCount: _asInt(scheduler['task_count']),
      scheduledCount: _asInt(scheduler['scheduled_count']),
      schedulerError: _asText(scheduler['error']),
      jobs: jobs.map(PanelSchedulerJob.fromJson).toList(growable: false),
    );
  }

  static String _asText(Object? value, {String fallback = '-'}) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static int _asInt(Object? value) => switch (value) {
    int number => number < 0 ? 0 : number,
    num number => number < 0 ? 0 : number.toInt(),
    String text => (int.tryParse(text) ?? 0).clamp(0, 1 << 31),
    _ => 0,
  };
}

class PanelSchedulerJob {
  const PanelSchedulerJob({
    required this.id,
    required this.nextRunTime,
    required this.trigger,
  });

  final String id;
  final String nextRunTime;
  final String trigger;

  factory PanelSchedulerJob.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('调度任务格式无效');
    }
    final id = value['id']?.toString().trim() ?? '';
    if (id.isEmpty) throw const FormatException('调度任务缺少 ID');
    return PanelSchedulerJob(
      id: id,
      nextRunTime: value['next_run_time']?.toString() ?? '',
      trigger: value['trigger']?.toString() ?? '',
    );
  }
}
