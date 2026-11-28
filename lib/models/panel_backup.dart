import 'dart:convert';

class PanelBackupCapabilities {
  const PanelBackupCapabilities({
    required this.items,
    required this.formats,
    required this.uploadLimitBytes,
    required this.extractedLimitBytes,
    required this.entryLimit,
    this.preflightEnabled = false,
    this.preflightLimit = 0,
    this.preflightTtlSeconds = 0,
    this.restoreEnabled = false,
    this.directoryMaintenanceEnabled = false,
  });

  final List<String> items;
  final List<String> formats;
  final int uploadLimitBytes;
  final int extractedLimitBytes;
  final int entryLimit;
  final bool preflightEnabled;
  final int preflightLimit;
  final int preflightTtlSeconds;
  final bool restoreEnabled;
  final bool directoryMaintenanceEnabled;

  factory PanelBackupCapabilities.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        value['formats'] is! List) {
      throw const FormatException('备份能力响应格式无效');
    }
    if (value.containsKey('directory_maintenance_enabled') &&
        value['directory_maintenance_enabled'] is! bool) {
      throw const FormatException('目录现场维护能力无效');
    }
    return PanelBackupCapabilities(
      items: (value['items'] as List).whereType<String>().toList(),
      formats: (value['formats'] as List).whereType<String>().toList(),
      uploadLimitBytes: _integer(value['upload_limit_bytes']),
      extractedLimitBytes: _integer(value['extracted_limit_bytes']),
      entryLimit: _integer(value['entry_limit']),
      preflightEnabled: value['preflight_enabled'] == true,
      preflightLimit: _integer(value['preflight_limit']),
      preflightTtlSeconds: _integer(value['preflight_ttl_seconds']),
      restoreEnabled: value['restore_enabled'] == true,
      directoryMaintenanceEnabled:
          value['directory_maintenance_enabled'] == true,
    );
  }
}

class PanelBackupPreflight {
  const PanelBackupPreflight({
    required this.requestId,
    required this.status,
    required this.active,
    required this.cancelAllowed,
    required this.filename,
    required this.format,
    required this.archiveSizeBytes,
    required this.archiveSha256,
    required this.items,
    required this.entryCount,
    required this.expandedBytes,
    required this.dependencyFiles,
    required this.warnings,
    required this.errorCode,
    required this.expiresAt,
  });

  final String requestId;
  final String status;
  final bool active;
  final bool cancelAllowed;
  final String filename;
  final String format;
  final int archiveSizeBytes;
  final String archiveSha256;
  final List<String> items;
  final int entryCount;
  final int expandedBytes;
  final List<String> dependencyFiles;
  final List<String> warnings;
  final String errorCode;
  final int expiresAt;

  factory PanelBackupPreflight.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['preflight'] is! Map<String, dynamic>) {
      throw const FormatException('备份预检查响应格式无效');
    }
    final record = value['preflight'] as Map<String, dynamic>;
    final id = record['preflight_id']?.toString() ?? '';
    final state = record['status']?.toString() ?? '';
    final digest = record['archive_sha256']?.toString() ?? '';
    final filename = record['filename']?.toString() ?? '';
    final format = record['format']?.toString() ?? '';
    final items = _strings(record['items']);
    final dependencies = _strings(record['dependency_files']);
    final warnings = _strings(record['warnings']);
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !const {
          'uploading',
          'checking',
          'ready',
          'failed',
          'cancelled',
          'expired',
          'unknown',
        }.contains(state) ||
        (digest.isNotEmpty && !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) ||
        filename.isEmpty ||
        filename.length > 255 ||
        filename != filename.trim() ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename.contains(':') ||
        filename.codeUnits.any((unit) => unit < 32 || unit == 127) ||
        !const {'tar.gz', 'tgz', 'tar', 'zip'}.contains(format) ||
        items.length != items.toSet().length ||
        items.any((item) => !const {'data', 'scripts'}.contains(item)) ||
        dependencies.any(
          (item) =>
              !const {'requirements.txt', 'dependencies.txt'}.contains(item),
        ) ||
        warnings.any(
          (item) => !const {
            'data_restore_may_change_panel_access',
            'contains_native_session_store',
          }.contains(item),
        )) {
      throw const FormatException('备份预检查摘要无效');
    }
    return PanelBackupPreflight(
      requestId: id,
      status: state,
      active: record['active'] == true,
      cancelAllowed: record['cancel_allowed'] == true,
      filename: filename,
      format: format,
      archiveSizeBytes: _integer(record['archive_size_bytes']),
      archiveSha256: digest,
      items: items,
      entryCount: _integer(record['entry_count']),
      expandedBytes: _integer(record['expanded_bytes']),
      dependencyFiles: dependencies,
      warnings: warnings,
      errorCode: record['error_code']?.toString() ?? '',
      expiresAt: _integer(record['expires_at']),
    );
  }
}

