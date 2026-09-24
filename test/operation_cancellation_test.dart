import 'package:flutter_test/flutter_test.dart';
import 'package:fls_for_android/services/operation_cancellation.dart';

void main() {
  test('cancellation is observable and throws at checkpoints', () async {
    final cancellation = OperationCancellation();
    expect(cancellation.isCancelled, isFalse);

    cancellation.cancel();

    expect(cancellation.isCancelled, isTrue);
    expect(cancellation.throwIfCancelled, throwsA(isA<OperationCancelled>()));
    await expectLater(
      cancellation.delay(const Duration(seconds: 1)),
      throwsA(isA<OperationCancelled>()),
    );
  });
}
