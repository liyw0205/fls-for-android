class PanelDirectoryMaintenance {
  const PanelDirectoryMaintenance({
    required this.requestId,
    required this.version,
    required this.state,
    required this.outcome,
    required this.restoreItems,
    required this.receiptState,
    required this.active,
    required this.recoverAllowed,
    this.finalizeAllowed = false,
  });

  final String requestId;
  final String version;
  final String state;
  final String outcome;
  final List<String> restoreItems;
  final String receiptState;
  final bool active;
  final bool recoverAllowed;
  final bool finalizeAllowed;

  factory PanelDirectoryMaintenance.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('目录现场响应无效');
    }
    final id = value['request_id'];
    final version = value['version'];
    final state = value['state'];
    final outcome = value['outcome'];
    final receipt = value['receipt_state'];
    final items = value['restore_items'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        version is! String ||
        !const {
          'prepared',
          'committed',
          'rolled_back',
          'finalizing',
          'finalized',
          'unavailable',
        }.contains(state) ||
        !const {
          'pending',
          'restored',
          'not_applied',
          'unknown',
        }.contains(outcome) ||
        !const {'available', 'missing', 'unavailable'}.contains(receipt) ||
        items is! List ||
        items.any((item) => !const {'data', 'scripts'}.contains(item)) ||
        items.toSet().length != items.length ||
        value['active'] is! bool ||
        value['recover_allowed'] is! bool ||
        (value.containsKey('finalize_allowed') &&
            value['finalize_allowed'] is! bool) ||
        value['evidence_retained'] != true) {
      throw const FormatException('目录现场身份或状态无效');
    }
    final unavailable = state == 'unavailable';
    if (unavailable
        ? version.isNotEmpty ||
              items.isNotEmpty ||
              outcome != 'unknown' ||
              value['recover_allowed'] == true ||
              value['finalize_allowed'] == true
        : !RegExp(r'^[a-f0-9]{64}$').hasMatch(version) ||
              items.isEmpty ||
              (state == 'prepared' && outcome != 'pending') ||
              (state == 'committed' && outcome != 'restored') ||
              (state == 'rolled_back' && outcome != 'not_applied') ||
              (const {'finalizing', 'finalized'}.contains(state) &&
                  !const {'restored', 'not_applied'}.contains(outcome))) {
      throw const FormatException('目录现场结果不一致');
    }
    if (value['recover_allowed'] == true &&
        (value['active'] == true ||
            receipt == 'available' ||
            state == 'finalized')) {
      throw const FormatException('目录现场操作权限不一致');
    }
    if (value['finalize_allowed'] == true &&
        (value['active'] == true ||
            receipt == 'available' ||
            !const {
              'committed',
              'rolled_back',
              'finalizing',
            }.contains(state))) {
      throw const FormatException('目录现场结束权限不一致');
    }
    return PanelDirectoryMaintenance(
      requestId: id,
      version: version,
      state: state as String,
      outcome: outcome as String,
      restoreItems: List<String>.unmodifiable(items.cast<String>()),
      receiptState: receipt as String,
      active: value['active'] as bool,
      recoverAllowed: value['recover_allowed'] as bool,
      finalizeAllowed: value['finalize_allowed'] == true,
    );
  }
}

class PanelDirectoryMaintenancePage {
  const PanelDirectoryMaintenancePage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
    required this.hasMore,
  });

  final List<PanelDirectoryMaintenance> items;
  final int total;
  final int limit;
  final int offset;
  final bool hasMore;

  factory PanelDirectoryMaintenancePage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        value['total'] is! int ||
        value['limit'] is! int ||
        value['offset'] is! int ||
        value['has_more'] is! bool) {
      throw const FormatException('目录现场列表无效');
    }
    final total = value['total'] as int;
    final limit = value['limit'] as int;
    final offset = value['offset'] as int;
    final items = (value['items'] as List)
        .map(PanelDirectoryMaintenance.fromJson)
        .toList();
    if (total < 0 ||
        total > 1000 ||
        limit < 1 ||
        limit > 100 ||
        offset < 0 ||
        offset > 100000 ||
        items.length != (total - offset).clamp(0, limit) ||
        items.map((item) => item.requestId).toSet().length != items.length ||
        value['has_more'] != (offset + limit < total)) {
      throw const FormatException('目录现场分页或身份不一致');
    }
    return PanelDirectoryMaintenancePage(
      items: List.unmodifiable(items),
      total: total,
      limit: limit,
      offset: offset,
      hasMore: value['has_more'] as bool,
    );
  }
}
