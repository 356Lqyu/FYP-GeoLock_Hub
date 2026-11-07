import 'claim_coordination.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../claim_card.dart';
import 'ngo_fleet_page.dart';
import 'ngo_routing_repository.dart';
import 'routing_page_support.dart';
import 'proposed_route_view.dart';
import 'routing_feedback.dart';
import 'routing_diagnostics_page.dart';
import 'route_display_formatters.dart';
import 'route_card_view.dart';
import 'route_execution_controller.dart';
import 'routing_policy_display.dart';

class NgoRoutesPage extends StatefulWidget {
  const NgoRoutesPage({
    super.key,
    this.repository,
    this.refreshSignal = 0,
    this.mapBuilder,
  });
  final NgoRoutingRepository? repository;
  final int refreshSignal;
  final RoutingMapBuilder? mapBuilder;
  @override
  State<NgoRoutesPage> createState() => _NgoRoutesPageState();
}

class _NgoRoutesPageState extends NgoSessionPage<NgoRoutesPage> {
  @override
  NgoRoutingRepository? get injectedRepository => widget.repository;
  Map<String, dynamic>? _overview, _fleet;
  Map<String, Map<String, dynamic>> _routeDetails = {};
  Map<String, dynamic> _pendingPlanning = {};
  List<Map<String, dynamic>> _claims = [];
  bool _claimsVerified = false;
  String? _backendError;
  String? _plannerConnection;
  bool _checkingPlanner = false;
  bool _generating = false;
  bool _initialHealthChecked = false;

