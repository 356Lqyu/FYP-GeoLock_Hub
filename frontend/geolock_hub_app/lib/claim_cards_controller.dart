import 'dart:async';
import 'package:flutter/foundation.dart';
import 'claim_card.dart';

/// Reads only. A deadline timer invalidates actions and requests another server
/// snapshot; elapsed/device time never changes a claim's classified status.
class ClaimCardsController extends ChangeNotifier {
  ClaimCardsController({required this.load, required this.identity});
  final Future<Object?> Function() load;
  final String? Function() identity;
  List<ClaimCard> _cards = const [];
  String? _readIdentity;
  List<ClaimCard> get cards => identity() == _readIdentity ? _cards : const [];
  bool loading = false;
  bool _fresh = false;
  bool get fresh => _fresh && identity() == _readIdentity;
  Object? error;
  int _generation = 0;
  bool _disposed = false;
  Timer? _deadline;

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    final user = identity();
    final elapsed = Stopwatch()..start();
    _deadline?.cancel();
    loading = true;
    _fresh = false;
    error = null;
    // Do not retain private rows while identity or authorization is rechecked.
    _cards = const [];
    notifyListeners();
    try {
      final result = parseClaimCards(await load());
      if (_disposed || generation != _generation) return;
      if (identity() != user) {
        error = StateError('Account changed. Refresh claim history.');
        return;
      }
      _readIdentity = user;
      _cards = List.unmodifiable(result);
      _fresh = true;
      Duration? next;
      for (final card in cards.where((card) => card.isValidActive)) {
        final delay =
            card.leaseExpiresAt!.difference(card.serverNow!) - elapsed.elapsed;
        if (next == null || delay < next) next = delay;
      }
      if (next != null) {
        if (next <= Duration.zero) _fresh = false;
        _deadline = Timer(
          next > Duration.zero ? next : const Duration(seconds: 1),
          refresh,
        );
      }
    } catch (failure) {
      if (!_disposed && generation == _generation) error = failure;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void invalidate() {
    if (_disposed) return;
    ++_generation;
    _deadline?.cancel();
    _cards = const [];
    _fresh = false;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _deadline?.cancel();
    super.dispose();
  }
}
