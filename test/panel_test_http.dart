import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

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

http.Client panelMockClient(
  Future<http.Response> Function(http.Request request) handler,
) => http_testing.MockClient.streaming((baseRequest, bodyStream) async {
  final bodyBytes = await bodyStream.toBytes();
  final request = http.Request(baseRequest.method, baseRequest.url)
    ..persistentConnection = baseRequest.persistentConnection
    ..followRedirects = baseRequest.followRedirects
    ..maxRedirects = baseRequest.maxRedirects
    ..headers.addAll(baseRequest.headers)
    ..bodyBytes = bodyBytes
    ..finalize();
  final response = await handler(request);
  return http.StreamedResponse(
    Stream<List<int>>.value(response.bodyBytes),
    response.statusCode,
    contentLength: response.contentLength,
    request: response.request ?? request,
    headers: response.headers,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
});
