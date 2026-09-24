import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'local_panel_host.dart';

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

RuntimeAsset? selectPythonRuntimeAsset(
  Map<String, dynamic> release,
  List<String> supportedAbis,
) {
  final arch = supportedAbis.contains('arm64-v8a') ? 'arm64' : null;
  if (arch == null) return null;

  final assets = release['assets'];
  if (assets is! List) return null;
  final expectedName = 'fls-proot-python-$arch.tar.gz';
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

class LocalInstallManager {
  LocalInstallManager({http.Client? client})
    : _client = client ?? http.Client();

  static final _releaseUri = Uri.parse(
    'https://api.github.com/repos/liyw0205/fls/releases/tags/proot-runtime',
  );
  static final _repoUri = Uri.parse(
    'https://api.github.com/repos/liyw0205/fls',
  );
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

  Future<bool> hasRuntime() async {
    final dir = await runtime;
    final checks = await Future.wait([
      File(
        p.join(dir.path, 'rootfs', 'opt', 'fls-venv', 'bin', 'python'),
      ).exists(),
      File(p.join(dir.path, 'bin', 'proot')).exists(),
      File(p.join(dir.path, 'libexec', 'proot', 'loader')).exists(),
      File(p.join(dir.path, 'lib', 'libandroid-shmem.so')).exists(),
      File(p.join(dir.path, 'lib', 'libtalloc.so')).exists(),
      File(p.join(dir.path, '.arch')).exists(),
    ]);
    return checks.every((exists) => exists);
  }

  Future<bool> hasProject() async {
    final dir = await project;
    final checks = await Future.wait([
      File(p.join(dir.path, 'fls-manager.py')).exists(),
      Directory(p.join(dir.path, 'fls_manager')).exists(),
    ]);
    return checks.every((exists) => exists);
  }

  Future<void> installRuntime({
    required List<String> supportedAbis,
    required ValueChanged<double> onProgress,
  }) async {
    final response = await _client.get(
      _releaseUri,
      headers: const {'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) {
      throw StateError('读取 PRoot Release 失败：HTTP ${response.statusCode}');
    }
    final release = jsonDecode(response.body);
    if (release is! Map<String, dynamic>) {
      throw const FormatException('PRoot Release 格式无效');
    }
    final asset = selectPythonRuntimeAsset(release, supportedAbis);
    if (asset == null) {
      throw StateError('没有适用于此设备 ABI 的 Python 容器镜像');
    }

    final base = await root;
    final archive = File(p.join(base.path, '.${asset.name}.part'));
    final staging = Directory(p.join(base.path, '.runtime-staging'));
    await base.create(recursive: true);
    if (await staging.exists()) await staging.delete(recursive: true);

    try {
      await _downloadAndVerify(asset, archive, onProgress);
      await staging.create(recursive: true);
      await _extractTarGz(archive, staging);
      final python = File(
        p.join(staging.path, 'rootfs', 'opt', 'fls-venv', 'bin', 'python'),
      );
      final proot = File(p.join(staging.path, 'bin', 'proot'));
      final loader = File(p.join(staging.path, 'libexec', 'proot', 'loader'));
      final requiredFiles = [
        python,
        proot,
        loader,
        File(p.join(staging.path, 'lib', 'libandroid-shmem.so')),
        File(p.join(staging.path, 'lib', 'libtalloc.so')),
        File(p.join(staging.path, '.arch')),
      ];
      if (!await Future.wait(
        requiredFiles.map((file) => file.exists()),
      ).then((exists) => exists.every((value) => value))) {
        throw const FormatException('运行时镜像缺少 PRoot、Python 或依赖库');
      }
      final arch = (await File(
        p.join(staging.path, '.arch'),
      ).readAsString()).trim();
      if (arch != 'arm64') {
        throw FormatException('运行时架构不匹配：$arch');
      }
      await _makeExecutable(proot);
      await _makeExecutable(loader);
      final loader32 = File(
        p.join(staging.path, 'libexec', 'proot', 'loader32'),
      );
      if (await loader32.exists()) await _makeExecutable(loader32);
      await _replaceDirectory(staging, await runtime);
    } finally {
      if (await archive.exists()) await archive.delete();
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> updatePanel({required ValueChanged<double> onProgress}) async {
    final branchResponse = await _client.get(
      Uri.https(_repoUri.authority, '${_repoUri.path}/commits/main'),
      headers: const {'Accept': 'application/vnd.github+json'},
    );
    if (branchResponse.statusCode != 200) {
      throw StateError('读取 FLS 版本失败：HTTP ${branchResponse.statusCode}');
    }
    final commit = jsonDecode(branchResponse.body);
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
        Uri.https('api.github.com', '/repos/liyw0205/fls/tarball/$sha'),
        archive,
        onProgress,
      );
      await staging.create(recursive: true);
      await _extractTarGz(archive, staging);
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
      await _replaceDirectory(extracted, await project);
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

  Future<void> startPanel() async {
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
    try {
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          final response = await client
              .get(Uri.parse('http://127.0.0.1:5700/'))
              .timeout(const Duration(seconds: 2));
          if (response.statusCode >= 200 && response.statusCode < 500) return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    } finally {
      client.close();
    }
    throw StateError('本机 FLS 未能在 20 秒内就绪，请检查本机面板日志');
  }

  Future<void> _downloadAndVerify(
    RuntimeAsset asset,
    File destination,
    ValueChanged<double> onProgress,
  ) async {
    final response = await _client.send(http.Request('GET', asset.url));
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
        onProgress((received / asset.size).clamp(0.0, 1.0));
      }
      converter.close();
      await output.flush();
      await output.close();
    } catch (_) {
      await output.close();
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
  ) async {
    final response = await _client.send(http.Request('GET', uri));
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
          onProgress((received / total).clamp(0.0, 1.0));
        }
      }
      await output.flush();
      await output.close();
    } catch (_) {
      await output.close();
      rethrow;
    }
  }

  Future<void> _extractTarGz(File archive, Directory destination) async {
    final result = await Process.run('/system/bin/toybox', [
      'tar',
      '-xzf',
      archive.path,
      '-C',
      destination.path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('解压失败：${result.stderr}');
    }
  }

  Future<void> _replaceDirectory(Directory staged, Directory target) async {
    final backup = Directory('${target.path}.previous');
    if (await backup.exists()) await backup.delete(recursive: true);
    if (await target.exists()) await target.rename(backup.path);
    try {
      await staged.rename(target.path);
      if (await backup.exists()) await backup.delete(recursive: true);
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest digest) => value = digest;

  @override
  void close() {}
}
