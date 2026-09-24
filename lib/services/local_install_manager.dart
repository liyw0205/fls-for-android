import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'directory_replacement.dart';
import 'local_panel_host.dart';
import 'operation_cancellation.dart';
import 'runtime_path_validation.dart';

enum RuntimeProfile {
  python('python', 'Python'),
  all('all', 'Full');

  const RuntimeProfile(this.id, this.label);

  final String id;
  final String label;

  static RuntimeProfile? fromId(String value) {
    for (final profile in values) {
      if (profile.id == value) return profile;
    }
    return null;
  }
}

class RuntimeAsset {
  const RuntimeAsset({
    required this.name,
    required this.url,
    required this.sha256,
    required this.size,
  });

  final String name;
  final Uri url;
  final String sha256;
  final int size;
}

RuntimeAsset? selectRuntimeAsset(
  Map<String, dynamic> release,
  List<String> supportedAbis,
  RuntimeProfile profile,
) {
  final arch = supportedAbis.contains('arm64-v8a') ? 'arm64' : null;
  if (arch == null) return null;

  final assets = release['assets'];
  if (assets is! List) return null;
  final expectedName = 'fls-proot-${profile.id}-$arch.tar.gz';
  for (final item in assets) {
    if (item is! Map<String, dynamic> || item['name'] != expectedName) {
      continue;
    }
    final digest = item['digest']?.toString() ?? '';
    final url = Uri.tryParse(item['browser_download_url']?.toString() ?? '');
    final size = item['size'];
    final match = RegExp(r'^sha256:([0-9a-f]{64})$').firstMatch(digest);
    if (match == null ||
        url == null ||
        url.scheme != 'https' ||
        size is! int ||
        size <= 0) {
      return null;
    }
    return RuntimeAsset(
      name: expectedName,
      url: url,
      sha256: match.group(1)!,
      size: size,
    );
  }
  return null;
}

RuntimeAsset? selectPythonRuntimeAsset(
  Map<String, dynamic> release,
  List<String> supportedAbis,
) => selectRuntimeAsset(release, supportedAbis, RuntimeProfile.python);

Uri applyGithubMirror(Uri original, String? mirror) {
  final value = mirror?.trim() ?? '';
  if (value.isEmpty) return original;
  final parsed = Uri.tryParse(value);
  if (parsed == null ||
      !{'http', 'https'}.contains(parsed.scheme) ||
      parsed.userInfo.isNotEmpty) {
    throw const FormatException('GitHub 加速源必须是有效的 HTTP 或 HTTPS 地址');
  }
  if (value.contains('%s')) {
    return Uri.parse(value.replaceFirst('%s', original.toString()));
  }
  return Uri.parse('${value.replaceFirst(RegExp(r'/+$'), '')}/$original');
}

class LocalInstallManager {
  LocalInstallManager({http.Client? client})
    : _client = client ?? http.Client();

  static final _releaseUri = Uri.parse(
    'https://api.github.com/repos/liyw0205/fls/releases/tags/proot-runtime',
  );
  static final _repoUri = Uri.parse(
    'https://api.github.com/repos/liyw0205/fls',
  );
  static const _mirrorKey = 'github_mirror_v1';
  final http.Client _client;