  Future<void> _showSupport() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RoutingDiagnosticsPage(
          repository: repository,
          operation: _routeOperation,
          planning: _pendingPlanning,
          initialHealth: _plannerConnection,
        ),
      ),
    );
    if (mounted) await reload();
  }

  Future<void> _openRoute(String routeId) async {
    final owner = repository.identity;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => NgoRouteDetailPage(
          routeId: routeId,
          repository: repository,
          mapBuilder: widget.mapBuilder,
        ),
      ),
    );
    // Detail actions can change route status and release a vehicle. Re-read the
    // protected list instead of retaining the pre-navigation status/hold.
    if (mounted && owner == repository.identity) await reload();
  }

  Future<void> _dismissFinishedSetup() async {
    if (!NgoRoutingRepository.isFinishedPreflight(_routeOperation)) return;
    if (!await routingConfirm(
      context,
      'Dismiss interrupted setup?',
      'This setup stopped before a snapshot request. Its original record will be kept in local history. No route will be generated.',
    )) {
      return;
    }
    if (!mounted) return;
    await perform(repository.finishRouteOperation);
    if (mounted && error == null) await reload();
  }

  Future<void> _archiveAuthorization() async {
    if (!actionsEnabled || _routeOperation['status'] != 'authorized') return;
    if (!await routingConfirm(
      context,
      'Keep route history and allow new planning?',
      'The app will verify the committed authorization and save its history locally. '
          'The existing route, pickup records and vehicle reservation remain unchanged. '
          'No new route will be generated.',
    )) {
      return;
    }
    if (!mounted) return;
    await perform(repository.finishRouteOperation);
    if (mounted && error == null) await reload();
  }

  bool _vehicleAllowed(Map<String, dynamic> vehicle) =>
      vehicle['eligible_for_planning'] == true &&
      vehicleHorizonWarning(vehicle, _overview?['policy_id']) == null;

  Future<void> _checkPlannerConnection() async {
    if (_checkingPlanner) return;
    setState(() => _checkingPlanner = true);
    try {
      await repository.checkPlannerConnection();
      if (mounted) {
        setState(
          () => _plannerConnection =
              'Planner ACTIVE for DEV. Read-only check; no snapshot or route created.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _plannerConnection = routingError(e));
    } finally {
      if (mounted) setState(() => _checkingPlanner = false);
    }
  }

  final Set<String> _selected = {};
  String _planRequest = const Uuid().v4();
  Map<String, dynamic> _routeOperation = {};
  @override
  void clearSessionData() {
    _overview = null;
    _routeDetails = {};
    _fleet = null;
    _claims = [];
    _claimsVerified = false;
    _pendingPlanning = {};
    _routeOperation = {};
    _plannerConnection = null;

    _selected.clear();
  }

  @override
  void didUpdateWidget(covariant NgoRoutesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) reload();
  }

  @override
  Future<Object?> fetch() async {
    if (!_initialHealthChecked && repository.canCheckPlanner) {
      _initialHealthChecked = true;
      // Auth-free GET only. Opening this page never starts planning.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkPlannerConnection();
      });
    }
    Map<String, dynamic>? fleet, overview;
    List<Map<String, dynamic>> claims = [];
    String? backendError, fleetError;
    bool claimsVerified = false;
    await Future.wait([
      () async {
        try {
          fleet = await repository.fleet();
        } catch (e) {
          fleetError = routingError(e);
        }
      }(),
      () async {
        try {
          overview = await repository.overview();
        } catch (e) {
          backendError = routingError(e);
        }
      }(),
      () async {
        try {
          // Always show owned lease evidence, including claims excluded from planning.
          claims = await repository.claimedPickups();
          claimsVerified = true;
        } catch (_) {
          // Missing display evidence must never become permission to plan.
        }
      }(),
    ]);
    return {
      'route_details': await loadRouteCardDetails(
        routingRows(overview?['routes'] ?? []),
        repository.detail,
      ),
      'fleet': fleet,
      'overview': overview,
      'claims': claims,
      'claims_verified': claimsVerified,
      'error': [?backendError, ?fleetError].join('\n'),
      'pending': await repository.pendingPlanning(),
      'operation': await repository.restoreRouteOperation(),
    };
  }

  @override
  void received(Object? value) {
    final data = routingObject(value);
    _fleet = data['fleet'] as Map<String, dynamic>?;
    _overview = data['overview'] as Map<String, dynamic>?;
    _routeDetails = data['route_details'] as Map<String, Map<String, dynamic>>;
    _claims = routingRows(data['claims']);
    _claimsVerified = data['claims_verified'] == true;
    _pendingPlanning = routingObject(data['pending'] ?? {});
    _routeOperation = routingObject(data['operation'] ?? {});
    _backendError = data['error'] as String?;
    if (_backendError?.isEmpty == true) {
      _backendError = null;
    }
    final ids = routingRows(
      _fleet?['vehicles'] ?? [],
    ).where(_vehicleAllowed).map((v) => v['vehicle_id']);
    _selected.removeWhere((id) => !ids.contains(id));
    if (_pendingPlanning['vehicle_ids'] is List) {
      _selected.addAll(
        (_pendingPlanning['vehicle_ids'] as List).whereType<String>().where(
          ids.contains,
        ),
      );
    }
    // A refresh or auth change invalidates candidates and their request context.

    _planRequest = const Uuid().v4();
  }

  Future<void> _showOperationResult(Map<String, dynamic> result) async {
    if (!mounted) return;
    if (result['kind'] == 'DATABASE_AUTHORIZATION_RECEIPT') {
      final routes = routingRows(result['routes']);
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => NgoRouteDetailPage(
            routeId: routes.first['route_id'] as String,
            repository: repository,
            mapBuilder: widget.mapBuilder,
          ),
        ),
      );
      if (mounted) await reload();
    } else if (result['kind'] == 'ADVISORY_CANDIDATE') {
      setState(
        () => error =
            'No route was authorized. Review the unserved pickups in Route support.',
      );
    } else {
      setState(
        () => error =
            'No committed authorization receipt visible. Keep this operation; no new request was sent.',
      );
    }
  }

  Future<void> _runOperation(
    Future<Map<String, dynamic>> Function() action,
  ) async {
    final owner = repository.identity;
    await perform(() async {
      final result = await action();
      if (owner == repository.identity) await _showOperationResult(result);
    });
    final saved = await repository.routeOperation();
    if (mounted) setState(() => _routeOperation = saved);
  }

  Future<void> _generate() async {
    if (_generating || !actionsEnabled) return;
    setState(() => _generating = true);
    try {
      await _runOperation(
        () => repository.generateAndAuthorize(
          _selected.toList()..sort(),
          _planRequest,
          _overview!['policy_id'] as String,
        ),
      );
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Pickup routes'),
      actions: [
        IconButton(
          tooltip: 'Route support',
          onPressed: busy ? null : _showSupport,
          icon: const Icon(Icons.help_outline),
        ),
        IconButton(
          tooltip: 'NGO vehicles',
          onPressed: () async {
            await Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => NgoFleetPage(repository: repository),
              ),
            );
            if (mounted) await reload();
          },
          icon: const Icon(Icons.directions_car_outlined),
        ),
        IconButton(
          tooltip: 'Refresh routes',
          onPressed: busy ? null : reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if ((loading || busy) && !_generating)
            const LinearProgressIndicator(),
          if (error != null)
            Text(
              'Route setup needs attention. No new request will be sent automatically.',
              key: const Key('routing-error'),
            ),
          if (!fresh && !loading)
            const Text('Refresh before performing an action.'),
          if (_backendError != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_backendError!),
              ),
            ),
          const SizedBox(height: 12),
          Text('Vehicles', style: Theme.of(context).textTheme.titleLarge),
          if (_fleet?['fleet_outcome'] == 'NO_FEASIBLE_PLAN')
            Text(
              routingRows(_fleet?['vehicles'] ?? []).isEmpty
                  ? 'No registered vehicles. Register a vehicle with a verified depot.'
                  : 'No vehicle is eligible for new planning. Check existing routes, availability and depot verification.',
            ),
          for (final v in routingRows(_fleet?['vehicles'] ?? []))
            CheckboxListTile(
              title: Text(
                '${v['vehicle_label']} · ${v['payload_capacity_kg']} kg',
              ),
              subtitle: Text(
                vehicleHorizonWarning(v, _overview?['policy_id']) ??
                    (v['eligible_for_planning'] == true
                        ? 'Eligible for planning'
                        : _vehicleAvailability(v)),
              ),
              value: _selected.contains(v['vehicle_id']),
              onChanged: actionsEnabled && _vehicleAllowed(v)
                  ? (selected) => setState(() {
                      if (selected == true) {
                        _selected.add(v['vehicle_id'] as String);
                      } else {
                        _selected.remove(v['vehicle_id']);
                      }

                      _planRequest = const Uuid().v4();
                    })
                  : null,
            ),
          Text(
            _overview == null
                ? 'Routing eligibility could not be confirmed'
                : 'Eligible claimed pickup tasks',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (_displayClaims.isEmpty)
            ListTile(
              title: Text(
                _overview == null
                    ? 'Pickup task eligibility unavailable. Refresh to verify.'
                    : _hasAssignedPickups
                    ? 'No eligible claimed pickup tasks remain for a new route. Existing pickups are assigned to your route below. Review its pickup readiness.'
                    : 'No eligible claimed pickup tasks are available for a new route. Review claim eligibility, leases and reconciliation in My Claims.',
              ),
            ),
          for (final t in _displayClaims)
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text('${t['title'] ?? 'Claimed pickup'}'),
              subtitle: Text(
                '${t['load_kg'] ?? t['listing_weight_kg'] ?? '—'} kg · ${t['task_status'] ?? '—'}\n'
                '${claimLeaseMessage(t, eligible: _eligibleClaimIds.contains(t['claim_id']))}',
              ),
            ),
          if (!repository.planningConfigured &&
              !repository.combinedPlanningConfigured)
            Text(
              repository.plannerConfigurationMessage,
              key: const Key('planner-configuration-error'),
            ),
          if (_overview != null && _overview!['policy_id'] == null)
            const Text(
              'Route planning is not available yet. Your claim is retained; contact the coordinator.',
              key: Key('routing-policy-unavailable'),
            ),
          if (_routeOperation.isNotEmpty)
            Card(
              child: ListTile(
                title: Text(
                  _routeOperation['status'] == 'authorized'
                      ? 'Previously authorized route retained. Review it below; this is not a new authorization.'
                      : NgoRoutingRepository.isFinishedPreflight(
                          _routeOperation,
                        )
                      ? 'Route setup stopped before generation.'
                      : 'Route setup needs attention.',
                ),
                subtitle:
                    _routeOperation['status'] != 'authorized' &&
                        _routeOperation['failure_code'] is String
                    ? Text(
                        routingFailureMessage(
                              _routeOperation['failure_code'],
                            ) ??
                            'No route is confirmed. Open Route support for help.',
                      )
                    : null,
                trailing: _routeOperation['status'] == 'authorized'
                    ? TextButton(
                        key: const Key('archive-authorization'),
                        onPressed: actionsEnabled
                            ? _archiveAuthorization
                            : null,
                        child: const Text('Keep history / allow new planning'),
                      )
                    : TextButton(
                        onPressed:
                            actionsEnabled &&
                                NgoRoutingRepository.isFinishedPreflight(
                                  _routeOperation,
                                )
                            ? _dismissFinishedSetup
                            : _showSupport,
                        child: Text(
                          NgoRoutingRepository.isFinishedPreflight(
                                _routeOperation,
                              )
                              ? 'Dismiss interrupted setup'
                              : 'Get help',
                        ),
                      ),
              ),
            ),
          if (_pendingPlanning['status'] == 'pending')
            const Text(
              'Route setup needs attention. Open Route support; no new request will be sent automatically.',
            ),
          FilledButton.icon(
            key: const Key('generate-route'),
            onPressed:
                !_generating &&
                    actionsEnabled &&
                    _overview?['authorization_enforced'] == true &&
                    _overview?['policy_id'] is String &&
                    repository.combinedPlanningConfigured &&
                    _routeOperation.isEmpty &&
                    _pendingPlanning['status'] != 'pending' &&
                    _selected.isNotEmpty &&
                    _displayClaims.isNotEmpty
                ? _generate
                : null,
            icon: _generating
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.route),
            label: Text(
              _generating ? 'Generating route…' : 'Generate & Authorize Route',
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Your pickup routes',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          for (final r in routingRows(_overview?['routes'] ?? []))
            PickupRouteCard(
              overview: r,
              detail: _routeDetails[r['route_id']],
              fresh: actionsEnabled,
              onTap: () => _openRoute(r['route_id'] as String),
              reconciliationRequired: routeNeedsReconciliation(
                _routeDetails[r['route_id']],
                _claims,
              ),
              reconciliationVerified:
                  _claimsVerified && _routeDetails[r['route_id']] != null,
            ),
        ],
      ),
    ),
  );

  bool get _hasAssignedPickups => _routeDetails.values.any(
    (r) =>
        r['authorization_confirmed'] == true &&
        routingRows(r['stops'] ?? []).isNotEmpty,
  );

  String _vehicleAvailability(Map<String, dynamic> vehicle) {
    final bound = _routeDetails.values.any(
      (r) =>
          r['vehicle_id'] == vehicle['vehicle_id'] &&
          r['authorization_confirmed'] == true,
    );
    if (vehicle['active_flag'] == false) return 'Inactive vehicle';
    if (bound) {
      return 'Reserved for an existing route; unavailable for new planning. Other eligibility checks still apply.';
    }
    if (vehicle['available_for_planning'] == false) {
      return 'Not available for new planning. Review vehicle availability and depot verification.';
    }
    return 'Not eligible: reservation, depot verification or other backend checks require review.';
  }

  Set<Object?> get _eligibleClaimIds => routingRows(
    _overview?['eligible_tasks'] ?? [],
  ).map((task) => task['claim_id']).toSet();

  List<Map<String, dynamic>> get _displayClaims {
    // The protected overview is the only admission authority. Claim cards enrich
    // those admitted tasks; they never add an excluded task back into routing.
    final cards = {for (final c in _claims) c['claim_id']: c};
    return routingRows(_overview?['eligible_tasks'] ?? [])
        .where((task) {
          final card = cards[task['claim_id']];
          if (card == null) return true;
          if (card['lease_is_expired'] == true ||
              card['lease_recovery_pending'] == true) {
            return false;
          }
          final now = DateTime.tryParse('${card['server_now'] ?? ''}');
          final end = DateTime.tryParse('${card['lease_expires_at'] ?? ''}');
          return now == null || end == null || end.isAfter(now);
        })
        .map((task) => {...?cards[task['claim_id']], ...task})
        .toList();
  }
}

