class PanelDependencyMaintenance {
  const PanelDependencyMaintenance({
    required this.requestId,
    required this.operationId,
    required this.version,
    required this.state,
    required this.resourceState,
    required this.receiptState,
    required this.ownerActive,
    required this.cleanupAllowed,
  });

  final String requestId;
  final String operationId;
  final String version;
  final String state;
  final String resourceState;
  final String receiptState;
  final bool ownerActive;
  final bool cleanupAllowed;

  bool get awaitingOwner =>
      ownerActive && !cleanupAllowed && !finalized && state != 'unavailable';
  bool get finalized => state == 'finalized';
  String get identity => '$requestId/$operationId';

  factory PanelDependencyMaintenance.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('依赖现场响应无效');
    }
    final requestId = value['request_id'];
    final operationId = value['operation_id'];
    final version = value['version'];
    final state = value['state'];
    final resource = value['resource_state'];
    final receipt = value['receipt_state'];
    final owner = value['owner_active'];
    final allowed = value['cleanup_allowed'];
    final idPattern = RegExp(r'^[a-f0-9]{32}$');
    if (requestId is! String ||
        !idPattern.hasMatch(requestId) ||
        operationId is! String ||
        !idPattern.hasMatch(operationId) ||
        version is! String ||
        !const {
          'pending',
          'active',
          'requested',
          'cleaning',
          'cleanup_failed',
          'finalizing',
          'finalized',
          'unavailable',
        }.contains(state) ||
        !const {'pending', 'cleaned', 'unknown'}.contains(resource) ||
        !const {'available', 'missing', 'unavailable'}.contains(receipt) ||
        owner is! bool ||
        allowed is! bool ||
        value['original_result'] != 'unknown' ||
        value['evidence_retained'] != true) {
      throw const FormatException('依赖现场身份或状态无效');
    }
    if (state == 'unavailable'
        ? version.isNotEmpty || resource != 'unknown' || allowed
        : !RegExp(r'^[a-f0-9]{64}$').hasMatch(version) ||
              resource == 'unknown') {
      throw const FormatException('依赖现场证据不一致');
    }
    if ((const {'finalizing', 'finalized'}.contains(state) &&
            resource != 'cleaned') ||
        (const {'active', 'requested', 'cleaning'}.contains(state) &&
            (!owner || allowed)) ||
        (state == 'finalized' && allowed) ||
        (allowed && (receipt == 'available' || state == 'unavailable'))) {
      throw const FormatException('依赖现场操作权限或结果不一致');
    }
    return PanelDependencyMaintenance(
      requestId: requestId,
      operationId: operationId,
      version: version,
      state: state as String,
      resourceState: resource as String,
      receiptState: receipt as String,
      ownerActive: owner,
      cleanupAllowed: allowed,
    );
  }
}

class PanelDependencyMaintenancePage {
  const PanelDependencyMaintenancePage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
    required this.hasMore,
  });

  final List<PanelDependencyMaintenance> items;
  final int total;
  final int limit;
  final int offset;
  final bool hasMore;

  factory PanelDependencyMaintenancePage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        value['total'] is! int ||
        value['limit'] is! int ||
        value['offset'] is! int ||
        value['has_more'] is! bool) {
      throw const FormatException('依赖现场列表无效');
    }
    final total = value['total'] as int;
    final limit = value['limit'] as int;
    final offset = value['offset'] as int;
    final items = (value['items'] as List)
        .map(PanelDependencyMaintenance.fromJson)
        .toList();
    if (total < 0 ||
        total > 1000 ||
        limit < 1 ||
        limit > 100 ||
        offset < 0 ||
        offset > 100000 ||
        items.length != (total - offset).clamp(0, limit) ||
        items.map((row) => row.identity).toSet().length != items.length ||
        value['has_more'] != (offset + limit < total)) {
      throw const FormatException('依赖现场分页或身份不一致');
    }
    return PanelDependencyMaintenancePage(
      items: List.unmodifiable(items),
      total: total,
      limit: limit,
      offset: offset,
      hasMore: value['has_more'] as bool,
    );
  }
}
