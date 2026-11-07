import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../supabase_config.dart';
import 'routing_worker_client.dart';
import 'routing_feedback.dart';

typedef RpcCall =
    Future<Object?> Function(String name, Map<String, dynamic> params);
typedef PlanCall = Future<Object?> Function(Map<String, dynamic> body);

Map<String, dynamic> routingObject(Object? value) {
  if (value is! Map) throw const FormatException('Invalid backend response.');
  return Map<String, dynamic>.from(value);
}

List<Map<String, dynamic>> routingRows(Object? value) {
  if (value is! List) throw const FormatException('Invalid backend list.');
  return value.map(routingObject).toList(growable: false);
}

String routingError(Object error) {
  if (error is RoutingRequestFailure) {
    return routingFailureMessage(error.code) ??
        (error.outcomeUnknown
            ? 'The route request outcome is not confirmed. Keep the saved request and check its outcome in troubleshooting.'
            : 'The routing service did not confirm this request. Review troubleshooting before trying again.');
  }
  if (error is PostgrestException) {
    final friendly = routingFailureMessage(error.message);
    if (friendly != null) return friendly;
    if (error.code == 'PGRST202' || error.code == '42883') {
      return 'Routing backend is not deployed. Fleet management is available separately.';
    }
    final messages = <String, String>{
      'VEHICLE_HAS_ACTIVE_ROUTE':
          'Vehicle is reserved. Finish or safely cancel its route first.',
      'VEHICLE_VERSION_CONFLICT':
          'Vehicle changed. Refresh and review before trying again.',
      'NGO_LOCATION_NOT_VERIFIED':
          'Verify your NGO operational depot before registering a vehicle.',
      'HANDOVER_NOT_CONFIRMED':
          'Confirm the physical handover before completing pickup.',
      'DATABASE_DISPATCH_AUTHORIZATION_REQUIRED':
          'Plan and authorize a managed route before starting pickup.',
      'OWNED_MANAGED_ROUTE_NOT_FOUND':
          'This route is unavailable for your signed-in NGO. Refresh your routes.',
      'STARTED_ROUTE_REQUIRES_RECONCILIATION':
          'Pickup has started. Resolve the claim through reconciliation before releasing its route.',
      'RESERVED_TASK_REQUIRES_RECONCILIATION':
          'This reserved pickup needs reconciliation. Open its claim details.',
    };
    return messages[error.message] ??
        'Database did not confirm the operation: ${error.message}';
  }
  if (error is StateError || error is FormatException) return '$error';
  return 'Request was not confirmed. Check your connection and refresh.';
}

/// Display only. Action permission always comes from a fresh protected read.
String routingDispatchMessage(Object? reason) => switch (reason) {
  'BEFORE_AUTHORIZED_DEPARTURE' =>
    'Pickup can start at the authorized departure time. Refresh when ready.',
  'PREVIOUS_PICKUP_UNRESOLVED' =>
    'Complete the pickup already in progress before starting the next stop.',
  'STOP_ORDER_REQUIRED' => 'Follow the stop order in this route.',
  'DISPATCH_SOURCE_STALE' ||
  'DISPATCH_AUTHORITY_STALE' ||
  'ROUTE_BINDING_DRIFT' =>
    'Route inputs changed. Refresh; unresolved pickups may require reconciliation.',
  'DISPATCH_WINDOW_OR_LEASE_EXPIRED' || 'REMAINING_ROUTE_INFEASIBLE' =>
    'The remaining route no longer fits its pickup windows or leases. Refresh and review the claim.',
  _ => 'Pickup is unavailable. Refresh the route and review its claim details.',
};

/// Only owned RPCs; never direct fleet/route writes or a service-role key.
class NgoRoutingRepository {
  NgoRoutingRepository({
    required this._rpc,
    required this._identity,
    Stream<void>? identityChanges,
    this._planner,
    this.plannerReady,
    this.savedPlanner,
    this.combinedPlanner,
    this.authorizationReader,
    this.authorizationCapabilities,
    this.plannerConfigurationError,
  }) : identityChanges = identityChanges ?? const Stream.empty();

  factory NgoRoutingRepository.live() {
    final client = Supabase.instance.client;
    const function = String.fromEnvironment('GEOLOCK_ROUTING_FUNCTION');
    const apiUrl = String.fromEnvironment('GEOLOCK_ROUTING_API_URL');
    final configurationError = RoutingWorkerClient.configurationErrorCode(
      apiUrl,
      environment: SupabaseConfig.environment,
    );
    if (kDebugMode) {
      debugPrint(
        'GeoLockRouting configuration=${configurationError ?? 'READY'}',
      );
    }
    final direct = configurationError == null
        ? RoutingWorkerClient(
            baseUrl: apiUrl.trim(),
            accessToken: () => client.auth.currentSession?.accessToken,
          )
        : null;
    PlanCall? devCall(PlanCall? call) => call == null
        ? null
        : (body) {
            if (SupabaseConfig.environment != 'dev') {
              throw StateError('Routing is DEV only.');
            }
            return call(body);
          };
    return NgoRoutingRepository(
      rpc: (name, params) async {
        if (SupabaseConfig.environment != 'dev') {
          throw StateError('Routing is DEV only.');
        }
        return client.rpc(name, params: params);
      },
      identity: () => client.auth.currentUser?.id,
      identityChanges: client.auth.onAuthStateChange.map((_) {}),
      plannerConfigurationError: configurationError,
      plannerReady: direct?.checkReady,
      combinedPlanner: devCall(direct?.planAndAuthorize),
      authorizationReader: devCall(direct?.authorizationResult),
      authorizationCapabilities: devCall(direct?.authorizationCapabilities),
      savedPlanner: direct == null
          ? null
          : (body) async {
              if (SupabaseConfig.environment != 'dev') {
                throw StateError('Routing is DEV only.');
              }
              return direct.savedResult(body);
            },
      planner: direct != null
          ? (body) async {
              if (SupabaseConfig.environment != 'dev') {
                throw StateError('Routing is DEV only.');
              }
              return direct.plan(body);
            }
          : function.isEmpty
          ? null
          : (body) async {
              if (SupabaseConfig.environment != 'dev') {
                throw StateError('Routing is DEV only.');
              }
              final response = await client.functions.invoke(
                function,
                body: body,
              );
              if (response.status != 200) {
                throw StateError('Planning service did not confirm a result.');
              }
              return response.data;
            },
    );
  }