class NgoRouteDetailPage extends StatefulWidget {
  const NgoRouteDetailPage({
    super.key,
    required this.routeId,
    this.repository,
    this.mapBuilder,
  });
  final String routeId;
  final RoutingMapBuilder? mapBuilder;
  final NgoRoutingRepository? repository;
  @override
  State<NgoRouteDetailPage> createState() => _NgoRouteDetailPageState();
}

class _NgoRouteDetailPageState extends NgoSessionPage<NgoRouteDetailPage> {
  @override
  NgoRoutingRepository? get injectedRepository => widget.repository;
  Map<String, dynamic>? _route;
  Map<String, dynamic> _execution = {};
  String? _pendingMixedCloseRequest;
  List<Map<String, dynamic>> _resolutionClaims = [];
  bool _resolutionClaimsVerified = false;
  Timer? _privateLocationExpiry;
  late final _executor = RouteExecutionController(repository);
  late final _checkpointRepository = ClaimCoordinationRepository(
    rpc: (name, params) => repository.coordinationRpc(name, params),
    identity: () => repository.identity,
  );
  @override
  Future<Object?> fetch() async {
    final pendingClose = await repository.pendingMixedRouteClosure(
      widget.routeId,
    );
    final route = await repository.detail(widget.routeId);
    List<Map<String, dynamic>> claims = [];
    bool claimsVerified = false;
    try {
      claims = await repository.claimedPickups();
      claimsVerified = true;
    } catch (_) {
      // Missing evidence is never permission to release or start a pickup.
    }
    return {
      'route': route,
      'resolution_claims': claims,
      'resolution_claims_verified': claimsVerified,
      'execution': await _executor.reconcile(widget.routeId, route),
      'pending_mixed_close_request': pendingClose,
    };
  }

