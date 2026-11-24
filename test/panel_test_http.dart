import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

http.Response utf8Response(
  String body,
  int statusCode, {
  Map<String, String> headers = const {},
}) => http.Response.bytes(utf8.encode(body), statusCode, headers: headers);

Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visibleText = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data)
      .whereType<String>()
      .join(' | ');
  throw TestFailure(
    'Timed out waiting for $finder. Visible text: $visibleText',
  );
}

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  throw TestFailure('Timed out waiting for the expected state');
}