  Future<Directory> get root async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'fls'));
  }

  Future<Directory> get runtime async =>
      Directory(p.join((await root).path, 'runtime'));
  Future<Directory> get project async =>
      Directory(p.join((await root).path, 'project'));
  Future<Directory> get data async =>
      Directory(p.join((await root).path, 'data'));
  Future<Directory> get logs async =>
      Directory(p.join((await root).path, 'log'));
  Future<Directory> get scripts async =>
      Directory(p.join((await root).path, 'scripts'));

  Future<bool> _hasRuntimeStructure() async {
    final dir = await runtime;
    final pythonExists = await runtimeFileExistsInRootfs(
      Directory(p.join(dir.path, 'rootfs')),
      'opt/fls-venv/bin/python',
    );
    final checks = await Future.wait([
      File(p.join(dir.path, 'bin', 'proot')).exists(),
      File(p.join(dir.path, 'libexec', 'proot', 'loader')).exists(),
      File(p.join(dir.path, 'lib', 'libandroid-shmem.so')).exists(),
      File(p.join(dir.path, 'lib', 'libtalloc.so')).exists(),
      File(p.join(dir.path, '.arch')).exists(),
    ]);
    return pythonExists && checks.every((exists) => exists);
  }

  Future<RuntimeProfile?> installedRuntimeProfile() async {
    if (!await _hasRuntimeStructure()) return null;
    final marker = File(p.join((await runtime).path, '.profile'));
    if (!await marker.exists()) return RuntimeProfile.python;
    return RuntimeProfile.fromId((await marker.readAsString()).trim());
  }

  Future<bool> hasRuntime({RuntimeProfile? profile}) async {
    final installed = await installedRuntimeProfile();
    return installed != null && (profile == null || installed == profile);
  }

  Future<bool> hasProject() async {
    final dir = await project;
    final checks = await Future.wait([
      File(p.join(dir.path, 'fls-manager.py')).exists(),
      Directory(p.join(dir.path, 'fls_manager')).exists(),
    ]);
    return checks.every((exists) => exists);
  }

  Future<String> loadGithubMirror() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_mirrorKey) ?? '';
  }

  Future<void> saveGithubMirror(String value) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = value.trim();
    if (normalized.isEmpty) {
      await prefs.remove(_mirrorKey);
    } else {
      await prefs.setString(_mirrorKey, normalized);
    }
  }

  Future<http.StreamedResponse> _sendCancellable(
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
      return await _client.send(request);
    } catch (_) {
      cancellation.throwIfCancelled();
      rethrow;
    }
  }

  Future<String> _readCancellable(
    http.StreamedResponse response,
    OperationCancellation cancellation,
  ) async {
    try {
      return await response.stream.bytesToString();
    } catch (_) {
      cancellation.throwIfCancelled();
      rethrow;
    }
  }

  Future<void> installRuntime({
    required List<String> supportedAbis,
    required ValueChanged<double> onProgress,
    required OperationCancellation cancellation,
    RuntimeProfile profile = RuntimeProfile.python,
    String? githubMirror,
  }) async {
    final response = await _sendCancellable(
      applyGithubMirror(_releaseUri, githubMirror),
      cancellation,
      headers: const {'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) {
      throw StateError('读取 PRoot Release 失败：HTTP ${response.statusCode}');
    }
    final release = jsonDecode(await _readCancellable(response, cancellation));
    cancellation.throwIfCancelled();
    if (release is! Map<String, dynamic>) {
      throw const FormatException('PRoot Release 格式无效');
    }
    final selectedAsset = selectRuntimeAsset(release, supportedAbis, profile);
    if (selectedAsset == null) {
      throw StateError('没有适用于此设备 ABI 的 ${profile.label} 容器镜像');
    }
    final asset = RuntimeAsset(
      name: selectedAsset.name,
      url: applyGithubMirror(selectedAsset.url, githubMirror),
      sha256: selectedAsset.sha256,
      size: selectedAsset.size,
    );

    final base = await root;
    final archive = File(p.join(base.path, '.${asset.name}.part'));
    final staging = Directory(p.join(base.path, '.runtime-staging'));
    await base.create(recursive: true);
    if (await staging.exists()) await staging.delete(recursive: true);

    try {
      await _downloadAndVerify(asset, archive, onProgress, cancellation);
      onProgress(0);
      await _activateRuntimeArchive(
        archive,
        staging,
        expectedProfile: profile,
        cancellation: cancellation,
      );
    } finally {
      if (await archive.exists()) await archive.delete();
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<RuntimeProfile> importRuntime(
    File archive, {
    required ValueChanged<double> onProgress,
    required OperationCancellation cancellation,
  }) async {
    final base = await root;
    final staging = Directory(p.join(base.path, '.runtime-import-staging'));
    await base.create(recursive: true);
    if (await staging.exists()) await staging.delete(recursive: true);
    try {
      final imported = await _activateRuntimeArchive(
        archive,
        staging,
        cancellation: cancellation,
      );
      cancellation.throwIfCancelled();
      onProgress(1);
      return imported;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<File> exportRuntime() async {
    if (!await hasRuntime()) {
      throw StateError('没有可导出的本机容器');
    }
    final base = await root;
    final profile = await installedRuntimeProfile();
    final archive = File(
      p.join(
        base.path,
        '.fls-container-${profile?.id ?? RuntimeProfile.python.id}-${DateTime.now().millisecondsSinceEpoch}.tar.gz',
      ),
    );
    final result = await Process.run('/system/bin/toybox', [
      'tar',
      '-czf',
      archive.path,
      '-C',
      (await runtime).path,
      '.',
    ]);
    if (result.exitCode != 0 || !await archive.exists()) {
      throw StateError('容器导出失败：${result.stderr}');
    }
    return archive;
  }

  Future<void> importServerDataArchive(
    File archive, {
    required OperationCancellation cancellation,
    required ValueChanged<double> onProgress,
  }) async {
    final base = await root;
    final staging = Directory(p.join(base.path, '.data-sync-staging'));
    await base.create(recursive: true);
    if (await staging.exists()) await staging.delete(recursive: true);
    try {
      await staging.create(recursive: true);
      await _validateDataArchive(archive, cancellation);
      onProgress(0.1);
      await _extractTarGz(archive, staging, cancellation: cancellation);
      cancellation.throwIfCancelled();

      final serverData = Directory(p.join(staging.path, 'data'));
      if (await FileSystemEntity.type(serverData.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException('远程备份中没有有效的 data 目录');
      }
      final stagedBackups = Directory(p.join(serverData.path, 'backups'));
      if (await stagedBackups.exists()) {
        await stagedBackups.delete(recursive: true);
      }
      final localBackups = Directory(p.join((await data).path, 'backups'));
      if (await localBackups.exists()) {
        await _copyDirectory(localBackups, stagedBackups, cancellation);
      }
      onProgress(0.9);
      cancellation.throwIfCancelled();
      await replaceDirectoryWithBackup(serverData, await data);
      onProgress(1);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> _validateDataArchive(
    File archive,
    OperationCancellation cancellation,
  ) async {
    final process = await Process.start('/system/bin/toybox', [
      'tar',
      '-tzf',
      archive.path,
    ]);
    cancellation.whenCancelled.then((_) => process.kill());
    final stderr = process.stderr.transform(utf8.decoder).join();
    var entries = 0;
    String? invalidPath;
    await for (final line
        in process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      cancellation.throwIfCancelled();
      entries++;
      final normalized = line.replaceAll('\\', '/');
      final parts = normalized.split('/');
      if (entries > 100000 ||
          normalized.startsWith('/') ||
          RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
          parts.contains('..') ||
          (normalized != 'data' &&
              normalized != 'dependencies.txt' &&
              !normalized.startsWith('data/'))) {
        invalidPath = line;
        process.kill();
        break;
      }
    }
    final exitCode = await process.exitCode;
    final errorText = await stderr;
    cancellation.throwIfCancelled();
    if (invalidPath != null) {
      throw const FormatException('远程 data 备份包含非法路径');
    }
    if (exitCode != 0 || entries == 0) {
      throw FormatException('远程 data 备份无法读取：$errorText');
    }

    final typeProcess = await Process.start('/system/bin/toybox', [
      'tar',
      '-tvzf',
      archive.path,
    ]);
    cancellation.whenCancelled.then((_) => typeProcess.kill());
    final typeStderr = typeProcess.stderr.transform(utf8.decoder).join();
    var typeEntries = 0;
    var invalidType = false;
    await for (final line
        in typeProcess.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      cancellation.throwIfCancelled();
      typeEntries++;
      if (line.isEmpty || (line[0] != '-' && line[0] != 'd')) {
        invalidType = true;
        typeProcess.kill();
        break;
      }
    }
    final typeExitCode = await typeProcess.exitCode;
    final typeErrorText = await typeStderr;
    cancellation.throwIfCancelled();
    if (invalidType) {
      throw const FormatException('远程 data 备份包含不支持的文件类型');
    }
    if (typeExitCode != 0 || typeEntries != entries) {
      throw FormatException('远程 data 备份无法校验：$typeErrorText');
    }
  }

  Future<void> _copyDirectory(
    Directory source,
    Directory destination,
    OperationCancellation cancellation,
  ) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      cancellation.throwIfCancelled();
      final target = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(target), cancellation);
      } else if (entity is File) {
        final iterator = StreamIterator<List<int>>(entity.openRead());
        final output = File(target).openWrite();
        try {
          while (await Future.any([
            iterator.moveNext(),
            cancellation.whenCancelled.then<bool>(
              (_) => throw const OperationCancelled(),
            ),
          ])) {
            cancellation.throwIfCancelled();
            output.add(iterator.current);
          }
          await output.flush();
        } finally {
          await iterator.cancel();
          await output.close();
        }
      } else {
        throw const FormatException('本地 backups 包含不支持的文件类型');
      }
    }
  }

  Future<void> updatePanel({
    required ValueChanged<double> onProgress,
    required OperationCancellation cancellation,
    String? githubMirror,
  }) async {
    final branchResponse = await _sendCancellable(
      applyGithubMirror(
        Uri.https(_repoUri.authority, '${_repoUri.path}/commits/main'),
        githubMirror,
      ),
      cancellation,
      headers: const {'Accept': 'application/vnd.github+json'},
    );
    if (branchResponse.statusCode != 200) {
      throw StateError('读取 FLS 版本失败：HTTP ${branchResponse.statusCode}');
    }
    final commit = jsonDecode(
      await _readCancellable(branchResponse, cancellation),
    );
    cancellation.throwIfCancelled();
    if (commit is! Map<String, dynamic> || commit['sha'] is! String) {
      throw const FormatException('FLS 版本信息格式无效');
    }
    final sha = commit['sha'] as String;
    final base = await root;
    final installedRevision = File(p.join(base.path, 'panel-revision'));
    if (await hasProject() &&
        await installedRevision.exists() &&
        (await installedRevision.readAsString()).trim() == sha) {
      onProgress(1);
      return;
    }
    final archive = File(p.join(base.path, '.fls-$sha.tar.gz.part'));
    final staging = Directory(p.join(base.path, '.project-staging'));
    await base.create(recursive: true);
    if (await staging.exists()) await staging.delete(recursive: true);

    try {
      await _downloadFile(
        applyGithubMirror(
          Uri.https('api.github.com', '/repos/liyw0205/fls/tarball/$sha'),
          githubMirror,
        ),
        archive,
        onProgress,
        cancellation,
      );
      await staging.create(recursive: true);
      onProgress(0);
      await _extractTarGz(archive, staging, cancellation: cancellation);
      cancellation.throwIfCancelled();
      Directory? extracted;
      await for (final entry in staging.list()) {
        if (entry is Directory) {
          extracted = entry;
          break;
        }
      }
      if (extracted == null ||
          !await File(p.join(extracted.path, 'fls-manager.py')).exists() ||
          !await Directory(p.join(extracted.path, 'fls_manager')).exists()) {
        throw const FormatException('FLS 源码包结构无效');
      }
      cancellation.throwIfCancelled();
      await replaceDirectoryWithBackup(extracted, await project);
      await File(p.join(base.path, 'panel-revision')).writeAsString(sha);
      await Future.wait([
        (await data).create(recursive: true),
        (await logs).create(recursive: true),
        (await scripts).create(recursive: true),
      ]);
    } finally {
      if (await archive.exists()) await archive.delete();
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> startPanel({required OperationCancellation cancellation}) async {
    final runtimeDir = await runtime;
    final projectDir = await project;
    if (!await hasRuntime() || !await hasProject()) {
      throw StateError('本机容器或 FLS 面板尚未安装');
    }
    await Future.wait([
      (await data).create(recursive: true),
      (await logs).create(recursive: true),
      (await scripts).create(recursive: true),
    ]);
    final started = await LocalPanelHost.start(
      runtimeDir: runtimeDir.path,
      projectDir: projectDir.path,
      dataDir: (await data).path,
      logDir: (await logs).path,
      scriptsDir: (await scripts).path,
    );
    if (!started) throw StateError('Android 本机面板服务启动失败');
    final client = http.Client();
    var attempts = 0;
    try {
      while (true) {
        cancellation.throwIfCancelled();
        attempts++;
        try {
          final request = http.AbortableRequest(
            'GET',
            Uri.parse('http://127.0.0.1:5700/'),
            abortTrigger: cancellation.whenCancelled,
          );
          final response = await client.send(request);
          final ready = response.statusCode >= 200 && response.statusCode < 500;
          await response.stream.drain<void>();
          if (ready) return;
        } catch (_) {
          cancellation.throwIfCancelled();
        }
        if (attempts % 4 == 0) {
          final status = await LocalPanelHost.status();
          final terminal =
              status.state == LocalPanelState.crashed ||
              status.state == LocalPanelState.failed ||
              status.state == LocalPanelState.interrupted ||
              (status.state == LocalPanelState.stopped && attempts >= 10);
          if (terminal) {
            throw StateError(
              '本机面板启动失败（${status.state.name}，退出码 ${status.exitCode ?? "未知"}）',
            );
          }
        }
        if (attempts >= 120) {
          throw StateError('等待本机面板启动超时，请查看诊断日志');
        }
        await cancellation.delay(const Duration(milliseconds: 500));
      }
    } on OperationCancelled {
      await LocalPanelHost.stop();
      rethrow;
    } catch (_) {
      try {
        final status = await LocalPanelHost.status();
        if (status.state == LocalPanelState.running ||
            status.state == LocalPanelState.starting ||
            status.state == LocalPanelState.retrying) {
          await LocalPanelHost.stop();
        }
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> _downloadAndVerify(
    RuntimeAsset asset,
    File destination,
    ValueChanged<double> onProgress,
    OperationCancellation cancellation,
  ) async {
    final response = await _sendCancellable(asset.url, cancellation);
    if (response.statusCode != 200) {
      throw StateError('下载 PRoot 失败：HTTP ${response.statusCode}');
    }
    if (response.contentLength != null &&
        response.contentLength != asset.size) {
      throw StateError('PRoot 镜像大小与 Release 元数据不一致');
    }
    final output = destination.openWrite();
    final hash = _DigestCollector();
    final converter = sha256.startChunkedConversion(hash);
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        output.add(chunk);
        converter.add(chunk);
        received += chunk.length;
        if (received > asset.size) {
          throw const FormatException('PRoot 镜像超过 Release 声明大小');
        }
        onProgress((received / asset.size).clamp(0.0, 1.0).toDouble());
      }
      converter.close();
      await output.flush();
      await output.close();
    } catch (_) {
      await output.close();
      cancellation.throwIfCancelled();
      rethrow;
    }
    if (hash.value?.toString() != asset.sha256) {
      await destination.delete();
      throw const FormatException('PRoot 镜像 SHA-256 校验失败');
    }
    if (received != asset.size) {
      await destination.delete();
      throw const FormatException('PRoot 镜像大小与 Release 元数据不一致');
    }
  }

  Future<void> _makeExecutable(File file) async {
    final result = await Process.run('/system/bin/chmod', ['755', file.path]);
    if (result.exitCode != 0 || !await file.exists()) {
      throw StateError('无法设置运行时可执行权限：${file.path}');
    }
  }

  Future<void> _downloadFile(
    Uri uri,
    File destination,
    ValueChanged<double> onProgress,
    OperationCancellation cancellation,
  ) async {
    final response = await _sendCancellable(uri, cancellation);
    if (response.statusCode != 200) {
      throw StateError('下载 FLS 失败：HTTP ${response.statusCode}');
    }
    final total = response.contentLength;
    var received = 0;
    final output = destination.openWrite();
    try {
      await for (final chunk in response.stream) {
        output.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          onProgress((received / total).clamp(0.0, 1.0).toDouble());
        }
      }
      await output.flush();
      await output.close();
    } catch (_) {
      await output.close();
      cancellation.throwIfCancelled();
      rethrow;
    }
  }

  Future<void> _extractTarGz(
    File archive,
    Directory destination, {
    OperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final process = await Process.start('/system/bin/toybox', [
      'tar',
      '-xzf',
      archive.path,
      '-C',
      destination.path,
    ]);
    final stdoutDone = process.stdout.drain<void>();
    final stderrText = process.stderr.transform(utf8.decoder).join();
    final exitCode = process.exitCode;
    final Object? result = cancellation == null
        ? await exitCode
        : await Future.any<Object?>([
            exitCode,
            cancellation.whenCancelled.then<Object?>((_) => null),
          ]);
    if (result == null) {
      process.kill();
      await exitCode;
      await stdoutDone;
      await stderrText;
      cancellation!.throwIfCancelled();
    }
    await stdoutDone;
    final errorText = await stderrText;
    cancellation?.throwIfCancelled();
    if (result is int && result != 0) {
      throw StateError('解压失败：$errorText');
    }
  }

  Future<RuntimeProfile> _activateRuntimeArchive(
    File archive,
    Directory staging, {
    RuntimeProfile? expectedProfile,
    OperationCancellation? cancellation,
  }) async {
    await staging.create(recursive: true);
    await _extractTarGz(archive, staging, cancellation: cancellation);
    cancellation?.throwIfCancelled();
    final proot = File(p.join(staging.path, 'bin', 'proot'));
    final loader = File(p.join(staging.path, 'libexec', 'proot', 'loader'));
    final pythonExists = await runtimeFileExistsInRootfs(
      Directory(p.join(staging.path, 'rootfs')),
      'opt/fls-venv/bin/python',
    );
    final requiredFiles = [
      proot,
      loader,
      File(p.join(staging.path, 'lib', 'libandroid-shmem.so')),
      File(p.join(staging.path, 'lib', 'libtalloc.so')),
      File(p.join(staging.path, '.arch')),
      File(p.join(staging.path, '.profile')),
    ];
    final missingFiles = <String>[];
    if (!pythonExists) missingFiles.add('rootfs/opt/fls-venv/bin/python');
    for (final file in requiredFiles) {
      if (!await file.exists()) {
        missingFiles.add(p.relative(file.path, from: staging.path));
      }
    }
    if (missingFiles.isNotEmpty) {
      throw FormatException('运行时镜像缺少必需文件：${missingFiles.join('、')}');
    }
    final arch = (await File(
      p.join(staging.path, '.arch'),
    ).readAsString()).trim();
    if (arch != 'arm64') {
      throw FormatException('运行时架构不匹配：$arch');
    }
    final profile = RuntimeProfile.fromId(
      (await File(p.join(staging.path, '.profile')).readAsString()).trim(),
    );
    if (profile == null ||
        (expectedProfile != null && profile != expectedProfile)) {
      throw const FormatException('运行时容器版本标记无效或与选择不一致');
    }
    await _makeExecutable(proot);
    await _makeExecutable(loader);
    final loader32 = File(p.join(staging.path, 'libexec', 'proot', 'loader32'));
    if (await loader32.exists()) await _makeExecutable(loader32);
    cancellation?.throwIfCancelled();
    await replaceDirectoryWithBackup(staging, await runtime);
    return profile;
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest digest) => value = digest;

  @override
  void close() {}
}