  @override
  void received(Object? value) {
    final data = routingObject(value);
    final route = routingObject(data['route']);
    _execution = routingObject(data['execution']);
    _pendingMixedCloseRequest = data['pending_mixed_close_request'] as String?;
    _resolutionClaims = routingRows(data['resolution_claims'] ?? []);
    _resolutionClaimsVerified = data['resolution_claims_verified'] == true;
    final claimsById = {
      for (final row in _resolutionClaims)
        if (row['claim_id'] is String)
          row['claim_id'] as String: ClaimCard.fromJson(row),
    };
    _privateLocationExpiry?.cancel();
    _privateLocationExpiry = null;
    Duration? nextExpiryDelay;
    final stops = <Map<String, dynamic>>[];
    for (final rawStop in routingRows(route['stops'])) {
      final stop = Map<String, dynamic>.from(rawStop);
      if (stop['source_type'] == 'DIRECT_DONATION') {
        final claim = claimsById[stop['claim_id']?.toString()];
        if (claim?.isValidActive != true) {
          _redactPrivateStopLocation(stop);
        } else {
          final expiresAt = claim!.leaseExpiresAt!;
          final serverNow = claim.serverNow!;
          final delay = expiresAt.difference(serverNow);
          if (nextExpiryDelay == null || delay < nextExpiryDelay) {
            nextExpiryDelay = delay;
          }
        }
      }
      stops.add(stop);
    }
    if (nextExpiryDelay != null) {
      const safetyMargin = Duration(seconds: 2);
      if (nextExpiryDelay <= safetyMargin) {
        // If the valid response is already near lease expiry, hide direct
        // locations now and refresh after its server-derived remaining time.
        for (final stop in stops) {
          if (stop['source_type'] == 'DIRECT_DONATION') {
            _redactPrivateStopLocation(stop);
          }
        }
        final delay = nextExpiryDelay > Duration.zero
            ? nextExpiryDelay
            : Duration.zero;
        _privateLocationExpiry = Timer(delay, () => unawaited(reload()));
      } else {
        _privateLocationExpiry = Timer(
          nextExpiryDelay - safetyMargin,
          _expirePrivateLocations,
        );
      }
    }
    _route = {...route, 'stops': stops};
  }