  final RpcCall _rpc;
  final String? plannerConfigurationError;
  String get plannerConfigurationMessage => switch (plannerConfigurationError) {
    'PLANNER_DEV_BUILD_REQUIRED' => 'Routing requires the DEV app build.',
    'PLANNER_URL_REJECTED' =>
      'The planner URL in this build is invalid or disallowed. Install a verified DEV routing build.',
    _ =>
      'The planner URL is missing from this build. Install a DEV build with GEOLOCK_ROUTING_API_URL configured.',
  };
  final String? Function() _identity;
  final PlanCall? _planner;
  final PlanCall? savedPlanner;
  final PlanCall? combinedPlanner,
      authorizationReader,
      authorizationCapabilities;
  Future<Map<String, dynamic>>? _combinedFlight;
  static final Set<String> _archivingOwners = {};
  String? _combinedSignature;
  final Future<void> Function()? plannerReady;
  final Stream<void> identityChanges;
  String? get identity => _identity();
  Future<Object?> coordinationRpc(String name, Map<String, dynamic> params) {
    if (!{
      'get_my_coordination_receipt',
      'confirm_my_route_depot_checkpoint',
    }.contains(name)) {
      throw StateError('Unsupported vehicle coordination operation.');
    }
    return _call(name, params);
  }

  bool get planningConfigured => _planner != null;
  bool get canCheckPlanner => plannerReady != null;
  bool get canReadSavedPlanning => savedPlanner != null;
  bool get combinedPlanningConfigured =>
      combinedPlanner != null &&
      authorizationReader != null &&
      authorizationCapabilities != null;

  Future<Map<String, dynamic>> routeOperation() async {
    final owner = identity;
    if (owner == null) return {};
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString('ngo_route_operation_$owner');
    if (identity != owner) throw StateError('Account changed.');
    return text == null ? {} : routingObject(jsonDecode(text));
  }

  /// Only this durable phase proves no snapshot/business RPC was attempted.
  static bool isFinishedPreflight(Map<String, dynamic> operation) =>
      operation['status'] == 'blocked' &&
      operation['phase'] == 'preflight' &&
      operation['intent'] == 'GENERATE_AND_AUTHORIZE' &&
      operation['snapshot_id'] == null &&
      operation['authorization'] == null &&
      operation['authorization_request_id'] == null;

  /// Reopening a page may read a receipt, never resume planning or authorization.
  Future<Map<String, dynamic>> restoreRouteOperation() async {
    final operation = await routeOperation();
    if (operation['snapshot_id'] is String && authorizationReader != null) {
      try {
        final result = await reconcileRouteOperation();
        if (result['kind'] == 'DATABASE_AUTHORIZATION_RECEIPT') {
          await _finishRouteOperation(allowCombinedFlight: false);
        }
      } catch (_) {
        // Receipt/archive failure is not proof of rollback. Keep every ID and
        // leave the existing manual recovery action available.
      }
    }
    return routeOperation();
  }

  Future<void> _saveOperation(String owner, Map<String, dynamic> value) async {
    final prefs = await SharedPreferences.getInstance();
    if (identity != owner ||
        !await prefs.setString(
          'ngo_route_operation_$owner',
          jsonEncode(value),
        )) {
      throw StateError(
        'Cannot preserve the route operation. No new operation should be sent.',
      );
    }
  }

  Future<Map<String, dynamic>> generateAndAuthorize(
    List<String> vehicles,
    String requestId,
    String policyId,
  ) {
    if (_archivingOwners.contains(identity)) {
      return Future.error(
        StateError('Authorization history is being verified.'),
      );
    }
    final selected = vehicles.toSet().toList()..sort();
    final signature = jsonEncode([identity, selected, policyId]);
    if (_combinedFlight != null) {
      if (signature != _combinedSignature) {
        return Future.error(StateError('Another route operation is pending.'));
      }
      return _combinedFlight!;
    }
    _combinedSignature = signature;
    final future = _startRouteOperation(selected, requestId, policyId);
    _combinedFlight = future;
    return future.whenComplete(() {
      _combinedFlight = null;
      _combinedSignature = null;
    });
  }

