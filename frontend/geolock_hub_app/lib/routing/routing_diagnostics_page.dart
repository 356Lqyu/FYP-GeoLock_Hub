import 'dart:async';
import 'package:flutter/material.dart';
import 'ngo_routing_repository.dart';
import 'proposed_route_view.dart';

/// Support reads and guarded local archival only; no planning or dispatch writes.
class RoutingDiagnosticsPage extends StatefulWidget {
  const RoutingDiagnosticsPage({
    super.key,
    required this.repository,
    required this.operation,
    required this.planning,
    this.initialHealth,
  });
  final NgoRoutingRepository repository;
  final Map<String, dynamic> operation, planning;
  final String? initialHealth;
  @override
  State<RoutingDiagnosticsPage> createState() => _RoutingDiagnosticsPageState();
}

class _RoutingDiagnosticsPageState extends State<RoutingDiagnosticsPage> {
  late final String? _owner = widget.repository.identity;
  late String? _message = widget.initialHealth;
  Map<String, dynamic>? _saved;
  bool _busy = false;
  StreamSubscription<void>? _auth;
  @override
  void initState() {
    super.initState();
    _auth = widget.repository.identityChanges.listen((_) {
      if (mounted) {
        setState(() {
          _saved = null;
          _message = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  Future<void> _read(Future<void> Function() action) async {
    if (_busy || widget.repository.identity != _owner) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Read-only check failed. Existing request retained.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sameOwner = widget.repository.identity == _owner;
    return Scaffold(
      appBar: AppBar(title: const Text('Route support')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Technical diagnostics. These actions never generate, authorize or resume a route. Local archival preserves history.',
          ),
          if (!sameOwner) const Text('Account changed. Close this screen.'),
          if (_busy) const LinearProgressIndicator(),
          if (sameOwner) ...[
            if (!widget.repository.canCheckPlanner)
              Text(widget.repository.plannerConfigurationMessage),
            if (widget.operation.isNotEmpty)
              SelectableText(
                'Request: ${widget.operation['request_id']}\nSnapshot: ${widget.operation['snapshot_id'] ?? 'not confirmed'}\nPhase: ${widget.operation['phase']}\nFailure: ${widget.operation['failure_code'] ?? 'not recorded'}\nHTTP: ${widget.operation['failure_http_status'] ?? 'not recorded'}',
              ),
            if (widget.planning.isNotEmpty)
              SelectableText(
                'Historical planning request: ${widget.planning['request_id']}\nSnapshot: ${widget.planning['snapshot_id']}',
              ),
            if (widget.repository.canCheckPlanner)
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _read(() async {
                        await widget.repository.checkPlannerConnection();
                        if (mounted && widget.repository.identity == _owner) {
                          setState(
                            () => _message =
                                'Planner ACTIVE for DEV. Read-only check; no snapshot or route created.',
                          );
                        }
                      }),
                child: const Text('Check planner connection (read only)'),
              ),
            if (_message != null) Text(_message!),
            if (widget.operation['status'] == 'authorized')
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _read(() async {
                        await widget.repository.finishRouteOperation();
                        if (mounted && widget.repository.identity == _owner) {
                          setState(
                            () => _message =
                                'Authorization history saved locally. Existing routes and reservations are unchanged. Return to routes to refresh.',
                          );
                        }
                      }),
                child: const Text(
                  'Archive verified authorization (history kept)',
                ),
              ),
            if (widget.operation['snapshot_id'] is String)
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _read(() async {
                        await widget.repository.reconcileRouteOperation();
                        if (mounted && widget.repository.identity == _owner) {
                          setState(
                            () => _message =
                                'Outcome checked. Return to routes to refresh. Missing receipt does not prove rollback.',
                          );
                        }
                      }),
                child: const Text('Check authorization outcome (read only)'),
              ),
            if (widget.repository.canReadSavedPlanning &&
                widget.planning['snapshot_id'] is String)
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _read(() async {
                        final result = await widget.repository
                            .readSavedPlanning();
                        if (mounted && widget.repository.identity == _owner) {
                          setState(() => _saved = result);
                        }
                      }),
                child: const Text('View saved Proposed result (read only)'),
              ),
            if (_saved != null) ...[
              const Text(
                'Historical advisory result. This is not an authorized route.',
              ),
              ProposedRouteView(
                candidate: _saved!,
                fleet: const [],
                tasks: const [],
              ),
            ],
          ],
        ],
      ),
    );
  }
}
