import 'package:flutter_test/flutter_test.dart';

import 'package:fls_for_android/services/local_panel_host.dart';

void main() {
  test('parses persisted local service status', () {
    final status = LocalPanelStatus.fromMap({
      'state': 'retrying',
      'startedAtMs': 1_700_000_000_000,
      'exitCode': 23,
      'restartAttempts': 2,
      'autoRestart': true,
    });

    expect(status.state, LocalPanelState.retrying);
    expect(status.startedAt, isNotNull);
    expect(status.exitCode, 23);
    expect(status.restartAttempts, 2);
    expect(status.autoRestart, isTrue);
  });

  test('unknown or missing service status is safe', () {
    final status = LocalPanelStatus.fromMap(null);

    expect(status.state, LocalPanelState.unknown);
    expect(status.startedAt, isNull);
    expect(status.exitCode, isNull);
    expect(status.restartAttempts, 0);
    expect(status.autoRestart, isFalse);
  });
}
