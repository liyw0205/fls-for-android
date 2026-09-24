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
}
