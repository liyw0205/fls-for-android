import 'dart:convert';

class PanelScriptFileItem {
  const PanelScriptFileItem({
    required this.name,
    required this.path,
    required this.kind,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String name;
  final String path;
  final String kind;
  final int? sizeBytes;
  final String modifiedAt;

  bool get isDirectory => kind == 'directory';

  factory PanelScriptFileItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('脚本文件条目格式无效');
    }
    final name = value['name'];
    final path = value['path'];
    final kind = value['kind'];
    if (name is! String ||
        name.isEmpty ||
        path is! String ||
        !_validRelativePath(path) ||
        path.split('/').last != name ||
        !const {'file', 'directory'}.contains(kind)) {
      throw const FormatException('脚本文件路径或类型无效');
    }
    return PanelScriptFileItem(
      name: name,
      path: path,
      kind: kind as String,
      sizeBytes: _optionalInteger(value['size_bytes']),
      modifiedAt: value['modified_at']?.toString() ?? '',
    );
  }
}

class PanelScriptFilePage {
  const PanelScriptFilePage({
    required this.path,
    required this.parent,
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final String path;
  final String? parent;
  final List<PanelScriptFileItem> items;
  final int page;
  final int pages;
  final int total;

  factory PanelScriptFilePage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('脚本目录响应格式无效');
    }
    final path = value['path'];
    final parent = value['parent'];
    if (path is! String ||
        (path.isNotEmpty && !_validRelativePath(path)) ||
        (parent != null && parent is! String)) {
      throw const FormatException('脚本目录路径无效');
    }
    return PanelScriptFilePage(
      path: path,
      parent: parent as String?,
      items: (value['items'] as List)
          .map(PanelScriptFileItem.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']).clamp(1, 1000000).toInt(),
      total: _integer(value['total']).clamp(0, 100000000).toInt(),
    );
  }
}

class PanelScriptFileSnapshot {
  const PanelScriptFileSnapshot({
    required this.path,
    required this.name,
    required this.content,
    required this.revision,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String path;
  final String name;
  final String content;
  final String revision;
  final int sizeBytes;
  final String modifiedAt;

  factory PanelScriptFileSnapshot.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['path'] is! String ||
        !_validRelativePath(value['path'] as String) ||
        value['name'] is! String ||
        value['content'] is! String ||
        value['revision'] is! String ||
        utf8.encode(value['content'] as String).length > 2 * 1024 * 1024 ||
        (value['path'] as String).split('/').last != value['name'] ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['revision'] as String)) {
      throw const FormatException('脚本文件快照格式无效');
    }
    return PanelScriptFileSnapshot(
      path: value['path'] as String,
      name: value['name'] as String,
      content: value['content'] as String,
      revision: value['revision'] as String,
      sizeBytes: _integer(value['size_bytes']).clamp(0, 1 << 30).toInt(),
      modifiedAt: value['modified_at']?.toString() ?? '',
    );
  }
}

class PanelScriptTaskReference {
  const PanelScriptTaskReference({
    required this.id,
    required this.name,
    required this.beforeCommand,
    required this.beforeConfigPath,
    required this.afterCommand,
    required this.afterConfigPath,
    required this.manual,
  });

  final String id;
  final String name;
  final String beforeCommand;
  final String beforeConfigPath;
  final String afterCommand;
  final String afterConfigPath;
  final bool manual;

  factory PanelScriptTaskReference.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['before'] is! Map<String, dynamic> ||
        value['after'] is! Map<String, dynamic>) {
      throw const FormatException('脚本任务引用格式无效');
    }
    final before = value['before'] as Map<String, dynamic>;
    final after = value['after'] as Map<String, dynamic>;
    if (before['command'] is! String ||
        before['config_path'] is! String ||
        after['command'] is! String ||
        after['config_path'] is! String ||
        value['manual'] is! bool) {
      throw const FormatException('脚本任务引用字段无效');
    }
    return PanelScriptTaskReference(
      id: value['id'] as String,
      name: value['name'] as String,
      beforeCommand: before['command'] as String,
      beforeConfigPath: before['config_path'] as String,
      afterCommand: after['command'] as String,
      afterConfigPath: after['config_path'] as String,
      manual: value['manual'] as bool,
    );
  }
}

class PanelScriptRenamePreview {
  const PanelScriptRenamePreview({
    required this.source,
    required this.destination,
    required this.revision,
    required this.references,
  });

  final String source;
  final String destination;
  final String revision;
  final List<PanelScriptTaskReference> references;

