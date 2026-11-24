import 'dart:convert';

import 'package:http/http.dart' as http;

http.Response utf8Response(
  String body,
  int statusCode, {
  Map<String, String> headers = const {},
}) => http.Response.bytes(utf8.encode(body), statusCode, headers: headers);
