import 'dart:async';
import 'package:flutter/material.dart';
import '../hub_admin/hub_widgets.dart' show HubColors;
import '../ui/geolock_role_style.dart';
import 'ngo_routing_repository.dart';
import 'proposed_route_view.dart';
import 'routing_feedback.dart';
import 'routing_worker_client.dart' show RoutingRequestFailure;

String routingOperationMessage(Map<String, dynamic> operation) {
  if (operation['kind'] == 'DATABASE_AUTHORIZATION_RECEIPT' ||
      operation['status'] == 'authorized') {
    return 'Route authorization confirmed.';
  }
  if (operation['operation_terminal'] == 'INFEASIBLE' ||
      operation['status'] == 'infeasible' ||
      (operation['kind'] == 'ADVISORY_CANDIDATE' &&
          operation['outcome'] == 'INFEASIBLE')) {
    return 'No feasible route was found. No route was authorized.';
  }
  if (operation['operation_terminal'] == 'REJECTED' ||
      operation['status'] == 'rejected' ||
      operation['status'] == 'blocked') {
    return routingFailureMessage(operation['failure_code']?.toString()) ??
        'The saved routing request was rejected.';
  }
  return 'Authorization is unconfirmed. No committed receipt is visible from '
      'this check. Keep the original request.';
}

String savedRoutingOperationMessage(Map<String, dynamic> operation) {
  if (NgoRoutingRepository.isFinishedPreflight(operation)) {
    final reason = routingFailureMessage(operation['failure_code']?.toString());
    return 'Route setup stopped before generation.${reason == null ? '' : ' $reason'}';
  }
  if (operation['status'] == 'authorization_unknown') {
    return 'Authorization is unconfirmed. Check the outcome of your saved request before starting another.';
  }
  if (const {
    'authorized',
    'infeasible',
    'blocked',
    'rejected',
  }.contains(operation['status'])) {
    return routingOperationMessage(operation);
  }
  return 'A routing request is already saved. Check its outcome in Route Support before starting another.';
}

/// Support reads and guarded local archival only; no planning or dispatch writes.
class RoutingDiagnosticsPage extends StatefulWidget {
  const RoutingDiagnosticsPage({
    super.key,
    required this.repository,
    required this.operation,
    required this.planning,
    this.initialHealth,
    this.initialHealthFailed = false,
  });
  final NgoRoutingRepository repository;
  final Map<String, dynamic> operation, planning;
  final String? initialHealth;
  final bool initialHealthFailed;
  @override
  State<RoutingDiagnosticsPage> createState() => _RoutingDiagnosticsPageState();
}

