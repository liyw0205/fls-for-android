import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fls_for_android/services/local_install_manager.dart';
import 'package:fls_for_android/services/operation_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fls_for_android/services/online_scripts_manager.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final oversizedArchive = Archive();
  for (var index = 0; index <= 20000; index++) {
    oversizedArchive.addFile(ArchiveFile.noData('repo-checkout/file-$index'));
  }

  final unsafeArchives = <(String, Archive, String)>[
    (
      'absolute paths',
      Archive()..addFile(ArchiveFile.string('/outside.py', 'unsafe')),
      '绝对路径',
    ),
    (
      'traversal paths',
      Archive()..addFile(
        ArchiveFile.string('repo-checkout/../../outside.py', 'unsafe'),
      ),
      '越界路径',
    ),
    (
      'symbolic links',
      Archive()..addFile(
        ArchiveFile.symlink('repo-checkout/link.py', '../../outside.py'),
      ),
      '符号链接',
    ),
    ('too many entries', oversizedArchive, '文件数量超过限制'),
  ];

  for (final (description, archive, expectedError) in unsafeArchives) {
    test('repository install rejects archive $description', () async {
      await _expectRepositoryArchiveRejected(archive, expectedError);
    });
  }

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

  test('catalog revalidates cache with ETag and Last-Modified', () async {
    const modifiedAt = 'Wed, 21 Oct 2015 07:28:00 GMT';
    final body = jsonEncode([
      {
        'id': 'daily_checkin',
        'name': 'Daily check-in',
        'type': 'raw',
        'link': 'https://example.com/checkin.py',
      },
    ]);
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      if (requestCount == 1) {
        return http.Response(
          body,
          200,
          headers: {'etag': '"catalog-v1"', 'last-modified': modifiedAt},
        );
      }
      expect(request.headers['If-None-Match'], '"catalog-v1"');
      expect(request.headers['If-Modified-Since'], modifiedAt);
      return http.Response('', 304);
    });
    final manager = OnlineScriptsManager(
      client: client,
      catalogUri: Uri.parse('https://catalog.example/index.json'),
    );
    addTearDown(manager.close);

    final initial = await manager.fetchCatalogSnapshot();
    final revalidated = await manager.fetchCatalogSnapshot();

    expect(initial.scripts, hasLength(1));
    expect(initial.fromCache, isFalse);
    expect(revalidated.scripts, hasLength(1));
    expect(revalidated.fromCache, isTrue);
    expect(revalidated.refreshError, isNull);
    expect(revalidated.changes, isNull);
    expect(revalidated.lastSyncedAt, initial.lastSyncedAt);
    expect(requestCount, 2);
  });

  test('catalog falls back to cached rows when refresh is offline', () async {
    final body = jsonEncode([
      {
        'id': 'daily_checkin',
        'name': 'Daily check-in',
        'type': 'raw',
        'link': 'https://example.com/checkin.py',
      },
    ]);
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      if (requestCount == 1) return http.Response(body, 200);
      throw const SocketException('offline');
    });
    final manager = OnlineScriptsManager(
      client: client,
      catalogUri: Uri.parse('https://catalog.example/index.json'),
    );
    addTearDown(manager.close);

    await manager.fetchCatalogSnapshot();
    final immediateCache = await manager.readCachedCatalog();
    final fallback = await manager.fetchCatalogSnapshot();

    expect(immediateCache?.scripts.single.id, 'daily_checkin');
    expect(immediateCache?.fromCache, isTrue);
    expect(fallback.scripts.single.id, 'daily_checkin');
    expect(fallback.fromCache, isTrue);
    expect(fallback.refreshError, contains('offline'));
    expect(fallback.lastSyncedAt, immediateCache?.lastSyncedAt);
  });

  test('catalog reports added, removed, and changed scripts', () async {
    final previous = jsonEncode([
      {
        'id': 'kept',
        'name': 'Old name',
        'type': 'raw',
        'link': 'https://example.com/old.py',
      },
      {
        'id': 'removed',
        'name': 'Removed',
        'type': 'raw',
        'link': 'https://example.com/removed.py',
      },
    ]);
    final current = jsonEncode([
      {
        'id': 'kept',
        'name': 'New name',
        'type': 'raw',
        'link': 'https://example.com/old.py',
      },
      {
        'id': 'added',
        'name': 'Added',
        'type': 'raw',
        'link': 'https://example.com/added.py',
      },
    ]);
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return http.Response(requestCount == 1 ? previous : current, 200);
    });
    final manager = OnlineScriptsManager(
      client: client,
      catalogUri: Uri.parse('https://catalog.example/index.json'),
    );
    addTearDown(manager.close);

    await manager.fetchCatalogSnapshot();
    final refreshed = await manager.fetchCatalogSnapshot();

    expect(refreshed.changes?.added, 1);
    expect(refreshed.changes?.removed, 1);
    expect(refreshed.changes?.updated, 1);
  });

  test(
    'raw installation reports byte progress for streamed downloads',
    () async {
      final temp = await Directory.systemTemp.createTemp('fls-script-install-');
      addTearDown(() => temp.delete(recursive: true));
      final previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPathProvider(temp.path);
      addTearDown(() => PathProviderPlatform.instance = previousPathProvider);

      final client = MockClient.streaming((request, _) async {
        expect(request.url, Uri.parse('https://raw.example/checkin.py'));
        final chunks = [
          Future<List<int>>.delayed(
            const Duration(milliseconds: 10),
            () => [1],
          ),
          Future<List<int>>.delayed(
            const Duration(milliseconds: 10),
            () => [2, 3],
          ),
          Future<List<int>>.delayed(
            const Duration(milliseconds: 10),
            () => [4],
          ),
        ];
        return http.StreamedResponse(
          Stream.fromFutures(chunks),
          200,
          contentLength: 4,
        );
      });
      final manager = OnlineScriptsManager(client: client);
      addTearDown(manager.close);
      final installManager = _RuntimeReadyInstallManager();
      final progress = <(int, int?)>[];

      await manager.installOrUpdateNative(
        script: _rawScript(),
        installManager: installManager,
        overwriteExisting: false,
        cancellation: OperationCancellation(),
        onStatus: (_) {},
        onProgress: (received, total) => progress.add((received, total)),
      );

      final installed = File(
        '${(await installManager.scripts).path}/checkin.py',
      );
      expect(await installed.readAsBytes(), [1, 2, 3, 4]);
      expect(progress, [(1, 4), (3, 4), (4, 4)]);
    },
  );

  test('cancelling an aborted download preserves the installed file', () async {
    final temp = await Directory.systemTemp.createTemp('fls-script-cancel-');
    addTearDown(() => temp.delete(recursive: true));
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(temp.path);
    addTearDown(() => PathProviderPlatform.instance = previousPathProvider);

    final installManager = _RuntimeReadyInstallManager();
    final scripts = await installManager.scripts;
    await scripts.create(recursive: true);
    final installed = File('${scripts.path}/checkin.py');
    await installed.writeAsString('existing version');
    final client = _AbortableBodyClient();
    final manager = OnlineScriptsManager(client: client);
    addTearDown(manager.close);
    final cancellation = OperationCancellation();

    await expectLater(
      manager.installOrUpdateNative(
        script: _rawScript(),
        installManager: installManager,
        overwriteExisting: true,
        cancellation: cancellation,
        onStatus: (_) {},
        onProgress: (_, _) => cancellation.cancel(),
      ),
      throwsA(isA<OperationCancelled>()),
    );

    expect(client.requestAborted, isTrue);
    expect(await installed.readAsString(), 'existing version');
    expect(
      await scripts
          .list()
          .where((entity) => p.basename(entity.path).startsWith('.fls-script-'))
          .isEmpty,
      isTrue,
    );
  });

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

