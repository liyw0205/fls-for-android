import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'local_install_manager.dart';
import 'local_panel_host.dart';
import 'operation_cancellation.dart';

typedef OnlineScriptsStatusCallback = void Function(String status);
typedef OnlineScriptsLogCallback = void Function(String log);
typedef OnlineScriptsProgressCallback =
    void Function(int receivedBytes, int? totalBytes);

enum OnlineScriptUpdateState { notInstalled, upToDate, updateAvailable }

class OnlineScriptUpdateResult {
  const OnlineScriptUpdateResult({required this.state, this.remoteRevision});

  final OnlineScriptUpdateState state;
  final String? remoteRevision;
}

class OnlineScript {
  const OnlineScript({
    required this.id,
    required this.name,
    required this.type,
    required this.link,
    required this.linkName,
    required this.installCommand,
    this.docLink,
  });

  final String id;
  final String name;
  final String type;
  final Uri link;
  final String linkName;
  final String installCommand;
  final Uri? docLink;

  factory OnlineScript.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    final type = json['type']?.toString().trim() ?? '';
    final link = _httpsUri(json['link']);
    final docLink = _httpsUri(json['doc_link'], required: false);
    if (!RegExp(r'^[A-Za-z0-9._-]{1,120}$').hasMatch(id) ||
        name.isEmpty ||
        !{'raw', 'repo'}.contains(type) ||
        link == null ||
        (json['doc_link'] != null && docLink == null)) {
      throw const FormatException('在线脚本条目无效');
    }
    return OnlineScript(
      id: id,
      name: name,
      type: type,
      link: link,
      linkName: json['link_name']?.toString().trim().isNotEmpty == true
          ? json['link_name'].toString().trim()
          : name,
      installCommand: json['install']?.toString() ?? '',
      docLink: docLink,
    );
  }

  static Uri? _httpsUri(Object? value, {bool required = true}) {
    if (value == null && !required) return null;
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }
}

class OnlineScriptsCatalogSnapshot {
  const OnlineScriptsCatalogSnapshot({
    required this.scripts,
    required this.lastCheckedAt,
    this.lastSyncedAt,
    this.fromCache = false,
    this.refreshError,
    this.changes,
  });

  final List<OnlineScript> scripts;
  final DateTime? lastCheckedAt;
  final DateTime? lastSyncedAt;
  final bool fromCache;
  final String? refreshError;
  final OnlineScriptsCatalogChanges? changes;
}

class OnlineScriptsCatalogChanges {
  const OnlineScriptsCatalogChanges({
    required this.added,
    required this.removed,
    required this.updated,
  });

  final int added;
  final int removed;
  final int updated;

  bool get hasChanges => added + removed + updated > 0;
}

class OnlineScriptInstallConflict implements Exception {
  const OnlineScriptInstallConflict();
}

class OnlineScriptsManager {
  OnlineScriptsManager({http.Client? client, Uri? catalogUri})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      catalogUri = catalogUri ?? defaultCatalogUri;

  static final Uri defaultCatalogUri = Uri.parse(
    'https://cdn.jsdelivr.net/gh/liyw0205/fls-scripts@main/index.json',
  );

  static const _maxDownloadBytes = 100 * 1024 * 1024;
  static const _maxCatalogBytes = 5 * 1024 * 1024;
  static const _maxExtractedBytes = 300 * 1024 * 1024;
  static const _maxArchiveEntries = 20000;

  final http.Client _client;
  final Uri catalogUri;
  final bool _ownsClient;

  Future<List<OnlineScript>> fetchCatalog() async =>
      (await fetchCatalogSnapshot()).scripts;

  Future<OnlineScriptsCatalogSnapshot?> readCachedCatalog() async {
    final preferences = await _getPreferences();
    if (preferences == null) return null;
    final cached = _readCachedCatalog(preferences.getString(_catalogCacheKey));
    if (cached == null) return null;
    return OnlineScriptsCatalogSnapshot(
      scripts: _parseCatalog(cached.body),
      lastCheckedAt: cached.checkedAt,
      lastSyncedAt: cached.syncedAt,
      fromCache: true,
    );
  }

