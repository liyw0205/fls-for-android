import 'package:flutter_test/flutter_test.dart';
import 'package:fls_for_android/models/panel_server.dart';

void main() {
  test('normalizes a host and removes the final slash', () {
    expect(
      normalizePanelUrl('  fls.example.com:5700/  '),
      'https://fls.example.com:5700',
    );
    expect(normalizePanelUrl('192.168.1.2:5700'), 'http://192.168.1.2:5700');
  });

  test('keeps secure scheme and a non-root path', () {
    expect(
      normalizePanelUrl('https://fls.example.com/panel/'),
      'https://fls.example.com/panel',
    );
  });

  test('rejects credentials, query strings, and unsupported schemes', () {
    expect(normalizePanelUrl('https://user:pass@example.com'), isNull);
    expect(normalizePanelUrl('https://example.com/?token=secret'), isNull);
    expect(normalizePanelUrl('ftp://example.com'), isNull);
  });
}