class _RoutingDiagnosticsPageState extends State<RoutingDiagnosticsPage> {
  late final String? _owner = widget.repository.identity;
  String? _message;
  bool _messageFailed = false;
  late String? _connectionResult = widget.initialHealth;
  late bool _connectionFailed = widget.initialHealthFailed;
  String? _connectionDetails;
  Map<String, dynamic>? _saved;
  String? _outcomeMessage;
  Map<String, dynamic>? _terminalOutcome;
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
          _connectionResult = null;
          _connectionDetails = null;
          _outcomeMessage = null;
          _terminalOutcome = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  Future<void> _read(
    Future<void> Function() action, {
    String failureMessage =
        'Read-only check failed. Existing request retained.',
  }) async {
    if (_busy || widget.repository.identity != _owner) return;
    setState(() {
      _busy = true;
      _message = null;
      _messageFailed = false;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = failureMessage;
          _messageFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => GeoRoleTheme(child: _buildPage());

  Future<void> _checkConnection() => _read(() async {
    setState(() {
      _connectionResult = null;
      _connectionDetails = null;
    });
    String result;
    String? details;
    var failed = false;
    try {
      await widget.repository.checkPlannerConnection();
      result =
          'Planner connection confirmed. No snapshot or route was created.';
    } catch (error) {
      failed = true;
      result = routingError(error);
      if (error is RoutingRequestFailure) {
        details = [
          'Code: ${error.code}',
          if (error.httpStatus != null) 'HTTP: ${error.httpStatus}',
          if (error.transportReason != null)
            'Transport: ${error.transportReason}',
        ].join('\n');
      }
    }
    if (mounted && widget.repository.identity == _owner) {
      setState(() {
        _connectionResult = result;
        _connectionFailed = failed;
        _connectionDetails = details;
      });
    }
  });

  Widget _buildPage() {
    final sameOwner = widget.repository.identity == _owner;
    final hasSavedRequests =
        widget.operation.isNotEmpty || widget.planning.isNotEmpty;
    return Scaffold(
      backgroundColor: HubColors.mint,
      appBar: AppBar(
        title: const Text('Route support'),
        backgroundColor: HubColors.mint,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const GeoNoticeCard(
            tone: GeoTone.success,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.help_outline, color: GeoTone.success),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Check the planner connection or review a saved routing request.',
                  ),
                ),
              ],
            ),
          ),
          if (!sameOwner) const Text('Account changed. Close this screen.'),
          if (_busy) const LinearProgressIndicator(),
          if (sameOwner) ...[
            const GeoSectionTitle('Planner connection'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.repository.canCheckPlanner) ...[
                      const Text(
                        'Read-only check. It does not generate, start or resume a route.',
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _checkConnection,
                        icon: const Icon(Icons.network_check),
                        label: const Text('Check connection'),
                      ),
                    ] else
                      Text(widget.repository.plannerConfigurationMessage),
                  ],
                ),
              ),
            ),
            if (_connectionResult != null)
              GeoNoticeCard(
                key: const Key('planner-connection-result'),
                tone: _connectionFailed ? GeoTone.warning : GeoTone.success,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_connectionFailed)
                      Text(
                        widget.operation.isNotEmpty ||
                                widget.planning.isNotEmpty
                            ? 'Connection check failed. Your saved request is retained.'
                            : 'Connection check failed.',
                      ),
                    Text(_connectionResult!),
                    if (_connectionDetails != null)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Connection diagnostics'),
                        children: [SelectableText(_connectionDetails!)],
                      ),
                  ],
                ),
              ),
            if (hasSavedRequests) ...[
              const GeoSectionTitle('Saved requests'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.operation.isNotEmpty) ...[
                        Text(
                          _outcomeMessage ??
                              savedRoutingOperationMessage(widget.operation),
                        ),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('Technical details'),
                          children: [
                            SelectableText(
                              'Request: ${widget.operation['request_id']}\nSnapshot: ${widget.operation['snapshot_id'] ?? 'not confirmed'}\nPhase: ${widget.operation['phase']}\nFailure: ${widget.operation['failure_code'] ?? 'not recorded'}\nHTTP: ${widget.operation['failure_http_status'] ?? 'not recorded'}',
                            ),
                          ],
                        ),
                      ],
                      if (widget.planning.isNotEmpty)
                        SelectableText(
                          'Historical planning request: ${widget.planning['request_id']}\nSnapshot: ${widget.planning['snapshot_id']}',
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (_message != null)
              GeoNoticeCard(
                tone: _messageFailed ? GeoTone.warning : GeoTone.info,
                child: Text(_message!),
              ),
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
                        setState(() {
                          _terminalOutcome = null;
                          _outcomeMessage = null;
                          _message = null;
                        });
                        final outcome = await widget.repository
                            .reconcileRouteOperation();
                        if (mounted && widget.repository.identity == _owner) {
                          setState(() {
                            _outcomeMessage = routingOperationMessage(outcome);
                            if (NgoRoutingRepository.hasTerminalRouteEvidence(
                              widget.operation,
                              outcome,
                            )) {
                              _terminalOutcome = outcome;
                            }
                          });
                        }
                      }),
                child: const Text('Check authorization outcome (read only)'),
              ),
            if (_terminalOutcome case final outcome?) ...[
              const Text(
                'Finishing keeps this attempt in history. It does not generate, authorize or cancel a route.',
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _read(
                        () async {
                          setState(() {
                            _terminalOutcome = null;
                            _outcomeMessage = null;
                            _message = null;
                          });
                          await widget.repository.finishTerminalRouteOperation(
                            owner: _owner!,
                            requestId: outcome['request_id'] as String,
                            snapshotId: outcome['snapshot_id'] as String,
                            terminal: outcome['operation_terminal'] as String,
                          );
                          if (mounted && widget.repository.identity == _owner) {
                            Navigator.of(context).pop();
                          }
                        },
                        failureMessage:
                            'Could not finish this attempt. The outcome or saved request may have changed. Check the outcome again.',
                      ),
                child: const Text('Finish previous attempt'),
              ),
            ],
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