class PanelBackupFollowup {
  const PanelBackupFollowup({
    required this.state,
    required this.operationId,
    required this.required,
    required this.error,
    required this.output,
    this.cleanupRequired = false,
  });

  final String state;
  final String operationId;
  final bool required;
  final String error;
  final String output;
  final bool cleanupRequired;

  factory PanelBackupFollowup.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['state'] is! String ||
        value['operation_id'] is! String ||
        value['error'] is! String ||
        (value.containsKey('required') && value['required'] is! bool) ||
        (value.containsKey('cleanup_required') &&
            value['cleanup_required'] is! bool) ||
        (value.containsKey('output') && value['output'] is! String)) {
      throw const FormatException('恢复后续处理状态无效');
    }
    final state = value['state'] as String;
    if (!const {
      'not_required',
      'not_requested',
      'pending',
      'running',
      'succeeded',
      'failed',
      'unknown',
    }.contains(state)) {
      throw const FormatException('恢复后续处理阶段无效');
    }
    final operationId = value['operation_id'] as String;
    if (operationId.isNotEmpty &&
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(operationId)) {
      throw const FormatException('恢复后续操作标识无效');
    }
    final output = value['output'] as String? ?? '';
    final error = value['error'] as String;
    final cleanupRequired = value['cleanup_required'] == true;
    if (utf8.encode(output).length > 32768 ||
        utf8.encode(error).length > 1000 ||
        (const {'running', 'succeeded', 'failed', 'unknown'}.contains(state) &&
            operationId.isEmpty) ||
        (const {'pending', 'not_required', 'not_requested'}.contains(state) &&
            operationId.isNotEmpty) ||
        (cleanupRequired && state != 'unknown')) {
      throw const FormatException('恢复后续处理身份或输出无效');
    }
    return PanelBackupFollowup(
      state: state,
      operationId: operationId,
      required: value['required'] == true,
      error: error,
      output: output,
      cleanupRequired: cleanupRequired,
    );
  }
}

class PanelBackupRestore {
  const PanelBackupRestore({
    required this.requestId,
    required this.preflightId,
    required this.filename,
    required this.archiveSha256,
    required this.archiveSizeBytes,
    required this.items,
    required this.restoreDependencies,
    required this.state,
    required this.phase,
    required this.active,
    required this.committed,
    required this.liveStateUnchanged,
    required this.restoreOutcomeUnknown,
    required this.error,
    required this.createdAt,
    required this.updatedAt,
    required this.scheduler,
    required this.dependencies,
    this.directoryRecoveryRequired = false,
    this.dependencyCleanupRequested = false,
  });

  final String requestId;
  final String preflightId;
  final String filename;
  final String archiveSha256;
  final int archiveSizeBytes;
  final List<String> items;
  final bool restoreDependencies;
  final String state;
  final String phase;
  final bool active;
  final bool committed;
  final bool liveStateUnchanged;
  final bool restoreOutcomeUnknown;
  final String error;
  final int createdAt;
  final int updatedAt;
  final PanelBackupFollowup scheduler;
  final PanelBackupFollowup dependencies;
  final bool directoryRecoveryRequired;
  final bool dependencyCleanupRequested;