  factory PanelScriptRenamePreview.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['source'] is! String ||
        !_validRelativePath(value['source'] as String) ||
        value['destination'] is! String ||
        !_validRelativePath(value['destination'] as String) ||
        value['revision'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['revision'] as String) ||
        value['references'] is! List) {
      throw const FormatException('脚本改名预览格式无效');
    }
    return PanelScriptRenamePreview(
      source: value['source'] as String,
      destination: value['destination'] as String,
      revision: value['revision'] as String,
      references: (value['references'] as List)
          .map(PanelScriptTaskReference.fromJson)
          .toList(growable: false),
    );
  }
}

class PanelScriptRenameOperation {
  const PanelScriptRenameOperation({
    required this.id,
    required this.source,
    required this.destination,
    required this.status,
    required this.finished,
    required this.sourceExists,
    required this.destinationExists,
    required this.taskStates,
  });

  final String id;
  final String source;
  final String destination;
  final String status;
  final bool finished;
  final bool sourceExists;
  final bool destinationExists;
  final List<Map<String, String>> taskStates;

  factory PanelScriptRenameOperation.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(value['id'] as String) ||
        value['source'] is! String ||
        !_validRelativePath(value['source'] as String) ||
        value['destination'] is! String ||
        !_validRelativePath(value['destination'] as String) ||
        value['status'] is! String ||
        value['finished'] is! bool ||
        value['actual'] is! Map<String, dynamic>) {
      throw const FormatException('脚本改名操作格式无效');
    }
    final actual = value['actual'] as Map<String, dynamic>;
    final tasks = actual['tasks'];
    if (actual['source_exists'] is! bool ||
        actual['destination_exists'] is! bool ||
        tasks is! List) {
      throw const FormatException('脚本改名状态格式无效');
    }
    final states = <Map<String, String>>[];
    for (final task in tasks) {
      if (task is! Map<String, dynamic> ||
          task['task_id'] is! String ||
          task['state'] is! String ||
          !const {
            'missing',
            'updated',
            'unchanged',
            'conflict',
          }.contains(task['state'])) {
        throw const FormatException('脚本改名任务状态无效');
      }
      states.add({
        'task_id': task['task_id'] as String,
        'state': task['state'] as String,
      });
    }
    return PanelScriptRenameOperation(
      id: value['id'] as String,
      source: value['source'] as String,
      destination: value['destination'] as String,
      status: value['status'] as String,
      finished: value['finished'] as bool,
      sourceExists: actual['source_exists'] as bool,
      destinationExists: actual['destination_exists'] as bool,
      taskStates: List.unmodifiable(states),
    );
  }
}

class PanelScriptDeleteReference {
  const PanelScriptDeleteReference({
    required this.taskId,
    required this.taskName,
    required this.fields,
  });

  final String taskId;
  final String taskName;
  final List<String> fields;

  factory PanelScriptDeleteReference.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['task_id'] is! String ||
        (value['task_id'] as String).isEmpty ||
        value['task_name'] is! String ||
        (value['task_name'] as String).length > 160 ||
        value['fields'] is! List) {
      throw const FormatException('脚本删除任务引用格式无效');
    }
    final fields = (value['fields'] as List).cast<Object?>();
    if (fields.isEmpty ||
        fields.any(
          (field) =>
              field is! String ||
              !const {'command', 'config_path'}.contains(field),
        )) {
      throw const FormatException('脚本删除任务引用字段无效');
    }
    return PanelScriptDeleteReference(
      taskId: value['task_id'] as String,
      taskName: value['task_name'] as String,
      fields: List.unmodifiable(fields.cast<String>()),
    );
  }
}

class PanelScriptDeletePreview {
  const PanelScriptDeletePreview({
    required this.path,
    required this.revision,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.references,
  });

  final String path;
  final String revision;
  final int sizeBytes;
  final String modifiedAt;
  final List<PanelScriptDeleteReference> references;

  factory PanelScriptDeletePreview.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['kind'] != 'file' ||
        value['path'] is! String ||
        !_validRelativePath(value['path'] as String) ||
        value['revision'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['revision'] as String) ||
        value['size_bytes'] is! num ||
        (value['size_bytes'] as num) < 0 ||
        (value['size_bytes'] as num) > (1 << 40) ||
        value['references'] is! List ||
        (value['references'] as List).length > 200) {
      throw const FormatException('脚本删除预览格式无效');
    }
    return PanelScriptDeletePreview(
      path: value['path'] as String,
      revision: value['revision'] as String,
      sizeBytes: (value['size_bytes'] as num).toInt(),
      modifiedAt: value['modified_at'] is String
          ? value['modified_at'] as String
          : '',
      references: (value['references'] as List)
          .map(PanelScriptDeleteReference.fromJson)
          .toList(growable: false),
    );
  }
}

bool _validRelativePath(String value) =>
    value.isNotEmpty &&
    !value.startsWith('/') &&
    !value.contains('\\') &&
    !value.contains('\u0000') &&
    value
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');

int _integer(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

int? _optionalInteger(Object? value) => value == null ? null : _integer(value);
