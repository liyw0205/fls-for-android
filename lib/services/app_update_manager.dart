import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class AppReleaseCommit {
  const AppReleaseCommit({
    required this.sha,
    required this.message,
    required this.url,
  });

  final String sha;
  final String message;
  final Uri url;
}

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.tagName,
    required this.name,
    required this.body,
    required this.url,
    required this.commits,
    this.apkUrl,
  });

  final String tagName;
  final String name;
  final String body;
  final Uri url;
  final List<AppReleaseCommit> commits;
  final Uri? apkUrl;
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latest,
    required this.updateAvailable,
  });

  final String currentVersion;
  final AppReleaseInfo latest;
  final bool updateAvailable;
}

typedef AppVersionLoader = Future<String> Function();

class AppUpdateManager {
  AppUpdateManager({http.Client? client, AppVersionLoader? versionLoader})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _versionLoader = versionLoader ?? _loadInstalledVersion;

  static final _latestReleaseUri = Uri.parse(
    'https://api.github.com/repos/liyw0205/fls-for-android/releases/latest',
  );

  final http.Client _client;
  final bool _ownsClient;
  final AppVersionLoader _versionLoader;

  Future<AppUpdateInfo> checkForUpdates() async {
    final currentVersion = await _versionLoader();
    final response = await _client
        .get(
          _latestReleaseUri,
          headers: const {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('读取 FLS APP 最新版本失败：HTTP ${response.statusCode}');
    }
    final value = jsonDecode(response.body);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('FLS APP Release 信息格式无效');
    }
    final latest = _releaseFromJson(value);
    final comparison = _compareVersions(
      currentVersion,
      _versionFromTag(latest.tagName),
    );
    var commits = const <AppReleaseCommit>[];
    if (comparison < 0) {
      try {
        commits = await _fetchCommits(currentVersion, latest.tagName);
      } catch (_) {
        // The release still provides the update and its own release notes.
      }
    }
    return AppUpdateInfo(
      currentVersion: currentVersion,
      latest: AppReleaseInfo(
        tagName: latest.tagName,
        name: latest.name,
        body: latest.body,
        url: latest.url,
        apkUrl: latest.apkUrl,
        commits: commits,
      ),
      updateAvailable: comparison < 0,
    );
  }

  Future<List<AppReleaseCommit>> _fetchCommits(
    String currentVersion,
    String latestTag,
  ) async {
    final fromTag = 'v$currentVersion';
    if (!_validTag(fromTag) || !_validTag(latestTag)) return const [];
    final uri = Uri.parse(
      'https://api.github.com/repos/liyw0205/fls-for-android/compare/'
      '${Uri.encodeComponent(fromTag)}...${Uri.encodeComponent(latestTag)}?per_page=100',
    );
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 404 || response.statusCode == 422) {
      return const [];
    }
    if (response.statusCode != 200) {
      throw StateError('读取版本间提交记录失败：HTTP ${response.statusCode}');
    }
    final value = jsonDecode(response.body);
    final items = value is Map<String, dynamic> ? value['commits'] : null;
    if (items is! List) return const [];
    final commits = <AppReleaseCommit>[];
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      try {
        commits.add(_commitFromJson(item));
      } on FormatException {
        continue;
      }
    }
    return commits;
  }

  AppReleaseInfo _releaseFromJson(Map<String, dynamic> json) {
    final tag = json['tag_name']?.toString().trim() ?? '';
    final url = _githubUri(json['html_url']);
    final assets = json['assets'];
    Uri? apkUrl;
    if (assets is List) {
      for (final item in assets) {
        if (item is! Map<String, dynamic>) continue;
        final name = item['name']?.toString().toLowerCase() ?? '';
        if (!name.endsWith('.apk') || !name.contains('arm64')) continue;
        apkUrl = _githubUri(item['browser_download_url']);
        if (apkUrl != null) break;
      }
    }
    if (!_validTag(tag) || url == null) {
      throw const FormatException('FLS APP Release 信息无效');
    }
    return AppReleaseInfo(
      tagName: tag,
      name: json['name']?.toString().trim().isNotEmpty == true
          ? json['name'].toString().trim()
          : tag,
      body: json['body']?.toString().trim() ?? '',
      url: url,
      apkUrl: apkUrl,
      commits: const [],
    );
  }

  AppReleaseCommit _commitFromJson(Map<String, dynamic> json) {
    final sha = json['sha']?.toString() ?? '';
    final url = _githubUri(json['html_url']);
    final commit = json['commit'];
    final message = commit is Map<String, dynamic>
        ? commit['message']?.toString().trim().split('\n').first ?? ''
        : '';
    if (!RegExp(r'^[a-f0-9]{7,40}$').hasMatch(sha) ||
        message.isEmpty ||
        url == null) {
      throw const FormatException('版本提交信息无效');
    }
    return AppReleaseCommit(sha: sha, message: message, url: url);
  }

  Uri? _githubUri(Object? value) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      return null;
    }
    return uri;
  }

  String _versionFromTag(String tag) => tag.replaceFirst(RegExp(r'^v'), '');

  bool _validTag(String value) =>
      RegExp(r'^[vA-Za-z0-9][A-Za-z0-9._+\-]{0,100}$').hasMatch(value);

  int _compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    for (var index = 0; index < leftParts.length; index++) {
      final comparison = leftParts[index].compareTo(rightParts[index]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  List<int> _versionParts(String value) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?(?:[-+].*)?$',
    ).firstMatch(value.trim());
    if (match == null) throw FormatException('APP 版本号无效：$value');
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4) ?? '0'),
    ];
  }

  static Future<String> _loadInstalledVersion() async {
    final info = await PackageInfo.fromPlatform();
    final build = info.buildNumber.trim();
    return build.isEmpty ? info.version : '${info.version}+$build';
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
