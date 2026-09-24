import 'package:flutter_test/flutter_test.dart';
import 'package:fls_for_android/services/local_install_manager.dart';

void main() {
  const digest =
      'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final release = {
    'assets': [
      {
        'name': 'fls-proot-python-arm64.tar.gz',
        'browser_download_url':
            'https://github.com/liyw0205/fls/releases/download/proot-runtime/fls-proot-python-arm64.tar.gz',
        'digest': digest,
        'size': 65000000,
      },
      {
        'name': 'fls-proot-all-arm64.tar.gz',
        'browser_download_url':
            'https://github.com/liyw0205/fls/releases/download/proot-runtime/fls-proot-all-arm64.tar.gz',
        'digest': digest,
        'size': 125000000,
      },
    ],
  };

  test('selects a supported ABI and checks release metadata', () {
    final asset = selectPythonRuntimeAsset(release, [
      'arm64-v8a',
      'armeabi-v7a',
    ]);
    expect(asset?.name, 'fls-proot-python-arm64.tar.gz');
    expect(asset?.sha256, 'a' * 64);
    expect(asset?.size, 65000000);
  });

  test('rejects unsupported ABI and incomplete digest metadata', () {
    expect(selectPythonRuntimeAsset(release, ['x86_64']), isNull);
    expect(
      selectPythonRuntimeAsset(
        {
          'assets': [
            {
              'name': 'fls-proot-python-arm64.tar.gz',
              'browser_download_url': 'https://example.com/runtime.tar.gz',
              'digest': 'sha256:invalid',
              'size': 100,
            },
          ],
        },
        ['arm64-v8a'],
      ),
      isNull,
    );
  });

  test('selects the full runtime profile', () {
    final asset = selectRuntimeAsset(release, [
      'arm64-v8a',
    ], RuntimeProfile.all);
    expect(asset?.name, 'fls-proot-all-arm64.tar.gz');
    expect(asset?.size, 125000000);
  });

  test('applies an optional GitHub mirror prefix or template', () {
    final original = Uri.parse('https://api.github.com/repos/liyw0205/fls');
    expect(
      applyGithubMirror(original, 'https://mirror.example/').toString(),
      'https://mirror.example/https://api.github.com/repos/liyw0205/fls',
    );
    expect(
      applyGithubMirror(original, 'https://mirror.example/?url=%s').toString(),
      'https://mirror.example/?url=https://api.github.com/repos/liyw0205/fls',
    );
    expect(
      () => applyGithubMirror(original, 'ftp://mirror.example'),
      throwsFormatException,
    );
  });
}
