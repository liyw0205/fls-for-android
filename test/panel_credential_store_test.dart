import 'package:fls_for_android/services/panel_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'serializes an opaque cookie and CSRF token without debug disclosure',
    () {
      const credentials = PanelSessionCredentials(
        cookie: 'session=signed-cookie.value',
        csrfToken: 'csrf_token-123',
      );

      final decoded = PanelSessionCredentials.fromJson(credentials.toJson());

      expect(decoded.cookie, credentials.cookie);
      expect(decoded.csrfToken, credentials.csrfToken);
      expect(credentials.toString(), isNot(contains('signed-cookie')));
    },
  );

  test('rejects cookie or CSRF values that cannot be sent as safe headers', () {
    expect(
      () => PanelSessionCredentials.fromJson({
        'cookie': 'session=value\r\nX-Token: leaked',
        'csrf_token': 'csrf-token',
      }),
      throwsFormatException,
    );
    expect(
      () => PanelSessionCredentials.fromJson({
        'cookie': 'session=value',
        'csrf_token': 'csrf token',
      }),
      throwsFormatException,
    );
  });
}