OnlineScript _rawScript() => OnlineScript.fromJson({
  'id': 'daily_checkin',
  'name': 'Daily check-in',
  'type': 'raw',
  'link': 'https://raw.example/checkin.py',
  'link_name': 'checkin.py',
});

Future<void> _expectRepositoryArchiveRejected(
  Archive archive,
  String expectedError,
) async {
  final temp = await Directory.systemTemp.createTemp('fls-script-archive-');
  addTearDown(() => temp.delete(recursive: true));
  final previousPathProvider = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _TestPathProvider(temp.path);
  addTearDown(() => PathProviderPlatform.instance = previousPathProvider);

  const head = 'd0123456789abcdef0123456789abcdef0123456';
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
  final installManager = _RuntimeReadyInstallManager();

  await expectLater(
    manager.installOrUpdateNative(
      script: OnlineScript.fromJson({
        'id': 'example_repo',
        'name': 'Example repository',
        'type': 'repo',
        'link': 'https://github.com/example/repo',
        'link_name': 'example-repo',
      }),
      installManager: installManager,
      overwriteExisting: false,
      cancellation: OperationCancellation(),
      onStatus: (_) {},
    ),
    throwsA(
      isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains(expectedError),
      ),
    ),
  );

  final scripts = await installManager.scripts;
  expect(
    await Directory(p.join(scripts.path, 'example-repo')).exists(),
    isFalse,
  );
  expect(
    await scripts
        .list()
        .where((entity) => p.basename(entity.path).startsWith('.fls-script-'))
        .isEmpty,
    isTrue,
  );
}

class _RuntimeReadyInstallManager extends LocalInstallManager {
  @override
  Future<bool> hasRuntime({RuntimeProfile? profile}) async => true;
}

class _AbortableBodyClient extends http.BaseClient {
  final _body = StreamController<List<int>>();
  bool requestAborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abortable = request as http.AbortableRequest;
    final abortTrigger = abortable.abortTrigger;
    if (abortTrigger != null) {
      abortTrigger.then((_) {
        requestAborted = true;
        if (_body.isClosed) return;
        _body.addError(http.RequestAbortedException(request.url));
        unawaited(_body.close());
      });
    }
    _body.add([1, 2]);
    return http.StreamedResponse(
      _body.stream,
      200,
      contentLength: 8,
      request: request,
    );
  }

  @override
  void close() {
    if (!_body.isClosed) unawaited(_body.close());
  }
}

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}
