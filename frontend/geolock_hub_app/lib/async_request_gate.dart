import 'dart:async';

/// Serializes refresh requests so rapid tab changes never overlap reads for a
/// single tab. Each caller still receives the result or error of its request.
class AsyncRequestGate {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() request) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await request());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}
