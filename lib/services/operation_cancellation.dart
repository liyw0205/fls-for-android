import 'dart:async';

class OperationCancelled implements Exception {
  const OperationCancelled();

  @override
  String toString() => '操作已取消';
}

class OperationCancellation {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const OperationCancelled();
  }

  Future<void> delay(Duration duration) async {
    await Future.any<void>([
      Future<void>.delayed(duration),
      whenCancelled.then<void>((_) => throw const OperationCancelled()),
    ]);
  }
}