  Future<OnlineScriptsCatalogSnapshot> fetchCatalogSnapshot() async {
    final preferences = await _getPreferences();
    final cached = preferences == null
        ? null
        : _readCachedCatalog(preferences.getString(_catalogCacheKey));
    final request = http.Request('GET', catalogUri)
      ..headers['Accept'] = 'application/json';
    if (cached?.etag case final etag?) {
      request.headers['If-None-Match'] = etag;
    }
    if (cached?.lastModified case final lastModified?) {
      request.headers['If-Modified-Since'] = lastModified;
    }

    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      final checkedAt = DateTime.now().toUtc();
      if (response.statusCode == 304) {
        await response.stream.drain<void>();
        if (cached == null) {
          throw StateError('在线脚本目录返回了无缓存的 HTTP 304');
        }
        if (preferences != null) {
          await _writeCachedCatalog(
            preferences,
            cached.copyWith(checkedAt: checkedAt),
          );
        }
        return OnlineScriptsCatalogSnapshot(
          scripts: _parseCatalog(cached.body),
          lastCheckedAt: checkedAt,
          lastSyncedAt: cached.syncedAt,
          fromCache: true,
        );
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw StateError('读取在线脚本目录失败：HTTP ${response.statusCode}');
      }
      if ((response.contentLength ?? 0) > _maxCatalogBytes) {
        await response.stream.drain<void>();
        throw const FormatException('在线脚本目录超过 5 MB');
      }
      final bodyBytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (bodyBytes.length + chunk.length > _maxCatalogBytes) {
          throw const FormatException('在线脚本目录超过 5 MB');
        }
        bodyBytes.addAll(chunk);
      }
      final body = utf8.decode(bodyBytes);
      final scripts = _parseCatalog(body);
      final changes = cached == null
          ? null
          : _compareCatalogs(_parseCatalog(cached.body), scripts);
      final nextCache = _CachedOnlineScriptsCatalog(
        body: body,
        etag: response.headers['etag'],
        lastModified: response.headers['last-modified'],
        syncedAt: checkedAt,
        checkedAt: checkedAt,
      );
      if (preferences != null) {
        await _writeCachedCatalog(preferences, nextCache);
      }
      return OnlineScriptsCatalogSnapshot(
        scripts: scripts,
        lastCheckedAt: checkedAt,
        lastSyncedAt: checkedAt,
        changes: changes,
      );
    } catch (error) {
      if (cached == null) rethrow;
      return OnlineScriptsCatalogSnapshot(
        scripts: _parseCatalog(cached.body),
        lastCheckedAt: cached.checkedAt,
        lastSyncedAt: cached.syncedAt,
        fromCache: true,
        refreshError: error.toString(),
      );
    }
  }

  List<OnlineScript> _parseCatalog(String body) {
    final value = jsonDecode(body);
    if (value is! List) throw const FormatException('在线脚本目录格式无效');
    final items = <OnlineScript>[];
    final ids = <String>{};
    for (final item in value) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final script = OnlineScript.fromJson(item);
        if (ids.add(script.id)) items.add(script);
      } on FormatException {
        continue;
      }
    }
    return items;
  }

  OnlineScriptsCatalogChanges _compareCatalogs(
    List<OnlineScript> previous,
    List<OnlineScript> current,
  ) {
    final oldById = {for (final script in previous) script.id: script};
    final newById = {for (final script in current) script.id: script};
    var updated = 0;
    for (final entry in oldById.entries) {
      final currentScript = newById[entry.key];
      if (currentScript != null &&
          _catalogFingerprint(entry.value) !=
              _catalogFingerprint(currentScript)) {
        updated++;
      }
    }
    return OnlineScriptsCatalogChanges(
      added: newById.keys.where((id) => !oldById.containsKey(id)).length,
      removed: oldById.keys.where((id) => !newById.containsKey(id)).length,
      updated: updated,
    );
  }

  String _catalogFingerprint(OnlineScript script) => jsonEncode([
    script.name,
    script.type,
    script.link.toString(),
    script.linkName,
    script.installCommand,
    script.docLink?.toString(),
  ]);

  String get _catalogCacheKey =>
      'online_scripts_catalog_${sha256.convert(utf8.encode(catalogUri.toString())).toString().substring(0, 20)}';

  Future<SharedPreferences?> _getPreferences() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  _CachedOnlineScriptsCatalog? _readCachedCatalog(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) return null;
      final body = decoded['body'];
      final syncedAt = DateTime.tryParse(
        decoded['synced_at']?.toString() ?? '',
      );
      final checkedAt = DateTime.tryParse(
        decoded['checked_at']?.toString() ?? '',
      );
      if (body is! String || syncedAt == null || checkedAt == null) return null;
      _parseCatalog(body);
      return _CachedOnlineScriptsCatalog(
        body: body,
        etag: decoded['etag']?.toString(),
        lastModified: decoded['last_modified']?.toString(),
        syncedAt: syncedAt,
        checkedAt: checkedAt,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeCachedCatalog(
    SharedPreferences preferences,
    _CachedOnlineScriptsCatalog cache,
  ) async {
    try {
      await preferences.setString(
        _catalogCacheKey,
        jsonEncode({
          'body': cache.body,
          'etag': cache.etag,
          'last_modified': cache.lastModified,
          'synced_at': cache.syncedAt.toIso8601String(),
          'checked_at': cache.checkedAt.toIso8601String(),
        }),
      );
    } catch (_) {
      // Catalog rendering must keep working if local cache storage is unavailable.
    }
  }

  Future<String> fetchDocument(OnlineScript script) async {
    final uri = script.docLink;
    if (uri == null) return '';
    return _fetchText(
      uri,
      headers: const {'Accept': 'text/plain, text/markdown, */*'},
      maximumBytes: 1024 * 1024,
      errorLabel: '脚本文档',
    );
  }

  Future<bool> hasInstallTarget(
    OnlineScript script,
    LocalInstallManager installManager,
  ) async {
    final targetPath = await _targetPath(script, installManager);
    return await FileSystemEntity.type(targetPath, followLinks: false) !=
        FileSystemEntityType.notFound;
  }

  Future<void> installOrUpdateNative({
    required OnlineScript script,
    required LocalInstallManager installManager,
    required bool overwriteExisting,
    required OperationCancellation cancellation,
    required OnlineScriptsStatusCallback onStatus,
    OnlineScriptsLogCallback? onLog,
    OnlineScriptsProgressCallback? onProgress,
  }) async {
    cancellation.throwIfCancelled();
    if (!await installManager.hasRuntime()) {
      throw StateError('请先安装本机 Python 或 Full 运行环境。');
    }

    final runtime = await installManager.runtime;
    final project = await installManager.project;
    final data = await installManager.data;
    final logs = await installManager.logs;
    final scripts = await installManager.scripts;
    await Future.wait([
      project.create(recursive: true),
      data.create(recursive: true),
      logs.create(recursive: true),
      scripts.create(recursive: true),
      Directory(p.join(runtime.path, 'tmp')).create(recursive: true),
    ]);

    final targetPath = await _targetPath(script, installManager);
    final targetType = await FileSystemEntity.type(
      targetPath,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound && !overwriteExisting) {
      throw const OnlineScriptInstallConflict();
    }
    if (targetType == FileSystemEntityType.link) {
      throw StateError('脚本安装位置是符号链接，拒绝覆盖。');
    }
    if ((script.type == 'raw' &&
            targetType == FileSystemEntityType.directory) ||
        (script.type == 'repo' && targetType == FileSystemEntityType.file)) {
      throw StateError('脚本安装位置与目标类型冲突，拒绝覆盖。');
    }

    final operationKey = _randomId();
    final staging = Directory(
      p.join(scripts.path, '.fls-script-$operationKey'),
    );
    final backup = Directory(
      p.join(scripts.path, '.fls-script-backup-$operationKey'),
    );
    final journal = <_FileBackup>[];
    var targetCreated = false;
    String? remoteRevision;

    try {
      await staging.create(recursive: true);
      onStatus('读取脚本来源');
      if (script.type == 'raw') {
        _safeRelativePath(script.linkName);
        final content = await _downloadBytes(
          script.link,
          cancellation: cancellation,
          headers: const {'Accept': '*/*'},
          maximumBytes: _maxDownloadBytes,
          onProgress: onProgress,
        );
        cancellation.throwIfCancelled();
        final stagedFile = File(p.join(staging.path, 'payload'));
        await stagedFile.writeAsBytes(content, flush: true);
        final destination = File(targetPath);
        await _validateParentChain(scripts, destination.parent);
        await destination.parent.create(recursive: true);
        await _backupAndCopy(
          stagedFile,
          destination,
          script.linkName,
          scripts,
          backup,
          journal,
        );
        targetCreated = true;
        if (p.extension(destination.path).toLowerCase() == '.sh') {
          final chmod = await Process.run('/system/bin/chmod', [
            '755',
            destination.path,
          ]);
          if (chmod.exitCode != 0) {
            throw StateError('无法设置脚本执行权限：${chmod.stderr}');
          }
        }
      } else {
        final repoInfo = await _repositoryInfo(script.link, cancellation);
        remoteRevision = repoInfo.commitSha;
        final bytes = await _downloadBytes(
          _repositoryArchiveUri(repoInfo),
          cancellation: cancellation,
          headers: const {'Accept': 'application/vnd.github+json'},
          maximumBytes: _maxDownloadBytes,
          onProgress: onProgress,
        );
        cancellation.throwIfCancelled();
        onStatus('校验并解压脚本仓库');
        final extracted = Directory(p.join(staging.path, 'repository'));
        await _extractRepository(bytes, extracted, cancellation);
        final repoTarget = Directory(targetPath);
        final extractedFiles = extracted.list(
          recursive: true,
          followLinks: false,
        );
        await for (final entity in extractedFiles) {
          cancellation.throwIfCancelled();
          if (entity is! File) continue;
          final relative = p.relative(entity.path, from: extracted.path);
          final destination = File(p.join(repoTarget.path, relative));
          await _validateParentChain(scripts, destination.parent);
          await destination.parent.create(recursive: true);
          await _backupAndCopy(
            entity,
            destination,
            relative,
            scripts,
            backup,
            journal,
          );
        }
        targetCreated = true;
      }

      cancellation.throwIfCancelled();
      if (script.installCommand.trim().isNotEmpty) {
        onStatus('安装脚本依赖');
        final runCommand = LocalPanelHost.runContainerCommand(
          runtimeDir: runtime.path,
          projectDir: project.path,
          dataDir: data.path,
          logDir: logs.path,
          scriptsDir: scripts.path,
          command: script.installCommand,
          onOutput: (line) => onLog?.call(line),
        );
        final exitCode = await Future.any<int>([
          runCommand,
          cancellation.whenCancelled.then<int>((_) async {
            await LocalPanelHost.cancelContainerCommand();
            throw const OperationCancelled();
          }),
        ]);
        cancellation.throwIfCancelled();
        if (exitCode != 0) {
          throw StateError('在线脚本依赖安装失败，退出码：$exitCode');
        }
      }
      if (remoteRevision != null) {
        await _saveInstallState(script, installManager, remoteRevision);
      }
      onStatus('安装完成');
    } catch (_) {
      if (targetCreated || journal.isNotEmpty) {
        await _rollbackFiles(journal);
        if (script.type == 'repo' && !overwriteExisting) {
          final repoTarget = Directory(targetPath);
          if (await repoTarget.exists()) {
            await repoTarget.delete(recursive: true);
          }
        }
      }
      rethrow;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
      if (await backup.exists()) await backup.delete(recursive: true);
    }
  }

  Future<OnlineScriptUpdateResult> checkForUpdate({
    required OnlineScript script,
    required LocalInstallManager installManager,
    required OperationCancellation cancellation,
    required OnlineScriptsStatusCallback onStatus,
    OnlineScriptsProgressCallback? onProgress,
  }) async {
    cancellation.throwIfCancelled();
    final targetPath = await _targetPath(script, installManager);
    final targetType = await FileSystemEntity.type(
      targetPath,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.notFound) {
      return const OnlineScriptUpdateResult(
        state: OnlineScriptUpdateState.notInstalled,
      );
    }
    if (targetType == FileSystemEntityType.link ||
        (script.type == 'raw' && targetType != FileSystemEntityType.file) ||
        (script.type == 'repo' &&
            targetType != FileSystemEntityType.directory)) {
      throw StateError('本机脚本目标类型异常，无法检查更新。');
    }

    if (script.type == 'raw') {
      onStatus('下载远端脚本并比对');
      final remoteBytes = await _downloadBytes(
        script.link,
        cancellation: cancellation,
        headers: const {'Accept': '*/*'},
        maximumBytes: _maxDownloadBytes,
        onProgress: onProgress,
      );
      cancellation.throwIfCancelled();
      final localFile = File(targetPath);
      final localLength = await localFile.length();
      final remoteRevision = sha256.convert(remoteBytes).toString();
      final installedRevision = localLength == remoteBytes.length
          ? await _fileSha256(localFile)
          : '';
      return OnlineScriptUpdateResult(
        state: installedRevision == remoteRevision
            ? OnlineScriptUpdateState.upToDate
            : OnlineScriptUpdateState.updateAvailable,
        remoteRevision: remoteRevision,
      );
    }

    onStatus('读取脚本仓库版本');
    final repository = await _repositoryInfo(script.link, cancellation);
    final installedState = await _readInstallState(script, installManager);
    if (installedState != null) {
      return OnlineScriptUpdateResult(
        state: installedState == repository.commitSha
            ? OnlineScriptUpdateState.upToDate
            : OnlineScriptUpdateState.updateAvailable,
        remoteRevision: repository.commitSha,
      );
    }

    onStatus('首次检查，下载仓库进行比对');
    final bytes = await _downloadBytes(
      _repositoryArchiveUri(repository),
      cancellation: cancellation,
      headers: const {'Accept': 'application/vnd.github+json'},
      maximumBytes: _maxDownloadBytes,
      onProgress: onProgress,
    );
    cancellation.throwIfCancelled();
    final root = await installManager.root;
    final staging = Directory(p.join(root.path, '.fls-check-${_randomId()}'));
    try {
      await staging.create(recursive: true);
      final extracted = Directory(p.join(staging.path, 'repository'));
      await _extractRepository(bytes, extracted, cancellation);
      final matches = await _repositoryMatchesInstalled(
        extracted,
        Directory(targetPath),
        cancellation,
      );
      if (matches) {
        await _saveInstallState(script, installManager, repository.commitSha);
      }
      return OnlineScriptUpdateResult(
        state: matches
            ? OnlineScriptUpdateState.upToDate
            : OnlineScriptUpdateState.updateAvailable,
        remoteRevision: repository.commitSha,
      );
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<String> _targetPath(
    OnlineScript script,
    LocalInstallManager installManager,
  ) async {
    final scripts = await installManager.scripts;
    final relative = _safeRelativePath(script.linkName);
    if (script.type == 'repo' && p.split(relative).length != 1) {
      throw const FormatException('脚本仓库目录名无效');
    }
    final target = p.join(scripts.path, relative);
    await _validateParentChain(scripts, Directory(p.dirname(target)));
    return target;
  }

  String _safeRelativePath(String value) {
    final normalized = value.replaceAll('\\', '/').trim();
    final segments = normalized.split('/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        segments.any(
          (segment) =>
              segment.isEmpty ||
              segment == '.' ||
              segment == '..' ||
              !RegExp(r'^[A-Za-z0-9._ -]{1,160}$').hasMatch(segment),
        )) {
      throw const FormatException('在线脚本路径包含不支持的字符');
    }
    return p.joinAll(segments);
  }

  Future<_GithubRepository> _repositoryInfo(
    Uri uri,
    OperationCancellation cancellation,
  ) async {
    if (uri.host != 'github.com') {
      throw const FormatException('目前仅支持从 GitHub 安装仓库脚本');
    }
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.length != 2) {
      throw const FormatException('GitHub 仓库地址格式无效');
    }
    final owner = segments[0];
    final repository = segments[1].replaceFirst(RegExp(r'\.git$'), '');
    if (![
      owner,
      repository,
    ].every((part) => RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(part))) {
      throw const FormatException('GitHub 仓库地址格式无效');
    }
    final response = await _send(
      Uri.https('api.github.com', '/repos/$owner/$repository'),
      cancellation,
      headers: const {'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw StateError('读取脚本仓库失败：HTTP ${response.statusCode}');
    }
    final body = await _readLimited(response, 1024 * 1024, cancellation);
    final value = jsonDecode(body);
    final branch = value is Map<String, dynamic>
        ? value['default_branch']?.toString() ?? ''
        : '';
    if (!RegExp(r'^[A-Za-z0-9._/-]{1,100}$').hasMatch(branch) ||
        branch.split('/').any((part) => part == '..' || part.isEmpty)) {
      throw const FormatException('脚本仓库默认分支无效');
    }
    final commitResponse = await _send(
      Uri(
        scheme: 'https',
        host: 'api.github.com',
        pathSegments: ['repos', owner, repository, 'commits', branch],
      ),
      cancellation,
      headers: const {'Accept': 'application/vnd.github+json'},
    );
    if (commitResponse.statusCode != 200) {
      await commitResponse.stream.drain<void>();
      throw StateError('读取脚本仓库提交版本失败：HTTP ${commitResponse.statusCode}');
    }
    final commitBody = await _readLimited(
      commitResponse,
      1024 * 1024,
      cancellation,
    );
    final commitValue = jsonDecode(commitBody);
    final commitSha = commitValue is Map<String, dynamic>
        ? commitValue['sha']?.toString() ?? ''
        : '';
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(commitSha)) {
      throw const FormatException('脚本仓库提交版本无效');
    }
    return _GithubRepository(owner, repository, branch, commitSha);
  }

  Uri _repositoryArchiveUri(_GithubRepository repository) => Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: [
      'repos',
      repository.owner,
      repository.repository,
      'zipball',
      repository.commitSha,
    ],
  );

  Future<bool> _repositoryMatchesInstalled(
    Directory extracted,
    Directory installed,
    OperationCancellation cancellation,
  ) async {
    final remoteFiles = <String>{};
    await for (final entity in extracted.list(
      recursive: true,
      followLinks: false,
    )) {
      cancellation.throwIfCancelled();
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: extracted.path);
      remoteFiles.add(relative);
      final localFile = File(p.join(installed.path, relative));
      if (await FileSystemEntity.type(localFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      if (await entity.length() != await localFile.length() ||
          await _fileSha256(entity) != await _fileSha256(localFile)) {
        return false;
      }
    }
    final installedFiles = <String>{};
    await for (final entity in installed.list(
      recursive: true,
      followLinks: false,
    )) {
      cancellation.throwIfCancelled();
      if (entity is Link) return false;
      if (entity is File) {
        installedFiles.add(p.relative(entity.path, from: installed.path));
      }
    }
    return remoteFiles.length == installedFiles.length &&
        remoteFiles.containsAll(installedFiles);
  }

  Future<String> _fileSha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<String?> _readInstallState(
    OnlineScript script,
    LocalInstallManager installManager,
  ) async {
    final file = await _installStateFile(script, installManager);
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> ||
          value['type'] != script.type ||
          value['link'] != script.link.toString() ||
          value['link_name'] != script.linkName) {
        return null;
      }
      final revision = value['revision']?.toString() ?? '';
      return RegExp(r'^[a-f0-9]{40}$').hasMatch(revision) ? revision : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _saveInstallState(
    OnlineScript script,
    LocalInstallManager installManager,
    String revision,
  ) async {
    final root = await installManager.root;
    final directory = Directory(p.join(root.path, 'script-state'));
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, '${script.id}.json'));
    final temporary = File(
      p.join(directory.path, '${script.id}.${_randomId()}.tmp'),
    );
    try {
      await temporary.writeAsString(
        jsonEncode({
          'type': script.type,
          'link': script.link.toString(),
          'link_name': script.linkName,
          'revision': revision,
        }),
        flush: true,
      );
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<File> _installStateFile(
    OnlineScript script,
    LocalInstallManager installManager,
  ) async {
    final root = await installManager.root;
    return File(p.join(root.path, 'script-state', '${script.id}.json'));
  }

  Future<void> _extractRepository(
    List<int> bytes,
    Directory destination,
    OperationCancellation cancellation,
  ) async {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.length > _maxArchiveEntries) {
      throw const FormatException('脚本仓库文件数量超过限制');
    }
    String? root;
    var extractedSize = 0;
    for (final entry in archive.files) {
      cancellation.throwIfCancelled();
      final name = entry.name.replaceAll('\\', '/');
      if (name.startsWith('/')) {
        throw const FormatException('脚本仓库包含绝对路径');
      }
      final segments = name.split('/');
      if (segments.any((part) => part == '..')) {
        throw const FormatException('脚本仓库包含越界路径');
      }
      if (segments.isEmpty || segments.first.isEmpty) continue;
      root ??= segments.first;
      if (segments.first != root) {
        throw const FormatException('脚本仓库压缩包结构无效');
      }
      if (entry.isSymbolicLink) continue;
      if (!entry.isFile) continue;
      extractedSize += entry.size;
      if (extractedSize > _maxExtractedBytes) {
        throw const FormatException('脚本仓库解压后超过 300 MB');
      }
      final relative = segments.skip(1).toList();
      if (relative.isEmpty) continue;
      final path = _safeRelativePath(relative.join('/'));
      final file = File(p.join(destination.path, path));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.content, flush: false);
    }
    if (root == null || extractedSize == 0) {
      throw const FormatException('脚本仓库中没有可安装的文件');
    }
  }

  Future<void> _backupAndCopy(
    File source,
    File destination,
    String relativePath,
    Directory scriptsRoot,
    Directory backupRoot,
    List<_FileBackup> journal,
  ) async {
    final relative = _safeRelativePath(relativePath);
    await _validateParentChain(scriptsRoot, destination.parent);
    final type = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.directory) {
      throw StateError('脚本目标路径与已有文件类型冲突：${destination.path}');
    }
    File? backup;
    if (type == FileSystemEntityType.file) {
      backup = File(p.join(backupRoot.path, relative));
      await backup.parent.create(recursive: true);
      await destination.copy(backup.path);
    }
    journal.add(_FileBackup(destination, backup));
    await source.copy(destination.path);
  }

  Future<void> _validateParentChain(
    Directory scriptsRoot,
    Directory targetParent,
  ) async {
    final relative = p.relative(targetParent.path, from: scriptsRoot.path);
    if (relative == '..' || relative.startsWith('../')) {
      throw StateError('脚本安装路径超出本机脚本目录，拒绝安装。');
    }
    var parent = scriptsRoot.path;
    final rootType = await FileSystemEntity.type(parent, followLinks: false);
    if (rootType == FileSystemEntityType.link ||
        (rootType != FileSystemEntityType.notFound &&
            rootType != FileSystemEntityType.directory)) {
      throw StateError('本机脚本目录不是安全目录，拒绝安装。');
    }
    if (relative == '.') return;
    for (final segment in p.split(relative)) {
      parent = p.join(parent, segment);
      final type = await FileSystemEntity.type(parent, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.directory)) {
        throw StateError('脚本安装路径包含符号链接或非目录，拒绝安装。');
      }
    }
  }

  Future<void> _rollbackFiles(List<_FileBackup> journal) async {
    for (final item in journal.reversed) {
      if (await item.destination.exists()) await item.destination.delete();
      final backup = item.backup;
      if (backup != null && await backup.exists()) {
        await backup.copy(item.destination.path);
      }
    }
  }

  Future<List<int>> _downloadBytes(
    Uri uri, {
    required OperationCancellation cancellation,
    required Map<String, String> headers,
    required int maximumBytes,
    OnlineScriptsProgressCallback? onProgress,
  }) async {
    final response = await _send(uri, cancellation, headers: headers);
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw StateError('下载脚本来源失败：HTTP ${response.statusCode}');
    }
    final total = response.contentLength;
    if (total != null && total > maximumBytes) {
      await response.stream.drain<void>();
      throw FormatException('脚本来源超过 ${maximumBytes ~/ (1024 * 1024)} MB');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 45),
    )) {
      cancellation.throwIfCancelled();
      if (bytes.length + chunk.length > maximumBytes) {
        throw FormatException('脚本来源超过 ${maximumBytes ~/ (1024 * 1024)} MB');
      }
      bytes.addAll(chunk);
      onProgress?.call(bytes.length, total);
    }
    return bytes;
  }

  Future<String> _fetchText(
    Uri uri, {
    required Map<String, String> headers,
    required int maximumBytes,
    required String errorLabel,
  }) async {
    final request = http.Request('GET', uri)..headers.addAll(headers);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw StateError('读取$errorLabel失败：HTTP ${response.statusCode}');
    }
    if ((response.contentLength ?? 0) > maximumBytes) {
      await response.stream.drain<void>();
      throw FormatException(
        '$errorLabel超过 ${maximumBytes ~/ (1024 * 1024)} MB',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw FormatException(
          '$errorLabel超过 ${maximumBytes ~/ (1024 * 1024)} MB',
        );
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Future<http.StreamedResponse> _send(
    Uri uri,
    OperationCancellation cancellation, {
    Map<String, String> headers = const {},
  }) async {
    cancellation.throwIfCancelled();
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: cancellation.whenCancelled,
    )..headers.addAll(headers);
    try {
      return await _client.send(request).timeout(const Duration(seconds: 45));
    } catch (_) {
      cancellation.throwIfCancelled();
      rethrow;
    }
  }

  Future<String> _readLimited(
    http.StreamedResponse response,
    int maximumBytes,
    OperationCancellation cancellation,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      cancellation.throwIfCancelled();
      if (bytes.length + chunk.length > maximumBytes) {
        throw const FormatException('GitHub 仓库信息超过限制');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  String _randomId() {
    final random = Random.secure();
    return List<int>.generate(
      12,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class _GithubRepository {
  const _GithubRepository(
    this.owner,
    this.repository,
    this.branch,
    this.commitSha,
  );

  final String owner;
  final String repository;
  final String branch;
  final String commitSha;
}

class _FileBackup {
  const _FileBackup(this.destination, this.backup);

  final File destination;
  final File? backup;
}

class _CachedOnlineScriptsCatalog {
  const _CachedOnlineScriptsCatalog({
    required this.body,
    required this.etag,
    required this.lastModified,
    required this.syncedAt,
    required this.checkedAt,
  });

  final String body;
  final String? etag;
  final String? lastModified;
  final DateTime syncedAt;
  final DateTime checkedAt;

  _CachedOnlineScriptsCatalog copyWith({DateTime? checkedAt}) =>
      _CachedOnlineScriptsCatalog(
        body: body,
        etag: etag,
        lastModified: lastModified,
        syncedAt: syncedAt,
        checkedAt: checkedAt ?? this.checkedAt,
      );
}
