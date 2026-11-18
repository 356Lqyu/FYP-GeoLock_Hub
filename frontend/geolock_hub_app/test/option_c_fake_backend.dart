// Synthetic offline backend for the Option C Generate Route → Start Route
// contract. It mirrors the state machine verified by the local PostgreSQL
// fixture tests (authorize_and_start_my_route, receipts, candidate status,
// start_pickup / complete_pickup). No Supabase connection, no DEV evidence.
// Not a *_test.dart file: shared by option_c_start_route_test.dart and
// automatic_route_operation_test.dart.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';

const ngo = 'ngo';

Map<String, dynamic> methodPlan(String method) => {
  'method': method,
  'validation': {
    'valid': true,
    'metrics': {
      'total_travel_km': 9,
      'total_route_minutes': 40,
      'served_pickup_task_count': 2,
    },
  },
  'plan': {
    'method': method,
    'status': 'COMPLETE',
    'optimization_status': 'OPTIMAL',
    'dispatch_authority_issued': false,
    'unserved_tasks': [],
    'unserved_reasons': [],
    'routes': [
      {
        'vehicle_id': 'van',
        'start_node_id': '100',
        'end_node_id': '100',
        'departure_us': 0,
        'return_us': 2400000000,
        'stops': [
          {'task_id': 't0', 'road_node_id': '101', 'cumulative_load_kg': 12},
          {'task_id': 't1', 'road_node_id': '102', 'cumulative_load_kg': 25},
        ],
      },
    ],
  },
};

/// Fake backend with the same state machine as the SQL wrapper.
class Backend {
  final calls = <String>[];
  final states = ['CONFIRMED', 'CONFIRMED'];
  final requests = <String, Map<String, dynamic>>{};
  String? routeId;
  bool closed = false;
  bool expired = false, multiRoute = false;
  int validityMinutes = 60;
  // Phase 2: a claim lease that ends the start window before the 60 minutes.
  Duration? leaseLimit;
  // Fault injection
  bool loseStartResponse = false; // commits, then the response is lost
  int failReceiptReads = 0; // receipt lookups that time out (uncertain outcome)
  bool timeoutBeforeCommit = false; // fails, nothing committed
  String? rejectStartWith; // P0001 rejection, nothing committed
  Completer<void>? startGate;
  int planCalls = 0;
  final startedClaims = <String>[];

  Map<String, dynamic> status(String candidate) {
    final now = DateTime.utc(2026, 11, 18, 9, 10);
    final cutoff = DateTime.utc(2026, 11, 18, 9, 0);
    final until = cutoff.add(Duration(minutes: validityMinutes));
    final leaseUntil = leaseLimit == null ? null : cutoff.add(leaseLimit!);
    final effective = leaseUntil != null && leaseUntil.isBefore(until)
        ? leaseUntil
        : until;
    final effectiveExpired =
        expired || (leaseUntil != null && !now.isBefore(leaseUntil));
    return {
      'effective_deadline': effective.toIso8601String(),
      'deadline_reason': effective == until ? 'VALIDITY_WINDOW' : 'LEASE',
      'lease_policy': 'PER_TASK_SERVICE_COMPLETION',
      'contract': 'geolock.routing-candidate-status.v1',
      'ngo_id': ngo,
      'candidate_id': candidate,
      'snapshot_id': 'snapshot',
      'attested': true,
      'route_count': multiRoute ? 2 : 1,
      'single_route': !multiRoute,
      'server_now': (expired ? until.add(const Duration(minutes: 1)) : now)
          .toIso8601String(),
      'snapshot_cutoff': cutoff.toIso8601String(),
      'valid_until': until.toIso8601String(),
      'validity_minutes': validityMinutes,
      'expired': effectiveExpired,
      'started_route_id': routeId,
      'startable': !effectiveExpired && !multiRoute && routeId == null,
    };
  }

  Map<String, dynamic> detail() {
    final current = states.indexWhere((s) => s == 'DISPATCHED');
    final next = current >= 0 ? current : states.indexWhere((s) => s == 'PLANNED');
    return {
      'contract': 'geolock.ngo-routing.v1',
      'ngo_id': ngo,
      'route_id': routeId,
      'route_status': closed
          ? 'COMPLETED'
          : states.contains('DISPATCHED') || states.contains('COLLECTED')
          ? 'IN_PROGRESS'
          : 'AUTHORISED',
      'authorization_confirmed': true,
      'vehicle_label': 'Van',
      'total_distance_km': 9,
      'total_duration_min': 40,
      'total_load_kg': 25,
      'pickup_count': 2,
      'departure_at': '2026-11-18T01:10:00Z',
      'actual_started_at': states.every((s) => s == 'PLANNED' || s == 'CONFIRMED')
          ? null
          : '2026-11-18T01:10:00Z',
      'depot': {'latitude': 3.2, 'longitude': 101.6},
      'next_executable_task_id': next < 0 ? null : 't$next',
      'can_close': !closed && states.every((s) => s == 'COLLECTED'),
      'can_cancel': false,
      'vehicle_id': 'van',
      'stops': [
        for (var i = 0; i < 2; i++)
          {
            'task_id': 't$i',
            'claim_id': 'c$i',
            'title': 'Donation $i',
            'load_kg': 12,
            'pickup_latitude': 3.21,
            'pickup_longitude': 101.61,
            'planned_arrival': '2026-11-18T01:20:00Z',
            'stop_order': i + 1,
            'task_status': states[i],
            'can_start':
                !states.contains('DISPATCHED') &&
                next == i &&
                states[i] == 'PLANNED',
            'can_complete': states[i] == 'DISPATCHED',
          },
      ],
    };
  }

