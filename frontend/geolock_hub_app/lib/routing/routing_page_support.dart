import 'dart:async';
import 'package:flutter/material.dart';
import 'ngo_routing_repository.dart';

/// Discards late/account-switched reads and disables actions while backgrounded.
abstract class NgoSessionPage<T extends StatefulWidget> extends State<T>
    with WidgetsBindingObserver {
  NgoRoutingRepository? get injectedRepository;
  late final NgoRoutingRepository repository;
  StreamSubscription<void>? _auth;
  Timer? _expires;
  int _generation = 0;
  String? _owner;
  bool loading = true, busy = false, fresh = false;
  String? error;
  Future<Object?> fetch();
  void received(Object? value);
  void clearSessionData() {}

  @override
  void initState() {
    super.initState();
    repository = injectedRepository ?? NgoRoutingRepository.live();
    WidgetsBinding.instance.addObserver(this);
    _auth = repository.identityChanges.listen((_) {
      if (_owner != repository.identity) {
        clearSessionData();
      }
      invalidate();
      unawaited(reload());
    });
    unawaited(reload());
  }

  void invalidate() {
    _generation++;
    fresh = false;
    _expires?.cancel();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    invalidate();
    if (state == AppLifecycleState.resumed) unawaited(reload());
  }

  bool get actionsEnabled =>
      fresh &&
      !busy &&
      !loading &&
      _owner != null &&
      _owner == repository.identity;

  Future<void> reload() async {
    final generation = ++_generation;
    final owner = repository.identity;
    _expires?.cancel();
    setState(() {
      loading = true;
      fresh = false;
      error = null;
    });
    try {
      final value = await fetch();
      if (!mounted ||
          generation != _generation ||
          owner != repository.identity) {
        return;
      }
      setState(() {
        received(value);
        _owner = owner;
        fresh = owner != null;
      });
      _expires = Timer(const Duration(seconds: 30), invalidate);
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => error = routingError(e));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => loading = false);
    }
  }

  Future<void> perform(Future<void> Function() action) async {
    if (!actionsEnabled) return;
    final owner = repository.identity;
    _expires?.cancel();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted && owner == repository.identity) {
        setState(() => error = routingError(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (fresh && owner == repository.identity) {
          _expires = Timer(const Duration(seconds: 30), invalidate);
        }
      }
    }
  }

  List<Widget> get notices => [
    if (loading || busy) const LinearProgressIndicator(),
    if (error != null)
      Padding(
        padding: const EdgeInsets.all(12),
        child: Text(error!, key: const Key('routing-error')),
      ),
    if (!fresh && !loading)
      const ListTile(title: Text('Refresh before performing an action.')),
  ];

  @override
  void dispose() {
    _generation++;
    _expires?.cancel();
    _auth?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

Future<bool> routingConfirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    ) ??
    false;

String routeNumber(Object? value) =>
    value is num && value.isFinite ? value.toStringAsFixed(2) : '—';
