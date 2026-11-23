import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fls_for_android/services/local_install_manager.dart';
import 'package:fls_for_android/services/operation_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:fls_for_android/services/online_scripts_manager.dart';

void main() {
  test(
    'catalog validates HTTPS sources and ignores duplicate or invalid rows',
    () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'catalog.example');
        return http.Response(
          jsonEncode([
            {
              'id': 'daily_checkin',
              'name': 'Daily check-in',
              'type': 'raw',
              'link': 'https://github.com/example/checkin.py',
              'link_name': 'checkin.py',
              'doc_link': 'https://cdn.example/checkin/README.md',
              'install': 'python -m pip install requests',
            },
            {
              'id': 'daily_checkin',
              'name': 'Duplicate',
              'type': 'raw',
              'link': 'https://github.com/example/duplicate.py',
            },
            {
              'id': 'unsafe',
              'name': 'Unsafe URL',
              'type': 'raw',
              'link': 'http://example.com/script.py',
            },
            {
              'id': 'unsupported',
              'name': 'Unsupported type',
              'type': 'shell',
              'link': 'https://example.com/script.sh',
            },
          ]),
          200,
        );
      });
      final manager = OnlineScriptsManager(
        client: client,
        catalogUri: Uri.parse('https://catalog.example/index.json'),
      );
      addTearDown(manager.close);

      final catalog = await manager.fetchCatalog();

      expect(catalog, hasLength(1));
      expect(catalog.single.id, 'daily_checkin');
      expect(catalog.single.docLink?.host, 'cdn.example');
      expect(catalog.single.installCommand, 'python -m pip install requests');
    },
  );

  test('online script identifiers reject paths and whitespace', () {
    expect(
      () => OnlineScript.fromJson({
        'id': '../unsafe',
        'name': 'Unsafe',
        'type': 'raw',
        'link': 'https://example.com/script.py',
      }),
      throwsFormatException,
    );
  });

  test(
    'raw script update check compares remote and installed file content',
    () async {
      final temp = await Directory.systemTemp.createTemp('fls-script-check-');
      addTearDown(() => temp.delete(recursive: true));
      final previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPathProvider(temp.path);
      addTearDown(() => PathProviderPlatform.instance = previousPathProvider);

      final installManager = LocalInstallManager();
      final scripts = await installManager.scripts;
      await scripts.create(recursive: true);
      await File('${scripts.path}/checkin.py').writeAsString('print("same")');
      final client = MockClient((request) async {
        expect(request.url, Uri.parse('https://raw.example/checkin.py'));
        return http.Response('print("same")', 200);
      });
      final manager = OnlineScriptsManager(client: client);
      addTearDown(manager.close);

      final result = await manager.checkForUpdate(
        script: OnlineScript.fromJson({
          'id': 'daily_checkin',
          'name': 'Daily check-in',
          'type': 'raw',
          'link': 'https://raw.example/checkin.py',
          'link_name': 'checkin.py',
        }),
        installManager: installManager,
        cancellation: OperationCancellation(),
        onStatus: (_) {},
      );

      expect(result.state, OnlineScriptUpdateState.upToDate);
    },
  );

  test('raw script update check detects changed remote content', () async {
    final temp = await Directory.systemTemp.createTemp('fls-script-check-');
    addTearDown(() => temp.delete(recursive: true));
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(temp.path);
    addTearDown(() => PathProviderPlatform.instance = previousPathProvider);

    final installManager = LocalInstallManager();
    final scripts = await installManager.scripts;
    await scripts.create(recursive: true);
    await File('${scripts.path}/checkin.py').writeAsString('print("old")');
    final client = MockClient((request) async {
      expect(request.url, Uri.parse('https://raw.example/checkin.py'));
      return http.Response('print("new")', 200);
    });
    final manager = OnlineScriptsManager(client: client);
    addTearDown(manager.close);

    final result = await manager.checkForUpdate(
      script: OnlineScript.fromJson({
        'id': 'daily_checkin',
        'name': 'Daily check-in',
        'type': 'raw',
        'link': 'https://raw.example/checkin.py',
        'link_name': 'checkin.py',
      }),
      installManager: installManager,
      cancellation: OperationCancellation(),
      onStatus: (_) {},
    );

    expect(result.state, OnlineScriptUpdateState.updateAvailable);
  });

  test(
    'repository update check compares saved commit with upstream head',
    () async {
      final temp = await Directory.systemTemp.createTemp('fls-script-check-');
      addTearDown(() => temp.delete(recursive: true));
      final previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPathProvider(temp.path);
      addTearDown(() => PathProviderPlatform.instance = previousPathProvider);

      final installManager = LocalInstallManager();
      final scripts = await installManager.scripts;
      await Directory('${scripts.path}/example-repo').create(recursive: true);
      final stateDirectory = Directory(
        '${(await installManager.root).path}/script-state',
      );
      await stateDirectory.create(recursive: true);
      await File('${stateDirectory.path}/example_repo.json').writeAsString(
        jsonEncode({
          'type': 'repo',
          'link': 'https://github.com/example/repo',
          'link_name': 'example-repo',
          'revision': 'a' * 40,
        }),
      );
      const head = 'b0123456789abcdef0123456789abcdef0123456';
      final client = MockClient((request) async {
        if (request.url.path == '/repos/example/repo') {
          return http.Response(jsonEncode({'default_branch': 'main'}), 200);
        }
        if (request.url.path == '/repos/example/repo/commits/main') {
          return http.Response(jsonEncode({'sha': head}), 200);
        }
        fail('Unexpected request: ${request.url}');
      });
      final manager = OnlineScriptsManager(client: client);
      addTearDown(manager.close);

      final result = await manager.checkForUpdate(
        script: OnlineScript.fromJson({
          'id': 'example_repo',
          'name': 'Example repository',
          'type': 'repo',
          'link': 'https://github.com/example/repo',
          'link_name': 'example-repo',
        }),
        installManager: installManager,
        cancellation: OperationCancellation(),
        onStatus: (_) {},
      );

      expect(result.state, OnlineScriptUpdateState.updateAvailable);
      expect(result.remoteRevision, head);
    },
  );

  test(
    'repository update check compares legacy install with archive',
    () async {
      final temp = await Directory.systemTemp.createTemp('fls-script-check-');
      addTearDown(() => temp.delete(recursive: true));
      final previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPathProvider(temp.path);
      addTearDown(() => PathProviderPlatform.instance = previousPathProvider);

      final installManager = LocalInstallManager();
      final scripts = await installManager.scripts;
      final installed = Directory('${scripts.path}/example-repo');
      await installed.create(recursive: true);
      await File('${installed.path}/checkin.py').writeAsString('print("same")');

      const head = 'c0123456789abcdef0123456789abcdef0123456';
      final archive = Archive()
        ..addFile(
          ArchiveFile.string('repo-checkout/checkin.py', 'print("same")'),
        );
      final archiveBytes = ZipEncoder().encode(archive);
      final client = MockClient((request) async {
        if (request.url.path == '/repos/example/repo') {
          return http.Response(jsonEncode({'default_branch': 'main'}), 200);
        }
        if (request.url.path == '/repos/example/repo/commits/main') {
          return http.Response(jsonEncode({'sha': head}), 200);
        }
        if (request.url.path == '/repos/example/repo/zipball/$head') {
          return http.Response.bytes(archiveBytes, 200);
        }
        fail('Unexpected request: ${request.url}');
      });
      final manager = OnlineScriptsManager(client: client);
      addTearDown(manager.close);

      final result = await manager.checkForUpdate(
        script: OnlineScript.fromJson({
          'id': 'example_repo',
          'name': 'Example repository',
          'type': 'repo',
          'link': 'https://github.com/example/repo',
          'link_name': 'example-repo',
        }),
        installManager: installManager,
        cancellation: OperationCancellation(),
        onStatus: (_) {},
      );

      expect(result.state, OnlineScriptUpdateState.upToDate);
      final stateFile = File(
        '${(await installManager.root).path}/script-state/example_repo.json',
      );
      expect(jsonDecode(await stateFile.readAsString())['revision'], head);
    },
  );
}

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}