  Future<Object?> rpc(String name, Map<String, dynamic> p) async {
    calls.add(name);
    switch (name) {
      case 'list_my_vehicles':
        return {
          'fleet_outcome': 'AVAILABLE_VEHICLES',
          'vehicles': [
            {
              'vehicle_id': 'van',
              'ngo_user_id': ngo,
              'vehicle_label': 'Van',
              'payload_capacity_kg': 100,
              'active_flag': true,
              'available_for_planning': routeId == null,
              'eligible_for_planning': routeId == null,
            },
          ],
        };
      case 'get_my_routing_overview':
        return {
          'contract': 'geolock.ngo-routing.v1',
          'ngo_id': ngo,
          'policy_id': 'policy',
          'authorization_enforced': true,
          'eligible_tasks': [
            if (routeId == null) ...[
              {'task_id': 't0', 'claim_id': 'c0', 'title': 'Rice', 'load_kg': 12},
              {'task_id': 't1', 'claim_id': 'c1', 'title': 'Oil', 'load_kg': 13},
            ],
          ],
          'routes': [
            if (routeId != null)
              {'route_id': routeId, 'route_status': detail()['route_status']},
          ],
        };
      case 'get_my_claim_cards_v2':
        return [];
      case 'begin_my_routing_snapshot':
        return {'ngo_id': ngo, 'snapshot_id': 'snapshot'};
      case 'get_my_route_candidate_status':
        return status(p['p_candidate'] as String);
      case 'get_my_route_start_receipt':
        if (failReceiptReads > 0) {
          failReceiptReads--;
          throw TimeoutException('synthetic receipt read timeout');
        }
        final found = requests[p['p_request']];
        return {
          'contract': 'geolock.routing-authorize-start.v1',
          'ngo_id': ngo,
          'request_id': p['p_request'],
          'outcome': found == null ? 'NOT_FOUND' : 'FOUND',
          'result': ?found,
        };
      case 'authorize_and_start_my_route':
        final request = p['p_request'] as String;
        final prior = requests[request];
        if (prior != null) {
          if (prior['candidate_id'] != p['p_candidate']) {
            throw const PostgrestException(
              message: 'REQUEST_CONFLICT',
              code: 'P0001',
            );
          }
          return {...prior, 'replayed': true};
        }
        if (startGate != null) await startGate!.future;
        if (timeoutBeforeCommit) {
          timeoutBeforeCommit = false;
          throw TimeoutException('synthetic timeout before commit');
        }
        if (rejectStartWith != null) {
          throw PostgrestException(message: rejectStartWith!, code: 'P0001');
        }
        if (expired) {
          throw const PostgrestException(
            message: 'CANDIDATE_EXPIRED',
            code: 'P0001',
          );
        }
        if (routeId != null) {
          throw const PostgrestException(
            message: 'PLAN_STALE_VEHICLE',
            code: 'P0001',
          );
        }
        routeId = 'route';
        states[0] = 'DISPATCHED';
        states[1] = 'PLANNED';
        final receipt = {
          'contract': 'geolock.routing-authorize-start.v1',
          'ngo_id': ngo,
          'request_id': request,
          'candidate_id': p['p_candidate'],
          'snapshot_id': 'snapshot',
          'route_id': 'route',
          'route_ids': ['route'],
          'route_status': 'IN_PROGRESS',
          'departure_mode': 'AUTO_NOW',
          'started_task_id': 't0',
          'started_claim_id': 'c0',
          'valid_until': '2026-11-18T10:00:00Z',
          'replayed': false,
        };
        requests[request] = receipt;
        if (loseStartResponse) {
          loseStartResponse = false;
          throw TimeoutException('synthetic lost response after commit');
        }
        return receipt;
      case 'get_my_authorized_route':
        return detail();
      case 'start_pickup':
        final si = int.parse((p['p_claim'] as String).substring(1));
        startedClaims.add(p['p_claim'] as String);
        if (states[si] != 'PLANNED' || states.contains('DISPATCHED')) {
          throw const PostgrestException(
            message: 'PREVIOUS_PICKUP_UNRESOLVED',
            code: 'P0001',
          );
        }
        states[si] = 'DISPATCHED';
        return null;
      case 'complete_pickup':
        final ci = int.parse((p['p_claim'] as String).substring(1));
        expect(states[ci], 'DISPATCHED');
        states[ci] = 'COLLECTED';
        return null;
      case 'close_my_collected_route':
        expect(states, everyElement('COLLECTED'));
        closed = true;
        return null;
      case 'authorize_my_routing_candidate':
        fail('The new flow must never call the legacy authorize RPC.');
    }
    // Unrelated reads from the detail page (e.g. checkpoints) are not part of
    // this contract; reject them as a backend error the page already handles.
    throw PostgrestException(message: 'FAKE_UNSUPPORTED_$name', code: 'P0001');
  }

  Future<Object?> plan(Map<String, dynamic> body) async {
    planCalls++;
    return {
      'kind': 'ADVISORY_CANDIDATE',
      'ngo_id': ngo,
      'request_id': body['request_id'],
      'snapshot_id': body['snapshot_id'],
      'candidate_id': 'candidate',
      'validation_status': 'ATTESTED',
      'dispatch_authority_issued': false,
      'outcome': 'CANDIDATE_READY',
      'methods': [
        for (final m in ['fcfs', 'nearest_neighbour', 'proposed']) methodPlan(m),
      ],
    };
  }

  NgoRoutingRepository repo() => NgoRoutingRepository(
    identity: () => ngo,
    rpc: rpc,
    planner: plan,
    combinedPlanner: (_) async =>
        fail('The new flow must never call /v1/plan-and-authorize.'),
    authorizationReader: (_) async => fail('No combined receipt read expected'),
    authorizationCapabilities: (_) async =>
        fail('No combined capability read expected'),
  );
}