  static void _redactPrivateStopLocation(Map<String, dynamic> stop) {
    stop['pickup_address'] = null;
    stop['pickup_latitude'] = null;
    stop['pickup_longitude'] = null;
    stop['pickup_road_node_id'] = null;
    stop['can_start'] = false;
    stop['can_complete'] = false;
  }

  void _expirePrivateLocations() {
    if (!mounted || _route == null) return;
    setState(() {
      _route = {
        ..._route!,
        'stops': [
          for (final raw in routingRows(_route!['stops']))
            if (raw['source_type'] == 'DIRECT_DONATION')
              _redactedCopy(raw)
            else
              raw,
        ],
      };
    });
    _privateLocationExpiry = Timer(
      const Duration(seconds: 2),
      () => unawaited(reload()),
    );
  }

  static Map<String, dynamic> _redactedCopy(Map<String, dynamic> stop) {
    final result = Map<String, dynamic>.from(stop);
    _redactPrivateStopLocation(result);
    return result;
  }

  @override
  void clearSessionData() {
    _privateLocationExpiry?.cancel();
    _privateLocationExpiry = null;
    _route = null;
    _execution = {};
    _pendingMixedCloseRequest = null;
    _resolutionClaims = [];
    _resolutionClaimsVerified = false;
  }

  @override
  void dispose() {
    _privateLocationExpiry?.cancel();
    super.dispose();
  }

