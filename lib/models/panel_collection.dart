import 'panel_task_summary.dart';

class PanelCollection {
  const PanelCollection({
    required this.id,
    required this.name,
    required this.remark,
    required this.memberCount,
    this.createdAt = '',
    this.updatedAt = '',
  });

  final String id;
  final String name;
  final String remark;
  final int memberCount;
  final String createdAt;
  final String updatedAt;

  factory PanelCollection.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('合集数据格式无效');
    }
    final id = value['id']?.toString().trim() ?? '';
    final name = value['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('合集缺少标识或名称');
    }
    return PanelCollection(
      id: id,
      name: name,
      remark: value['remark']?.toString() ?? '',
      memberCount: _integer(value['member_count']),
      createdAt: value['created_at']?.toString() ?? '',
      updatedAt: value['updated_at']?.toString() ?? '',
    );
  }
}

class PanelCollectionPage {
  const PanelCollectionPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelCollection> items;
  final int page;
  final int pages;
  final int total;

  factory PanelCollectionPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('合集列表响应格式无效');
    }
    return PanelCollectionPage(
      items: (value['items'] as List)
          .map(PanelCollection.fromJson)
          .toList(growable: false),
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

class PanelCollectionTaskPage {
  const PanelCollectionTaskPage({
    required this.collection,
    required this.collectionVersion,
    required this.view,
    required this.items,
    required this.memberIds,
    required this.page,
    required this.pages,
    required this.total,
  });

  final PanelCollection collection;
  final String collectionVersion;
  final String view;
  final List<PanelTaskSummary> items;
  final List<String> memberIds;
  final int page;
  final int pages;
  final int total;

  factory PanelCollectionTaskPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('合集任务响应格式无效');
    }
    final rawMembers = value['member_ids'];
    final rawCollection = value['collection'];
    final view = value['view']?.toString() ?? 'members';
    final collectionVersion = value['collection_version']?.toString() ?? '';
    if (rawCollection is! Map<String, dynamic> ||
        !const {'members', 'available'}.contains(view) ||
        collectionVersion.isEmpty ||
        (view == 'members' && rawMembers is! List) ||
        (rawMembers != null && rawMembers is! List)) {
      throw const FormatException('合集任务响应缺少版本或成员信息');
    }
    return PanelCollectionTaskPage(
      collection: PanelCollection.fromJson(rawCollection),
      collectionVersion: collectionVersion,
      view: view,
      items: (value['items'] as List)
          .map(PanelTaskSummary.fromJson)
          .toList(growable: false),
      memberIds: rawMembers is List
          ? rawMembers.map((item) => item.toString()).toList(growable: false)
          : const [],
      page: _integer(value['page']),
      pages: _integer(value['pages']),
      total: _integer(value['total']),
    );
  }
}

int _integer(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};