  factory PanelBackupRestore.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['restore'] is! Map<String, dynamic> ||
        (value.containsKey('cleanup_requested') &&
            value['cleanup_requested'] is! bool)) {
      throw const FormatException('备份恢复响应格式无效');
    }
    final record = value['restore'] as Map<String, dynamic>;
    const stringFields = [
      'request_id',
      'preflight_id',
      'archive_sha256',
      'filename',
      'state',
      'phase',
      'error',
    ];
    const boolFields = [
      'restore_dependencies',
      'active',
      'committed',
      'live_state_unchanged',
      'restore_outcome_unknown',
    ];
    if (stringFields.any((field) => record[field] is! String) ||
        boolFields.any((field) => record[field] is! bool) ||
        (record.containsKey('directory_recovery_required') &&
            record['directory_recovery_required'] is! bool) ||
        record['archive_size_bytes'] is! int ||
        record['created_at'] is! int ||
        record['updated_at'] is! int ||
        record['restore_items'] is! List ||
        (record['restore_items'] as List).any((item) => item is! String)) {
      throw const FormatException('备份恢复字段类型无效');
    }
    final requestId = record['request_id'] as String;
    final preflightId = record['preflight_id'] as String;
    final digest = record['archive_sha256'] as String;
    final filename = record['filename'] as String;
    final items = List<String>.unmodifiable(record['restore_items'] as List);
    final state = record['state'] as String;
    final phase = record['phase'] as String;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(preflightId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        filename.isEmpty ||
        filename.length > 255 ||
        filename != filename.trim() ||
        filename.contains('/') ||
        filename.contains('\\') ||
        !const {
          'accepted',
          'extracting',
          'staging',
          'committing',
          'restored',
          'failed',
          'unknown',
        }.contains(state) ||
        !const {
          'accepted',
          'extracting',
          'staging',
          'committing',
          'restored',
          'failed',
          'unknown',
        }.contains(phase) ||
        items.isEmpty ||
        items.length != items.toSet().length ||
        items.any((item) => !const {'data', 'scripts'}.contains(item))) {
      throw const FormatException('备份恢复记录身份无效');
    }
    final active = record['active'] as bool;
    final directoryRecoveryRequired =
        record['directory_recovery_required'] == true;
    final committed = record['committed'] as bool;
    final unchanged = record['live_state_unchanged'] as bool;
    final unknown = record['restore_outcome_unknown'] as bool;
    const activeStates = {'accepted', 'extracting', 'staging', 'committing'};
    final scheduler = PanelBackupFollowup.fromJson(record['scheduler']);
    final dependencies = PanelBackupFollowup.fromJson(record['dependencies']);
    final restoreDependencies = record['restore_dependencies'] as bool;
    final cleanupRequested = value['cleanup_requested'] == true;
    if ((record['archive_size_bytes'] as int) < 1 ||
        (record['created_at'] as int) < 0 ||
        (record['updated_at'] as int) < (record['created_at'] as int) ||
        utf8.encode(record['error'] as String).length > 1000 ||
        active != activeStates.contains(state) ||
        (active && directoryRecoveryRequired) ||
        (active && phase != state) ||
        committed != (state == 'restored') ||
        (committed && unchanged) ||
        unknown != (state == 'unknown') ||
        (state == 'failed' && !unchanged) ||
        scheduler.required != items.contains('data') ||
        scheduler.state == 'not_requested' ||
        (!items.contains('data') && scheduler.state != 'not_required') ||
        (items.contains('data') &&
            scheduler.state == 'not_required' &&
            state != 'failed') ||
        dependencies.state == 'not_required' ||
        (cleanupRequested &&
            (!restoreDependencies || dependencies.operationId.isEmpty)) ||
        (!restoreDependencies && dependencies.state != 'not_requested') ||
        (restoreDependencies &&
            dependencies.state == 'not_requested' &&
            state != 'failed')) {
      throw const FormatException('备份恢复状态不一致');
    }
    return PanelBackupRestore(
      requestId: requestId,
      preflightId: preflightId,
      filename: filename,
      archiveSha256: digest,
      archiveSizeBytes: _integer(record['archive_size_bytes']),
      items: items,
      restoreDependencies: restoreDependencies,
      state: state,
      phase: phase,
      active: active,
      committed: committed,
      liveStateUnchanged: unchanged,
      restoreOutcomeUnknown: unknown,
      error: record['error'] as String,
      createdAt: _integer(record['created_at']),
      updatedAt: _integer(record['updated_at']),
      scheduler: scheduler,
      dependencies: dependencies,
      directoryRecoveryRequired: directoryRecoveryRequired,
      dependencyCleanupRequested: cleanupRequested,
    );
  }
}

class PanelBackupRestoresPage {
  const PanelBackupRestoresPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
    required this.hasMore,
  });

  final List<PanelBackupRestore> items;
  final int total;
  final int limit;
  final int offset;
  final bool hasMore;

  factory PanelBackupRestoresPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        value['total'] is! int ||
        value['limit'] is! int ||
        value['offset'] is! int ||
        value['has_more'] is! bool) {
      throw const FormatException('备份恢复历史响应格式无效');
    }
    final total = value['total'] as int;
    final limit = value['limit'] as int;
    final offset = value['offset'] as int;
    final items = value['items'] as List;
    if (total < 0 ||
        total > 1000 ||
        limit < 1 ||
        limit > 100 ||
        offset < 0 ||
        offset > 100000 ||
        items.length > limit ||
        items.length != (total - offset).clamp(0, limit) ||
        value['has_more'] != (offset + limit < total)) {
      throw const FormatException('备份恢复历史分页无效');
    }
    return PanelBackupRestoresPage(
      items: (value['items'] as List)
          .map(
            (item) =>
                PanelBackupRestore.fromJson({'ok': true, 'restore': item}),
          )
          .toList(growable: false),
      total: total,
      limit: limit,
      offset: offset,
      hasMore: value['has_more'] == true,
    );
  }
}

class PanelBackupMaintenance {
  const PanelBackupMaintenance({
    required this.eventId,
    required this.required,
    required this.kind,
    required this.acknowledged,
    required this.notice,
  });

  final String eventId;
  final bool required;
  final String kind;
  final bool acknowledged;
  final String notice;

