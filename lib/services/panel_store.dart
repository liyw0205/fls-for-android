import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/panel_server.dart';

class PanelStore {
  static const _key = 'remote_panels_v1';

  Future<List<PanelServer>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(PanelServer.fromJson)
          .whereType<PanelServer>()
          .toList();
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(List<PanelServer> servers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(servers.map((server) => server.toJson()).toList()),
    );
  }
}
