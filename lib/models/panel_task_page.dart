import 'panel_task_summary.dart';

class PanelTaskPage {
  const PanelTaskPage({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
  });

  final List<PanelTaskSummary> items;
  final int page;
  final int pages;
  final int total;

  factory PanelTaskPage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['ok'] != true ||
        value['items'] is! List) {
      throw const FormatException('任务列表响应格式无效');
    }
    return PanelTaskPage(
      items: (value['items'] as List)
          .map(PanelTaskSummary.fromJson)
          .toList(growable: false),
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