  factory PanelBackupMaintenance.fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['ok'] != true) {
      throw const FormatException('恢复归档维护状态响应无效');
    }
    if (value['maintenance'] == null) {
      return const PanelBackupMaintenance(
        eventId: '',
        required: false,
        kind: '',
        acknowledged: true,
        notice: '',
      );
    }
    final maintenance = value['maintenance'];
    if (maintenance is! Map<String, dynamic>) {
      throw const FormatException('恢复归档维护状态无效');
    }
    final eventId = maintenance['event_id']?.toString() ?? '';
    final kind = maintenance['kind']?.toString() ?? '';
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(eventId) ||
        !const {'repair', 'publication', 'unavailable'}.contains(kind)) {
      throw const FormatException('恢复维护事件身份无效');
    }
    return PanelBackupMaintenance(
      eventId: eventId,
      required: maintenance['required'] == true,
      kind: kind,
      acknowledged: maintenance['acknowledged'] == true,
      notice: maintenance['notice']?.toString() ?? '',
    );
  }
}

class PanelBackupFile {
  const PanelBackupFile({
    required this.name,
    required this.version,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String name;
  final String version;
  final int sizeBytes;
  final String modifiedAt;

  factory PanelBackupFile.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('备份文件记录格式无效');
    }
    final name = value['name']?.toString() ?? '';
    final version = value['version']?.toString() ?? '';
    if (name.isEmpty ||
        name != name.trim() ||
        name.contains('/') ||
        name.contains('\\') ||
        !name.endsWith('.tar.gz') ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) {
      throw const FormatException('备份文件身份无效');
    }
    return PanelBackupFile(
      name: name,
      version: version,
      sizeBytes: _integer(value['size_bytes']),
      modifiedAt: value['modified_at']?.toString() ?? '',
    );
  }
}

class PanelBackupFilesPage {
  const PanelBackupFilesPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelBackupFile> items;
  final int page;
  final int pages;
  final int total;

  factory PanelBackupFilesPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('备份文件分页响应格式无效');
    }
    return PanelBackupFilesPage(
      items: (value['items'] as List)
          .map(PanelBackupFile.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelBackupJob {
  const PanelBackupJob({
    required this.id,
    required this.items,
    required this.status,
    required this.active,
    required this.cancelAllowed,
    required this.cancelRequested,
    required this.filename,
    required this.sizeBytes,
    required this.createdAt,
    required this.updatedAt,
    required this.cleanupRequired,
  });

  final String id;
  final List<String> items;
  final String status;
  final bool active;
  final bool cancelAllowed;
  final bool cancelRequested;
  final String filename;
  final int sizeBytes;
  final String createdAt;
  final String updatedAt;
  final bool cleanupRequired;

  factory PanelBackupJob.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        value['items'] is! List ||
        value['status'] is! String) {
      throw const FormatException('备份作业记录格式无效');
    }
    final id = value['id'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw const FormatException('备份作业标识无效');
    }
    return PanelBackupJob(
      id: id,
      items: (value['items'] as List).whereType<String>().toList(),
      status: value['status'] as String,
      active: value['active'] == true,
      cancelAllowed: value['cancel_allowed'] == true,
      cancelRequested: value['cancel_requested'] == true,
      filename: value['filename']?.toString() ?? '',
      sizeBytes: _integer(value['size_bytes']),
      createdAt: value['created_at']?.toString() ?? '',
      updatedAt: value['updated_at']?.toString() ?? '',
      cleanupRequired: value['cleanup_required'] == true,
    );
  }
}

class PanelBackupJobsPage {
  const PanelBackupJobsPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelBackupJob> items;
  final int page;
  final int pages;
  final int total;

  factory PanelBackupJobsPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('备份作业分页响应格式无效');
    }
    return PanelBackupJobsPage(
      items: (value['items'] as List)
          .map(PanelBackupJob.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelBackupRequest {
  const PanelBackupRequest({
    required this.requestId,
    required this.kind,
    required this.status,
    required this.accepted,
    required this.items,
  });

  final String requestId;
  final String kind;
  final String status;
  final bool? accepted;
  final List<String> items;

  factory PanelBackupRequest.fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['ok'] != true) {
      throw const FormatException('备份请求查询响应格式无效');
    }
    final request = value['request'];
    if (request is! Map<String, dynamic> ||
        request['request_id'] is! String ||
        request['kind'] is! String ||
        request['status'] is! String) {
      throw const FormatException('备份请求摘要格式无效');
    }
    return PanelBackupRequest(
      requestId: request['request_id'] as String,
      kind: request['kind'] as String,
      status: request['status'] as String,
      accepted: request['accepted'] is bool
          ? request['accepted'] as bool
          : null,
      items: request['items'] is List
          ? (request['items'] as List).whereType<String>().toList()
          : const [],
    );
  }
}

int _integer(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

List<String> _strings(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];
