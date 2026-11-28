import 'dart:convert';

import 'package:fls_for_android/services/panel_api_client.dart';
import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:http/http.dart' as http;

import 'panel_test_http.dart';

const cleanupPath = '/api/logs/cleanup';

Map<String, Object?> cleanupCapabilities() => {
  'ok': true,
  'capabilities': {
    'supported': true,
    'max_files': 200,
    'max_groups': 20,
    'preview_ttl_seconds': 600,
  },
};

Map<String, dynamic> cleanupPreview({
  List<String> groups = const [],
  int count = 2,
}) {
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  return {
    'ok': true,
    'preview': {
      'preview_id': 'a' * 32,
      'digest': 'b' * 64,
      'created_at': now,
      'expires_at': now + 600,
      'groups': groups,
      'group_versions': {for (final group in groups) group: 'c' * 64},
      'total_files': count,
      'total_bytes': count * 12,
      'items': [
        for (var index = 0; index < count; index++)
          {
            'filename': 'worker$index.log',
            'version': 'd' * 64,
            'group': groups.isEmpty ? 'Workers' : groups[index % groups.length],
            'size_bytes': 12,
            'status': 'ready',
          },
      ],
    },
  };
}

Map<String, Object?> cleanupResult(
  Map<String, dynamic> preview,
  String requestId, {
  List<String> statuses = const ['deleted', 'busy'],
  bool missing = false,
}) {
  final row = preview['preview'] as Map<String, dynamic>;
  final items = missing
      ? <Map<String, dynamic>>[]
      : [
          for (var index = 0; index < (row['items'] as List).length; index++)
            {
              ...(row['items'] as List)[index] as Map<String, dynamic>,
              'status': statuses[index],
            },
        ];
  return {
    'ok': true,
    'request': {
      'request_id': requestId,
      if (!missing) ...{
        'preview_id': row['preview_id'],
        'digest': row['digest'],
        'created_at': row['created_at'],
        'reconciled': false,
      },
      'status': missing
          ? 'missing'
          : statuses.contains('unknown')
          ? 'unknown'
          : 'completed',
      'items': items,
      'counts': {
        for (final status in [
          'deleted',
          'missing',
          'busy',
          'conflict',
          'failed',
          'unknown',
        ])
          status: items.where((item) => item['status'] == status).length,
      },
    },
  };
}

http.Response cleanupJson(Object value, [int status = 200]) =>
    utf8Response(jsonEncode(value), status);

PanelApiClient cleanupApi(
  Future<http.Response> Function(http.Request) handler,
) => PanelApiClient(
  baseUrl: 'https://fls.example',
  credentials: const PanelSessionCredentials(
    cookie: 'fls_native_session=cleanup',
    csrfToken: 'cleanup-csrf',
  ),
  client: panelMockClient(handler),
);
