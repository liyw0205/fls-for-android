class PanelEnvItem {
  const PanelEnvItem({
    required this.key,
    required this.version,
    this.id,
    this.taskName,
    this.exists = false,
  });

  final String key;
  final String version;
  final String? id;
  final String? taskName;
  final bool exists;

  factory PanelEnvItem.fromJson(Object? value, {bool source = false}) {
    if (value is! Map<String, dynamic> ||
        value['key'] is! String ||
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value['key'] as String) ||
        !validEnvVersion(value['version']) ||
        (source &&
            (value['id'] is! String ||
                value['task_name'] is! String ||
                value['exists'] is! bool))) {
      throw const FormatException('变量记录格式无效');
    }
    return PanelEnvItem(
      key: value['key'] as String,
      version: value['version'] as String,
      id: source ? value['id'] as String : null,
      taskName: source ? value['task_name'] as String : null,
      exists: value['exists'] == true,
    );
  }
}

bool validEnvVersion(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

class PanelEnvPage {
  const PanelEnvPage({
    required this.items,
    required this.version,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelEnvItem> items;
  final String version;
  final int page;
  final int pages;
  final int total;

  factory PanelEnvPage.fromJson(Object? value, {bool source = false}) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List ||
        (value['items'] as List).length > 100 ||
        !validEnvVersion(value['version']) ||
        value['page'] is! int ||
        value['pages'] is! int ||
        value['total'] is! int ||
        (value['page'] as int) < 1 ||
        (value['pages'] as int) < (value['page'] as int) ||
        (value['total'] as int) < 0) {
      throw const FormatException('变量分页响应格式无效');
    }
    return PanelEnvPage(
      items: List.unmodifiable(
        (value['items'] as List).map(
          (item) => PanelEnvItem.fromJson(item, source: source),
        ),
      ),
      version: value['version'] as String,
      page: value['page'] as int,
      pages: value['pages'] as int,
      total: value['total'] as int,
    );
  }
}

class PanelEnvContent {
  const PanelEnvContent(this.content, this.version);
  final String content;
  final String version;

  factory PanelEnvContent.fromJson(Object? value, String field) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value[field] is! String ||
        !validEnvVersion(value['version'])) {
      throw const FormatException('变量内容响应格式无效');
    }
    return PanelEnvContent(value[field] as String, value['version'] as String);
  }
}

class PanelEnvResult {
  const PanelEnvResult({
    required this.saved,
    this.resolved = false,
    this.confirmRequired = false,
    this.conflict = false,
    this.changed = 0,
    this.skipped = 0,
    this.state = '',
  });
  final bool? saved;
  final bool resolved;
  final bool confirmRequired;
  final bool conflict;
  final int changed;
  final int skipped;
  final String state;

  factory PanelEnvResult.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !(value['saved'] == null || value['saved'] is bool)) {
      throw const FormatException('变量操作响应格式无效');
    }
    return PanelEnvResult(
      saved: value['saved'] as bool?,
      resolved: value['resolved'] == true,
      confirmRequired: value['confirm_required'] == true,
      conflict: value['conflict'] == true,
      changed: value['changed_count'] is int
          ? value['changed_count'] as int
          : 0,
      skipped: value['skipped_count'] is int
          ? value['skipped_count'] as int
          : 0,
      state: value['state'] is String ? value['state'] as String : '',
    );
  }
}