  bool get authorized =>
      actionsEnabled &&
      _route?['authorization_confirmed'] == true &&
      !RouteExecutionController.held(_execution);

  bool get _isTerminal => const {
    'COMPLETED',
    'CANCELLED',
    'ABANDONED',
  }.contains(_route?['route_status']);

  bool get canRecoverSavedDeferral =>
      actionsEnabled && _route?['authorization_confirmed'] == true;

  Map<String, dynamic>? get _currentStop =>
      _route == null ? null : RouteExecutionController.currentStop(_route!);

  bool get _canContinue =>
      mounted &&
      fresh &&
      ModalRoute.of(context)?.isCurrent == true &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  Future<void> _action(Future<void> Function() action) async {
    final previousAttempt = (_execution['attempt'] as Map?)?['id'];
    await perform(action);
    final failure = error;
    if (mounted) {
      await reload();
      final attempt = _execution['attempt'] as Map?;
      final reconciled =
          attempt?['id'] != previousAttempt &&
          attempt?['outcome'] == 'observed_confirmed';
      if (mounted && failure != null && !reconciled) {
        setState(() => error = failure);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Route details'),
      actions: [
        IconButton(
          onPressed: busy ? null : reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ...notices,
          if (!_resolutionClaimsVerified && !loading)
            const Text('Reconciliation status unavailable; refresh to verify.'),
          if (routeNeedsReconciliation(_route, _resolutionClaims))
            const Text(
              'A pickup needs individual claim reconciliation. Open the affected claim from Claims; unrelated route stops remain subject to their own backend safety checks.',
            ),
          Card(
            key: const Key('route-summary'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${routeStatusLabel(_route?['route_status'])} · ${_route?['vehicle_label'] ?? 'Assigned vehicle'}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${routeNumber(_route?['total_distance_km'])} km · ${routeNumber(_route?['total_duration_min'])} min · ${routeLoadText(_route?['total_load_kg'])} kg · ${_route?['pickup_count'] ?? '—'} pickups',
                  ),
                  const Text(
                    'Estimated duration includes service, waiting and return to depot.',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Planned departure: ${routeMytTime(_route?['departure_at'])}',
                  ),
                  Text(
                    'Actual pickup start: ${routeMytTime(_route?['actual_started_at'], missing: 'Not started')}',
                  ),
                  Text(
                    _route?['route_status'] == 'COMPLETED'
                        ? 'Route completed. No further pickup actions.'
                        : _route?['route_status'] == 'CANCELLED'
                        ? 'Route cancelled. No further pickup actions.'
                        : _route?['route_status'] == 'ABANDONED'
                        ? 'Route closed. Review the individual pickup outcomes below.'
                        : _route?['authorization_confirmed'] == true
                        ? 'Database authorization confirmed'
                        : 'No current database authorization — actions disabled',
                    key: const Key('route-authority'),
                  ),
                ],
              ),
            ),
          ),
          if (_execution['message'] is String)
            ListTile(
              key: const Key('route-execution-message'),
              leading: Icon(
                RouteExecutionController.held(_execution)
                    ? Icons.warning_amber
                    : Icons.route,
              ),
              title: Text(_execution['message'] as String),
            ),
          if (_route != null &&
              _currentStop != null &&
              !_isTerminal &&
              _currentStop?['task_status'] != 'DISPATCHED')
            FilledButton(
              key: const Key('start-route'),
              onPressed: authorized && _currentStop?['can_start'] == true
                  ? () => _action(
                      () => _executor.startRoute(
                        widget.routeId,
                        canContinue: () => _canContinue,
                      ),
                    )
                  : null,
              child: Text(
                _route?['actual_started_at'] == null &&
                        _execution['intent_id'] == null
                    ? 'Start Route'
                    : 'Continue route',
              ),
            ),
          if (const {
                'AUTHORISED',
                'IN_PROGRESS',
              }.contains(_route?['route_status']) &&
              _route?['depot'] is Map) ...[
            const Text('Road geometry unavailable - markers only.'),
            ProposedRouteMap(
              key: ValueKey('authorized-map-${widget.routeId}'),
              mapBuilder: widget.mapBuilder,
              route: {
                'depot': _route!['depot'],
                'stops': [
                  for (final stop in routingRows(_route!['stops']))
                    {
                      ...stop,
                      'latitude': stop['pickup_latitude'],
                      'longitude': stop['pickup_longitude'],
                      'display_name':
                          stop['title'] ?? 'Pickup ${stop['stop_order']}',
                      'display_address': routeDisplayAddress(
                        stop['pickup_address'],
                      ),
                    },
                ],
              },
            ),
          ],
          if (_route?['dispatch_block_reason'] != null)
            Text(
              routingDispatchMessage(_route!['dispatch_block_reason']),
              key: const Key('dispatch-block-reason'),
            ),
          if (_route?['awaiting_individual_reconciliation'] == true)
            const ListTile(
              key: Key('awaiting-individual-reconciliation'),
              leading: Icon(Icons.hourglass_top),
              title: Text('Awaiting individual reconciliation'),
              subtitle: Text(
                'Other eligible pickups are complete. The skipped pickup remains assigned and the vehicle stays reserved until it has a final outcome.',
              ),
            ),
          if (_execution['status'] == 'retryable_same_request' &&
              (_execution['attempt'] as Map?)?['kind'] == 'defer')
            Card(
              key: const Key('retry-saved-deferral'),
              child: ListTile(
                leading: const Icon(Icons.sync),
                title: const Text('Skip request outcome is uncertain'),
                subtitle: const Text(
                  'Check the protected receipt and, only if absent, retry the same saved request ID.',
                ),
                trailing: OutlinedButton(
                  onPressed: canRecoverSavedDeferral
                      ? () async {
                          final attempt = _execution['attempt'] as Map;
                          await _action(
                            () => _executor.deferForReconciliation(
                              widget.routeId,
                              attempt['task_id'] as String,
                              canContinue: () => _canContinue,
                            ),
                          );
                        }
                      : null,
                  child: const Text('Recover saved request'),
                ),
              ),
            ),
          if (_pendingMixedCloseRequest != null)
            Card(
              key: const Key('recover-mixed-route-close'),
              child: ListTile(
                leading: const Icon(Icons.receipt_long),
                title: const Text('Mixed route closure needs receipt recovery'),
                subtitle: const Text(
                  'Check the protected receipt. If the original closure did not commit, the same saved request ID will be used.',
                ),
                trailing: OutlinedButton(
                  onPressed: actionsEnabled
                      ? () => _action(() => repository.close(widget.routeId))
                      : null,
                  child: const Text('Recover saved closure'),
                ),
              ),
            ),
          for (final s in routingRows(_route?['stops'] ?? []))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Chip(
                      label: Text(
                        s['lease_expired_pending_recovery'] == true
                            ? 'Waiting for expiry recovery'
                            : s['deferred_status'] == 'RESOLVED_UNCOLLECTED'
                            ? 'Not collected — resolved'
                            : s['deferred_for_reconciliation'] == true
                            ? 'Needs reconciliation'
                            : s['needs_reconciliation'] == true
                            ? 'Needs reconciliation'
                            : s['task_status'] == 'COLLECTED'
                            ? 'Completed pickup'
                            : _route?['route_status'] == 'CANCELLED'
                            ? 'Not started'
                            : s['task_id'] == _currentStop?['task_id']
                            ? s['task_status'] == 'DISPATCHED'
                                  ? 'Current pickup'
                                  : 'Next pickup — not started'
                            : 'Upcoming pickup',
                      ),
                    ),
                    Text('${s['stop_order']}. ${s['title'] ?? 'Pickup'}'),
                    Text(
                      '${s['source_type'] == 'HUB_BATCH' ? 'Community hub pickup' : 'Pickup'} · ${routeLoadText(s['load_kg'])} kg',
                    ),
                    if (s['pickup_address'] != null)
                      Text(routeDisplayAddress(s['pickup_address'])),
                    Text(
                      'Planned arrival: ${routeMytTime(s['planned_arrival'])}',
                    ),
                    if (s['lease_expired_pending_recovery'] == true)
                      const Text(
                        'The lease has expired, but the protected backend recovery process has not opened reconciliation yet. Refresh later; skip remains unavailable until the backend authorizes deferral.',
                      ),
                    if (!_isTerminal)
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            onPressed:
                                authorized &&
                                    s['can_complete'] == true &&
                                    s['task_id'] == _currentStop?['task_id']
                                ? () async {
                                    if (await routingConfirm(
                                      context,
                                      'Confirm handover?',
                                      'Confirm that the physical pickup and handover have completed.',
                                    )) {
                                      if (mounted) {
                                        await _action(
                                          () => _executor.completeCurrent(
                                            widget.routeId,
                                            s['task_id'] as String,
                                            canContinue: () => _canContinue,
                                          ),
                                        );
                                      }
                                    }
                                  }
                                : null,
                            child: const Text('Complete pickup'),
                          ),
                          if (s['can_defer'] == true)
                            OutlinedButton(
                              key: Key('defer-pickup-${s['task_id']}'),
                              onPressed: authorized
                                  ? () async {
                                      if (await routingConfirm(
                                        context,
                                        'Skip this pickup for now?',
                                        'This stop will remain assigned and require individual reconciliation. It will not be collected, released, or reassigned. You can continue only if the backend confirms the remaining route is safe.',
                                      )) {
                                        if (mounted) {
                                          await _action(
                                            () => _executor
                                                .deferForReconciliation(
                                                  widget.routeId,
                                                  s['task_id'] as String,
                                                  canContinue: () =>
                                                      _canContinue,
                                                ),
                                          );
                                        }
                                      }
                                    }
                                  : null,
                              child: const Text('Skip for now and continue'),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          if (!_isTerminal &&
              _route != null &&
              _route?['actual_started_at'] != null)
            VehicleDepotCheckpoint(
              key: ValueKey('checkpoint-${widget.routeId}'),
              routeId: widget.routeId,
              requiredCheckpoint:
                  _route?['vehicle_checkpoint_required'] == true &&
                  _route?['can_close'] != true,
              authorized: authorized,
              repository: _checkpointRepository,
              readRoute: () => repository.detail(widget.routeId),
              onChanged: reload,
            ),
          if (routeNoCollectionSummary(_route) != null)
            Text(routeNoCollectionSummary(_route)!),
          if (!_isTerminal && routeNoCollectionSummary(_route) == null) ...[
            const Text(
              'The vehicle remains reserved until every pickup is resolved and return to the NGO depot is confirmed.',
            ),
            FilledButton(
              onPressed: authorized && _route?['can_close'] == true
                  ? () async {
                      if (await routingConfirm(
                        context,
                        'Close route and release vehicle?',
                        _route?['closure_kind'] == 'NO_COLLECTION'
                            ? 'No goods were collected. Confirm the vehicle is back at its registered NGO depot and under NGO control. This closes the started route without claiming goods were returned.'
                            : _route?['closure_outcome'] == 'ABANDONED'
                            ? 'Confirm every pickup has a final outcome and the vehicle has returned to its NGO depot. The route will close as ABANDONED because at least one pickup was independently resolved as uncollected.'
                            : 'Confirm that all pickups are complete and the vehicle has returned to its NGO depot.',
                      )) {
                        if (mounted) {
                          await _action(() => repository.close(widget.routeId));
                        }
                      }
                    }
                  : null,
              child: Text(
                _route?['closure_kind'] == 'NO_COLLECTION'
                    ? 'No goods collected — confirm vehicle return and close route'
                    : 'Confirm depot return and close route',
              ),
            ),
          ],
          if (!_isTerminal &&
              !(_route?['route_status'] == 'CANCELLED' &&
                  _route?['cancellation_outcome'] == 'NO_COLLECTION'))
            TextButton(
              onPressed: authorized && _route?['can_cancel'] == true
                  ? () async {
                      if (await routingConfirm(
                        context,
                        'Cancel unstarted route?',
                        _route?['no_collection_cancellation_eligible'] == true
                            ? 'Cancel this route without collection. Released claims, pickup outcomes and route history will be preserved. The vehicle reservation will be released.'
                            : 'Pickup must not have started. PostgreSQL will check that every task can safely return to planning.',
                      )) {
                        if (mounted) {
                          await _action(
                            () => repository.cancel(widget.routeId),
                          );
                        }
                      }
                    }
                  : null,
              child: Text(
                _route?['no_collection_cancellation_eligible'] == true
                    ? 'Cancel Route — No Pickups Completed'
                    : 'Cancel unstarted route',
              ),
            ),
        ],
      ),
    ),
  );
}