  Future<Map<String, dynamic>> _startRouteOperation(
    List<String> vehicles,
    String requestId,
    String policyId,
  ) async {
    final owner = identity;
    if (owner == null || vehicles.isEmpty || !combinedPlanningConfigured) {
      throw StateError('Combined routing is not configured.');
    }
    if ((await routeOperation()).isNotEmpty) {
      throw StateError(
        'Preserve the existing operation. Check its outcome or explicitly resume it.',
      );
    }
    final legacy = await pendingPlanning();
    if (legacy['status'] == 'pending') {
      throw StateError(
        'Reconcile the earlier uncertain planning request first.',
      );
    }
    final operation = <String, dynamic>{
      'request_id': requestId,
      'policy_id': policyId,
      'vehicle_ids': vehicles,
      'status': 'pending',
      'intent': 'GENERATE_AND_AUTHORIZE',
      'phase': 'preflight',
    };
    await _saveOperation(owner, operation);
    return _continueRouteOperation(owner, operation);
  }

  Future<Map<String, dynamic>> _continueRouteOperation(
    String owner,
    Map<String, dynamic> operation,
  ) async {
    try {
      final capability = _owned(
        await authorizationCapabilities!({
          'request_id': operation['request_id'],
        }),
        owner,
      );
      if (capability['contract'] != 'geolock.routing-auto-now.v1' ||
          capability['automatic_departure'] != true) {
        throw RoutingRequestFailure(
          'Automatic departure authority is unavailable',
          code: 'AUTOMATIC_AUTHORIZATION_CONTRACT_UNAVAILABLE',
          phase: 'preflight',
        );
      }
      if (capability['combined_generation_enabled'] != true) {
        throw RoutingRequestFailure(
          'Combined workflow is disabled',
          code: 'COMBINED_WORKFLOW_DISABLED',
          phase: 'preflight',
        );
      }
      if (plannerReady != null) await plannerReady!();
      if (operation['snapshot_id'] is! String) {
        operation = {...operation, 'phase': 'snapshot'};
        await _saveOperation(owner, operation);
        final snapshot = _owned(
          await _call('begin_my_routing_snapshot', {
            'p_request': operation['request_id'],
            'p_policy': operation['policy_id'],
            'p_vehicle_ids': operation['vehicle_ids'],
          }),
          owner,
        );
        if (snapshot['snapshot_id'] is! String) {
          throw const FormatException('Snapshot identity missing.');
        }
        operation = {...operation, 'snapshot_id': snapshot['snapshot_id']};
        await _saveOperation(owner, operation);
      }
      operation = {...operation, 'phase': 'combined'};
      await _saveOperation(owner, operation);
      final response = _owned(
        await combinedPlanner!({
          'request_id': operation['request_id'],
          'snapshot_id': operation['snapshot_id'],
          'authorize_on_success': true,
        }),
        owner,
      );
      if (response['kind'] == 'ADVISORY_CANDIDATE' &&
          response['outcome'] == 'INFEASIBLE' &&
          response['dispatch_authority_issued'] == false &&
          response['snapshot_id'] == operation['snapshot_id']) {
        await _saveOperation(owner, {...operation, 'status': 'infeasible'});
        return response;
      }
      final accepted = await _acceptAuthorization(owner, operation, response);
      if (accepted['kind'] == 'DATABASE_AUTHORIZATION_RECEIPT') {
        // The receipt and recovery IDs are already durable. Archive this local
        // planning request only after the same safe receipt/binding checks used
        // by the manual action. This never changes the authorized route.
        try {
          await _finishRouteOperation(allowCombinedFlight: true);
        } catch (_) {
          // Keep returning the confirmed route. A failed archive leaves the
          // durable authorized operation for startup retry or manual recovery.
        }
      }
      return accepted;
    } catch (error) {
      final latest = await routeOperation();
      if (identity == owner && latest['status'] != 'authorized') {
        final known =
            operation['phase'] == 'preflight' ||
            error is PostgrestException ||
            (error is RoutingRequestFailure && !error.outcomeUnknown);
        await _saveOperation(owner, {
          ...operation,
          'status': known ? 'blocked' : 'authorization_unknown',
          'failure_stage': error is RoutingRequestFailure
              ? error.phase
              : operation['phase'] ?? 'unknown',
          'failure_code': error is RoutingRequestFailure
              ? error.code
              : operation['phase'] == 'preflight'
              ? 'ROUTING_PREFLIGHT_FAILED'
              : 'ROUTING_OUTCOME_UNKNOWN',
          if (error is RoutingRequestFailure && error.httpStatus != null)
            'failure_http_status': error.httpStatus,
          if (error is PostgrestException &&
              RegExp(r'^[A-Z][A-Z0-9_]{1,79}$').hasMatch(error.message))
            'failure_code': error.message,
        });
        if (!known &&
            operation['snapshot_id'] is String &&
            authorizationReader != null) {
          try {
            final reconciled = await reconcileRouteOperation();
            if (reconciled['kind'] == 'DATABASE_AUTHORIZATION_RECEIPT') {
              try {
                await _finishRouteOperation(allowCombinedFlight: true);
              } catch (_) {
                // Keep the confirmed route result and durable fallback record.
              }
              return reconciled;
            }
          } catch (_) {
            // Read-only reconciliation failed; never retry the uncertain write.
          }
        }
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _acceptAuthorization(
    String owner,
    Map<String, dynamic> operation,
    Map<String, dynamic> response,
  ) async {
    final receipt = routingObject(response['authorization']);
    final ids = receipt['route_ids'];
    if (response['kind'] != 'DATABASE_AUTHORIZATION_RECEIPT' ||
        response['snapshot_id'] != operation['snapshot_id'] ||
        response['request_id'] != operation['request_id'] ||
        receipt['snapshot_id'] != operation['snapshot_id'] ||
        receipt['departure_mode'] != 'AUTO_NOW' ||
        response['authorization_request_id'] is! String ||
        receipt['candidate_id'] is! String ||
        ids is! List ||
        ids.isEmpty ||
        ids.length > 20 ||
        ids.toSet().length != ids.length ||
        ids.any((id) => id is! String)) {
      throw const FormatException(
        'Database authorization receipt was not confirmed.',
      );
    }
    final recorded = operation['authorization'];
    if ((operation['authorization_request_id'] != null &&
            operation['authorization_request_id'] !=
                response['authorization_request_id']) ||
        (recorded is Map &&
            (recorded['candidate_id'] != receipt['candidate_id'] ||
                recorded['snapshot_id'] != receipt['snapshot_id'] ||
                jsonEncode(recorded['route_ids']) !=
                    jsonEncode(receipt['route_ids'])))) {
      throw const FormatException('Recorded authorization receipt changed.');
    }
    await _saveOperation(owner, {
      ...operation,
      'status': 'authorized',
      'authorization_request_id': response['authorization_request_id'],
      // Retain the complete originally recorded receipt, including audit refs.
      'authorization': recorded is Map
          ? Map<String, dynamic>.from(recorded)
          : receipt,
    });
    final routes = <Map<String, dynamic>>[];
    for (final id in ids) {
      final route = await detail(id as String);
      if (route['candidate_id'] != receipt['candidate_id'] ||
          route['snapshot_id'] != operation['snapshot_id']) {
        throw const FormatException('Authorized route binding mismatch.');
      }
      routes.add(route);
    }
    return {...response, 'routes': routes};
  }

  Future<Map<String, dynamic>> reconcileRouteOperation() async {
    final owner = identity;
    final operation = await routeOperation();
    if (owner == null ||
        operation['snapshot_id'] is! String ||
        authorizationReader == null) {
      throw StateError(
        'No confirmed snapshot ID. Resume only the original operation; never create a replacement.',
      );
    }
    final response = _owned(
      await authorizationReader!({
        'request_id': operation['request_id'],
        'snapshot_id': operation['snapshot_id'],
      }),
      owner,
    );
    if (response['kind'] == 'AUTHORIZATION_UNCONFIRMED' &&
        response['snapshot_id'] == operation['snapshot_id'] &&
        response['request_id'] == operation['request_id']) {
      if ({'REJECTED', 'INFEASIBLE'}.contains(response['operation_terminal'])) {
        await _saveOperation(owner, {
          ...operation,
          'status': response['operation_terminal'] == 'REJECTED'
              ? 'rejected'
              : 'infeasible',
          'failure_code': response['failure_code'],
        });
      }
      return response;
    }
    return _acceptAuthorization(owner, operation, response);
  }

  Future<Map<String, dynamic>> resumeRouteOperation() async {
    final owner = identity;
    final operation = await routeOperation();
    if (owner == null ||
        !combinedPlanningConfigured ||
        operation['intent'] != 'GENERATE_AND_AUTHORIZE') {
      throw StateError('Original route operation unavailable.');
    }
    // This method is only invoked by an explicit Resume button. Always read first.
    if (operation['snapshot_id'] is String) {
      final result = await reconcileRouteOperation();
      if (result['kind'] == 'DATABASE_AUTHORIZATION_RECEIPT') {
        try {
          await _finishRouteOperation(allowCombinedFlight: false);
        } catch (_) {
          // Receipt remains saved; the page retains its manual recovery action.
        }
        return result;
      }
      if (result['operation_terminal'] != null) {
        throw StateError(
          'This operation ended. Reconcile and explicitly start another operation.',
        );
      }
    }
    if (operation['status'] == 'authorized') {
      throw StateError(
        'Authorization is recorded; refresh the existing route.',
      );
    }
    return _continueRouteOperation(owner, operation);
  }

  /// Archive a finished authorization REQUEST, not its still-active route.
  /// Only fresh owner-scoped receipt + protected route binding reads prove commit.
  Future<void> finishRouteOperation() =>
      _finishRouteOperation(allowCombinedFlight: false);

  Future<void> _finishRouteOperation({
    required bool allowCombinedFlight,
  }) async {
    final owner = identity;
    if (owner == null ||
        (_combinedFlight != null && !allowCombinedFlight) ||
        !_archivingOwners.add(owner)) {
      throw StateError('Operation is still pending.');
    }
    try {
      final operation = await routeOperation();
      if (operation.isEmpty) throw StateError('No operation to archive.');
      if (operation['snapshot_id'] is String) {
        final result = await reconcileRouteOperation();
        if (result['kind'] == 'DATABASE_AUTHORIZATION_RECEIPT') {
          final oldReceipt = operation['authorization'];
          final confirmed = routingObject(result['authorization']);
          // Never replace a previously recorded authorization with a different one.
          if ((operation['authorization_request_id'] != null &&
                  operation['authorization_request_id'] !=
                      result['authorization_request_id']) ||
              (oldReceipt is Map &&
                  (oldReceipt['candidate_id'] != confirmed['candidate_id'] ||
                      oldReceipt['snapshot_id'] != confirmed['snapshot_id'] ||
                      jsonEncode(oldReceipt['route_ids']) !=
                          jsonEncode(confirmed['route_ids'])))) {
            throw const FormatException(
              'Recorded authorization receipt changed.',
            );
          }
          // _acceptAuthorization already verified every owner-scoped route's
          // candidate/snapshot binding. Route completion is a separate lifecycle.
        } else if (!{
          'REJECTED',
          'INFEASIBLE',
        }.contains(result['operation_terminal'])) {
          throw StateError(
            'Authorization outcome remains uncertain. Preserve this operation.',
          );
        }
      } else if (!isFinishedPreflight(operation)) {
        throw StateError(
          'Snapshot outcome is uncertain. Resume only the original request.',
        );
      }
      final confirmed = await routeOperation();
      if (identity != owner ||
          confirmed['request_id'] != operation['request_id']) {
        throw StateError('Operation changed. History was not archived.');
      }
      final prefs = await SharedPreferences.getInstance();
      final key =
          'ngo_route_operation_history_${owner}_${operation['request_id']}';
      final previous = prefs.getString(key);
      final encoded = jsonEncode(confirmed);
      // Do not overwrite an earlier, different historical record.
      if (previous != null && previous != encoded) {
        throw StateError(
          'Existing history differs. Preserve both records for review.',
        );
      }
      if (identity != owner || !await prefs.setString(key, encoded)) {
        throw StateError('Cannot preserve authorization history.');
      }
      if (identity != owner ||
          jsonEncode(await routeOperation()) != encoded ||
          !await prefs.remove('ngo_route_operation_$owner')) {
        throw StateError(
          'Cannot archive the finished operation. History retained.',
        );
      }
      // Never edit route execution journals, legacy planning history or DB state.
    } finally {
      _archivingOwners.remove(owner);
    }
  }

  Future<Map<String, dynamic>> readSavedPlanning() async {
    final owner = identity;
    final saved = await pendingPlanning();
    if (owner == null ||
        savedPlanner == null ||
        saved['snapshot_id'] is! String ||
        !{'candidate_ready', 'infeasible'}.contains(saved['status'])) {
      throw StateError(
        'No completed saved planning result is available. No new request was sent.',
      );
    }
    final result = _owned(
      await savedPlanner!({
        'request_id': saved['request_id'],
        'snapshot_id': saved['snapshot_id'],
      }),
      owner,
    );
    if (identity != owner ||
        result['snapshot_id'] != saved['snapshot_id'] ||
        result['kind'] != 'ADVISORY_CANDIDATE' ||
        result['dispatch_authority_issued'] != false ||
        result['saved_result_display_only'] != true) {
      throw const FormatException('Saved result identity was not confirmed.');
    }
    return result;
  }

  Future<void> checkPlannerConnection() async {
    if (plannerReady == null) {
      throw StateError('No direct planner health check is configured.');
    }
    await plannerReady!();
  }

  Future<Object?> _call(
    String name, [
    Map<String, dynamic> params = const {},
  ]) async {
    final owner = identity;
    if (owner == null) throw StateError('Sign in as an NGO.');
    final result = await _rpc(name, params);
    if (identity != owner) throw StateError('Account changed. Refresh.');
    return result;
  }

  Map<String, dynamic> _owned(Object? value, String owner) {
    final row = routingObject(value);
    if ((!row.containsKey('ngo_id') && !row.containsKey('ngo_user_id')) ||
        (row.containsKey('ngo_id') && row['ngo_id'] != owner) ||
        (row.containsKey('ngo_user_id') && row['ngo_user_id'] != owner)) {
      throw const FormatException('Backend ownership mismatch.');
    }
    return row;
  }

  Future<Map<String, dynamic>> fleet() async {
    final owner = identity;
    final value = routingObject(await _call('list_my_vehicles'));
    for (final row in routingRows(value['vehicles'])) {
      _owned(row, owner!);
    }
    return value;
  }

  Future<Map<String, dynamic>> pendingRegistration() async {
    final owner = identity;
    if (owner == null) throw StateError('Sign in as an NGO.');
    final prefs = await SharedPreferences.getInstance();
    if (identity != owner) throw StateError('Account changed.');
    final value = prefs.getString('ngo_vehicle_registration_$owner');
    return value == null ? {} : routingObject(jsonDecode(value));
  }

  Future<void> register(Map<String, dynamic> fields) async {
    final owner = identity;
    if (owner == null) throw StateError('Sign in as an NGO.');
    final prefs = await SharedPreferences.getInstance();
    if (identity != owner) throw StateError('Account changed.');
    final key = 'ngo_vehicle_registration_$owner';
    final saved = prefs.getString(key);
    final payload = saved == null
        ? <String, dynamic>{'p_request_id': const Uuid().v4(), ...fields}
        : routingObject(jsonDecode(saved));
    if (jsonEncode(Map.of(payload)..remove('p_request_id')) !=
        jsonEncode(fields)) {
      throw StateError(
        'Retry the saved registration before submitting a different vehicle.',
      );
    }
    if (!await prefs.setString(key, jsonEncode(payload))) {
      throw StateError('Cannot save the registration retry key.');
    }
    if (identity != owner) throw StateError('Account changed.');
    _owned(await _call('register_my_vehicle', payload), owner);
    await prefs.remove(key);
  }

  Future<void> updateVehicle(
    Map<String, dynamic> vehicle,
    Map<String, dynamic> fields,
  ) async {
    final owner = identity;
    if (owner == null) throw StateError('Sign in as an NGO.');
    _owned(vehicle, owner);
    _owned(
      await _call('update_my_vehicle', {
        'p_vehicle_id': vehicle['vehicle_id'],
        'p_expected_version': vehicle['vehicle_version'],
        ...fields,
      }),
      owner,
    );
  }

  Future<void> availability(
    Map<String, dynamic> vehicle,
    bool available,
  ) async {
    _owned(vehicle, identity ?? '');
    await _call('set_my_vehicle_availability', {
      'p_vehicle_id': vehicle['vehicle_id'],
      'p_expected_version': vehicle['vehicle_version'],
      'p_available': available,
    });
  }

  Future<void> deactivate(Map<String, dynamic> vehicle) async {
    _owned(vehicle, identity ?? '');
    await _call('deactivate_my_vehicle', {
      'p_vehicle_id': vehicle['vehicle_id'],
      'p_expected_version': vehicle['vehicle_version'],
    });
  }

  Future<Map<String, dynamic>> overview() async {
    final owner = identity;
    final value = _owned(await _call('get_my_routing_overview'), owner!);
    if (value['contract'] != 'geolock.ngo-routing.v1') {
      throw const FormatException('Unsupported routing contract.');
    }
    routingRows(value['eligible_tasks']);
    routingRows(value['routes']);
    return value;
  }

  Future<List<Map<String, dynamic>>> claimedPickups() async =>
      routingRows(await _call('get_my_claim_cards_v2'));

  /// Owned display reads only. A missing address never changes plan authority.
  Future<Map<String, Map<String, dynamic>>> pickupDescriptions(
    List<Map<String, dynamic>> tasks,
  ) async {
    final owner = identity;
    final result = <String, Map<String, dynamic>>{};
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    final titles = <String, dynamic>{};
    if (tasks.any((t) => t['claim_id'] is String)) {
      try {
        for (final card in await claimedPickups().timeout(
          const Duration(seconds: 2),
        )) {
          titles[card['claim_id'] as String] = card['title'];
        }
      } catch (_) {
        /* Display metadata is optional; no planning retry. */
      }
    }
    for (final task in tasks.take(100)) {
      final remaining = deadline.difference(DateTime.now());
      if (identity != owner || remaining <= Duration.zero) break;
      if (task['claim_id'] is! String || task['task_id'] is! String) continue;
      try {
        final detail = routingObject(
          await _call('get_claimed_listing_detail', {
            'p_claim': task['claim_id'],
          }).timeout(
            remaining < const Duration(seconds: 2)
                ? remaining
                : const Duration(seconds: 2),
          ),
        );
        if (detail['claim_id'] != task['claim_id']) continue;
        if (task['listing_id'] != null &&
            detail['listing_id'] != task['listing_id']) {
          continue;
        }
        result[task['task_id'] as String] = {
          'title': titles[task['claim_id']],
          'pickup_address': detail['pickup_address'],
        };
      } catch (_) {
        // Keep the independently validated result; never retry planning for UI metadata.
      }
    }
    return identity == owner ? result : {};
  }

  Future<Map<String, dynamic>> detail(String routeId) async {
    final owner = identity;
    final row = _owned(
      await _call('get_my_authorized_route', {'p_route': routeId}),
      owner!,
    );
    if (row['route_id'] != routeId ||
        row['contract'] != 'geolock.ngo-routing.v1') {
      throw const FormatException('Invalid route identity.');
    }
    routingRows(row['stops']);
    return row;
  }

  Future<Map<String, dynamic>> plan(
    List<String> vehicles,
    String requestId,
    String policyId,
  ) async {
    if (_planner == null) {
      throw StateError('Routing worker is not connected yet.');
    }
    final owner = identity;
    if (owner == null || vehicles.isEmpty) {
      throw StateError('Select an eligible NGO vehicle.');
    }
    // Fail a broken ADB/phone connection BEFORE creating another DEV snapshot.
    // Health proves connectivity/project only, never NGO ownership or authority.
    if (plannerReady != null) await plannerReady!();
    final selected = vehicles.toSet().toList()..sort();
    var pending = await pendingPlanning();
    if (pending.isNotEmpty &&
        (pending['policy_id'] != policyId ||
            jsonEncode(pending['vehicle_ids']) != jsonEncode(selected))) {
      throw StateError(
        'A saved planning request uses different vehicles or policy. Reconcile it before starting another request.',
      );
    }
    pending = pending.isEmpty
        ? <String, dynamic>{
            'request_id': requestId,
            'policy_id': policyId,
            'vehicle_ids': selected,
            'status': 'pending',
          }
        : pending;
    // Save BEFORE the mutating snapshot RPC: even a lost RPC response must reuse
    // its original request ID. Refresh/rebuild cannot silently mint duplicates.
    await _savePlanning(owner, pending);
    final savedRequest = pending['request_id'] as String;
    String phase = 'begin_my_routing_snapshot';
    late Map<String, dynamic> result;
    try {
      if (pending['snapshot_id'] is! String) {
        final snapshot = _owned(
          await _call('begin_my_routing_snapshot', {
            'p_request': savedRequest,
            'p_policy': policyId,
            'p_vehicle_ids': selected,
          }),
          owner,
        );
        if (snapshot['snapshot_id'] is! String) {
          throw const FormatException('Invalid snapshot identity.');
        }
        pending = {...pending, 'snapshot_id': snapshot['snapshot_id']};
        await _savePlanning(owner, pending);
      }
      phase = 'planner_http';
      result = _owned(
        await _planner({
          'request_id': savedRequest,
          'snapshot_id': pending['snapshot_id'],
        }),
        owner,
      );
    } catch (error) {
      final failure = error is RoutingRequestFailure
          ? error
          : RoutingRequestFailure(
              phase == 'begin_my_routing_snapshot'
                  ? 'Snapshot request was not confirmed. Keep the saved request ID'
                  : 'Planning result was not confirmed. Keep the saved request and snapshot IDs',
              code: error is PostgrestException
                  ? 'SNAPSHOT_REJECTED'
                  : 'PLANNING_OUTCOME_UNKNOWN',
              phase: phase,
              requestId: savedRequest,
              snapshotId: pending['snapshot_id'] as String?,
              outcomeUnknown: error is! PostgrestException,
            );
      if (identity == owner) {
        await _savePlanning(owner, {
          ...pending,
          'status': failure.outcomeUnknown ? 'pending' : 'rejected',
          'failure_code': failure.code,
        });
      }
      throw failure;
    }
    if (identity != owner) throw StateError('Account changed.');
    if (result['kind'] != 'ADVISORY_CANDIDATE' ||
        result['dispatch_authority_issued'] != false ||
        result['snapshot_id'] != pending['snapshot_id']) {
      throw const FormatException(
        'Planning output cannot grant dispatch authority.',
      );
    }
    final methods = routingRows(result['methods']);
    if (methods.length != 4 ||
        !methods.map((m) => m['method']).toSet().containsAll({
          'fcfs',
          'nearest_neighbour',
          'distance_only',
          'proposed',
        })) {
      throw const FormatException('Incomplete routing comparison.');
    }
    for (final method in methods) {
      final plan = routingObject(method['plan']);
      final validation = routingObject(method['validation']);
      routingObject(validation['metrics']);
      if (plan['dispatch_authority_issued'] != false ||
          plan['method'] != method['method']) {
        throw const FormatException('Invalid advisory route comparison.');
      }
      for (final route in routingRows(plan['routes'])) {
        if (route['return_us'] is! num || route['vehicle_id'] is! String) {
          throw const FormatException('Invalid route schedule.');
        }
        routingRows(route['stops']);
      }
    }
    await _savePlanning(owner, {
      ...pending,
      'status': result['outcome'] == 'INFEASIBLE'
          ? 'infeasible'
          : 'candidate_ready',
    });
    return result;
  }

  Future<Map<String, dynamic>> pendingPlanning() async {
    final owner = identity;
    if (owner == null) return {};
    final prefs = await SharedPreferences.getInstance();
    if (identity != owner) throw StateError('Account changed. Refresh.');
    final value = prefs.getString('ngo_planning_request_$owner');
    return value == null ? {} : routingObject(jsonDecode(value));
  }

  Future<void> _savePlanning(String owner, Map<String, dynamic> value) async {
    final prefs = await SharedPreferences.getInstance();
    if (identity != owner ||
        !await prefs.setString(
          'ngo_planning_request_$owner',
          jsonEncode(value),
        )) {
      throw StateError(
        'Cannot preserve the planning retry record. No new request should be sent.',
      );
    }
  }

  Future<void> clearFinishedPlanning() async {
    final owner = identity;
    if (owner == null) throw StateError('Sign in as an NGO.');
    final pending = await pendingPlanning();
    if (pending.isNotEmpty &&
        !{
          'rejected',
          'candidate_ready',
          'infeasible',
        }.contains(pending['status'])) {
      throw StateError(
        'The previous outcome is unknown. Reconcile the saved request before discarding it.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    if (identity != owner ||
        !await prefs.setString(
          'ngo_planning_history_${owner}_${pending['request_id']}',
          jsonEncode(pending),
        ) ||
        !await prefs.remove('ngo_planning_request_$owner')) {
      throw StateError('Cannot clear the finished planning context.');
    }
  }

  Future<List<String>> authorize(String candidate, DateTime departure) async {
    final owner = identity;
    if (owner == null) throw StateError('Sign in as an NGO.');
    final prefs = await SharedPreferences.getInstance();
    final iso = departure.toUtc().toIso8601String();
    final key = 'ngo_route_authorize_${owner}_${candidate}_$iso';
    final id = prefs.getString(key) ?? const Uuid().v4();
    if (!await prefs.setString(key, id) || identity != owner) {
      throw StateError('Cannot preserve route authorization retry.');
    }
    final result = routingObject(
      await _call('authorize_my_routing_candidate', {
        'p_request': id,
        'p_candidate': candidate,
        'p_depart_at': iso,
      }),
    );
    final ids = result['route_ids'];
    if (result['candidate_id'] != candidate ||
        ids is! List ||
        ids.isEmpty ||
        ids.any((v) => v is! String)) {
      throw const FormatException(
        'Database did not return authorized route IDs.',
      );
    }
    // Keep the key: a lost response or repeated tap must not issue new bookings.
    return ids.cast<String>();
  }

  Future<void> pickup(
    String routeId,
    String taskId, {
    required bool complete,
    Future<void> Function()? beforeMutation,
  }) async {
    final row = await detail(
      routeId,
    ); // fresh backend confirmation before mutation
    final stops = routingRows(
      row['stops'],
    ).where((s) => s['task_id'] == taskId).toList();
    if (row['authorization_confirmed'] != true ||
        stops.length != 1 ||
        stops.single[complete ? 'can_complete' : 'can_start'] != true) {
      throw StateError(
        complete
            ? 'Pickup completion is blocked. Refresh the claim; lease expiry or reconciliation may require review.'
            : routingDispatchMessage(row['dispatch_block_reason']),
      );
    }
    // Optional local durable execution journal; never replaces protected checks.
    if (beforeMutation != null) await beforeMutation();
    await _call(complete ? 'complete_pickup' : 'start_pickup', {
      'p_claim': stops.single['claim_id'],
      if (complete) 'p_handover_confirmed': true,
    });
  }

  Future<void> deferPickup(
    String routeId,
    String taskId, {
    required String requestId,
    Future<void> Function()? beforeMutation,
  }) async {
    final row = await detail(routeId);
    final stops = routingRows(
      row['stops'],
    ).where((s) => s['task_id'] == taskId);
    if (row['authorization_confirmed'] != true ||
        stops.length != 1 ||
        stops.single['can_defer'] != true) {
      throw StateError('The backend has not authorized deferring this pickup.');
    }
    if (beforeMutation != null) await beforeMutation();
    await _call('defer_my_pickup_for_reconciliation', {
      'p_claim': stops.single['claim_id'],
      'p_request': requestId,
    });
  }

  Future<Map<String, dynamic>> deferredPickupReceipt(String requestId) async {
    final value = routingObject(
      await _call('get_my_deferred_pickup_receipt', {'p_request': requestId}),
    );
    if (value['request_id'] != requestId) {
      throw const FormatException('Deferral receipt request identity changed.');
    }
    return value;
  }

  Future<String?> pendingMixedRouteClosure(String routeId) async {
    final owner = identity;
    if (owner == null) return null;
    final prefs = await SharedPreferences.getInstance();
    if (identity != owner) throw StateError('Sign-in changed.');
    return prefs.getString('ngo_mixed_route_close_${owner}_$routeId');
  }

  Future<void> close(String routeId) async {
    final owner = identity;
    if (owner == null) throw StateError('Sign in before closing the route.');
    final prefs = await SharedPreferences.getInstance();
    final key = 'ngo_mixed_route_close_${owner}_$routeId';
    final saved = prefs.getString(key);
    if (saved != null) {
      final receipt = routingObject(
        await _call('get_my_mixed_route_close_receipt', {'p_request': saved}),
      );
      if (identity != owner) throw StateError('Sign-in changed.');
      if (receipt['found'] == true &&
          receipt['request_id'] == saved &&
          receipt['route_id'] == routeId &&
          receipt['result'] is Map &&
          routingObject(receipt['result'])['request_id'] == saved &&
          routingObject(receipt['result'])['route_status'] == 'ABANDONED') {
        await prefs.remove(key);
        return;
      }
      // The receipt RPC serializes with close_my_resolved_route on this exact
      // request id. Replaying this idempotent request cannot create a second
      // closure or silently replace the original operation.
      if (receipt['found'] != false || receipt['request_id'] != saved) {
        throw StateError('The saved route closure receipt is not confirmed.');
      }
      final row = await detail(routeId);
      if (identity != owner) throw StateError('Sign-in changed.');
      if (row['can_close'] != true ||
          (row['closure_outcome'] != 'ABANDONED' &&
              !{
                'NO_COLLECTION',
                'MIXED_OUTCOME',
              }.contains(row['closure_kind'])) ||
          row['authorization_confirmed'] != true) {
        throw StateError(
          'The saved closure is not currently authorized. Its request remains preserved.',
        );
      }
      final result = routingObject(
        await _call('close_my_resolved_route', {
          'p_route': routeId,
          'p_depot_return_confirmed': true,
          'p_request': saved,
        }),
      );
      if (result['request_id'] != saved ||
          result['route_id'] != routeId ||
          result['route_status'] != 'ABANDONED') {
        throw StateError(
          'The saved route closure result needs reconciliation.',
        );
      }
      await prefs.remove(key);
      return;
    }
    final row = await detail(routeId);
    if (row['can_close'] != true || row['authorization_confirmed'] != true) {
      throw StateError('Route still has unresolved pickups.');
    }
    if (row['closure_outcome'] != 'ABANDONED' &&
        !{'NO_COLLECTION', 'MIXED_OUTCOME'}.contains(row['closure_kind'])) {
      await _call('close_my_collected_route', {
        'p_route': routeId,
        'p_depot_return_confirmed': true,
      });
      return;
    }
    final request = const Uuid().v4();
    if (!await prefs.setString(key, request) || identity != owner) {
      throw StateError(
        'Unable to preserve the closure request. No write sent.',
      );
    }
    final result = routingObject(
      await _call('close_my_resolved_route', {
        'p_route': routeId,
        'p_depot_return_confirmed': true,
        'p_request': request,
      }),
    );
    if (result['request_id'] != request ||
        result['route_id'] != routeId ||
        result['route_status'] != 'ABANDONED') {
      throw StateError('The saved route closure result needs reconciliation.');
    }
    await prefs.remove(key);
  }

  Future<void> cancel(String routeId) async {
    final row = await detail(routeId);
    if (row['can_cancel'] != true || row['authorization_confirmed'] != true) {
      throw StateError('Route cannot be safely cancelled.');
    }
    await _call('cancel_my_unstarted_route', {'p_route': routeId});
  }
}
