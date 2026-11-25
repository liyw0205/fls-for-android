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
