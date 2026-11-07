// Synthetic test transports only. No Supabase connection or live evidence.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/ngo_fleet_page.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';

Map<String, dynamic> vehicle() => {
  'vehicle_id': 'synthetic-v',
  'ngo_user_id': 'synthetic-ngo',
  'vehicle_version': 4,
  'vehicle_label': 'Synthetic van',
  'payload_capacity_kg': 100,
  'active_flag': true,
  'available_for_planning': true,
  'eligible_for_planning': true,
};
Map<String, dynamic> fleet() => {
  'vehicles': [vehicle()],
  'fleet_outcome': 'AVAILABLE_VEHICLES',
};
Map<String, dynamic> detail({bool authorized = true, bool start = true}) => {
  'contract': 'geolock.ngo-routing.v1',
  'ngo_id': 'synthetic-ngo',
  'route_id': 'synthetic-route',
  'route_status': 'AUTHORISED',
  'authorization_confirmed': authorized,
  'vehicle_id': 'synthetic-v',
  'depot_road_node_id': '101',
  'total_distance_km': 2,
  'total_duration_min': 8,
  'can_close': false,
  'can_cancel': false,
  'stops': [
    {
      'task_id': 'synthetic-task',
      'claim_id': 'synthetic-claim',
      'title': 'Synthetic pickup',
      'stop_order': 1,
      'task_status': 'PLANNED',
      'load_kg': 10,
      'pickup_road_node_id': '102',
      'can_start': start,
      'can_complete': false,
    },
  ],
};
Map<String, dynamic> fields() => {
  'p_label': 'Synthetic van',
  'p_vehicle_type': 'VAN',
  'p_capacity_kg': 100,
  'p_fixed_cost_rm': 10,
  'p_distance_cost_rm_per_km': 1,
  'p_max_route_duration_min': 120,
  'p_available': false,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'completion rechecks authority and sends the exact handover contract',
    () async {
      final calls = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          calls.add(name);
          if (name == 'get_my_authorized_route') {
            return {
              ...detail(start: false),
              'stops': [
                {
                  ...(detail()['stops'] as List).single as Map<String, dynamic>,
                  'task_status': 'DISPATCHED',
                  'can_start': false,
                  'can_complete': true,
                },
              ],
            };
          }
          expect(name, 'complete_pickup');
          expect(params, {
            'p_claim': 'synthetic-claim',
            'p_handover_confirmed': true,
          });
          return null;
        },
      );
      await repo.pickup('synthetic-route', 'synthetic-task', complete: true);
      expect(calls, ['get_my_authorized_route', 'complete_pickup']);
    },
  );

  test(
    'route close and cancellation respect separate fresh backend flags',
    () async {
      for (final close in [false, true]) {
        var allowed = false;
        final calls = <String>[];
        final repo = NgoRoutingRepository(
          identity: () => 'synthetic-ngo',
          rpc: (name, params) async {
            calls.add(name);
            if (name == 'get_my_authorized_route') {
              return {
                ...detail(),
                'can_close': close && allowed,
                'can_cancel': !close && allowed,
              };
            }
            expect(
              name,
              close ? 'close_my_collected_route' : 'cancel_my_unstarted_route',
            );
            expect(params, {
              'p_route': 'synthetic-route',
              if (close) 'p_depot_return_confirmed': true,
            });
            return null;
          },
        );
        await expectLater(
          close
              ? repo.close('synthetic-route')
              : repo.cancel('synthetic-route'),
          throwsStateError,
        );
        expect(calls, ['get_my_authorized_route']);
        allowed = true;
        await (close
            ? repo.close('synthetic-route')
            : repo.cancel('synthetic-route'));
        expect(
          calls.last,
          close ? 'close_my_collected_route' : 'cancel_my_unstarted_route',
        );
      }
    },
  );

  test(
    'uncertain mixed closure retries only the original request after a protected receipt read',
    () async {
      var closeCalls = 0;
      final requestIds = <String>[];
      final calls = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          calls.add(name);
          if (name == 'get_my_authorized_route') {
            return {
              ...detail(),
              'can_close': true,
              'closure_outcome': 'ABANDONED',
            };
          }
          if (name == 'get_my_mixed_route_close_receipt') {
            return {'found': false, 'request_id': params['p_request']};
          }
          expect(name, 'close_my_resolved_route');
          requestIds.add(params['p_request'] as String);
          if (closeCalls++ == 0) {
            throw TimeoutException('response lost after send');
          }
          return {
            'route_id': 'synthetic-route',
            'route_status': 'ABANDONED',
            'request_id': params['p_request'],
          };
        },
      );
      await expectLater(
        repo.close('synthetic-route'),
        throwsA(isA<TimeoutException>()),
      );
      await repo.close('synthetic-route');
      expect(requestIds, hasLength(2));
      expect(requestIds[0], isNotEmpty);
      expect(requestIds[1], requestIds[0]);
      expect(
        calls.where((name) => name == 'get_my_mixed_route_close_receipt'),
        hasLength(1),
      );
    },
  );

  test(
    'committed mixed closure timeout is confirmed from its protected receipt',
    () async {
      var committed = false;
      final requestIds = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          if (name == 'get_my_authorized_route') {
            return {
              ...detail(),
              'can_close': true,
              'closure_outcome': 'ABANDONED',
            };
          }
          if (name == 'get_my_mixed_route_close_receipt') {
            final request = params['p_request'];
            return {
              'found': committed,
              'request_id': request,
              if (committed) 'route_id': 'synthetic-route',
              if (committed)
                'result': {
                  'route_id': 'synthetic-route',
                  'route_status': 'ABANDONED',
                  'request_id': request,
                },
            };
          }
          expect(name, 'close_my_resolved_route');
          requestIds.add(params['p_request'] as String);
          committed = true;
          throw TimeoutException('synthetic committed response loss');
        },
      );
      await expectLater(
        repo.close('synthetic-route'),
        throwsA(isA<TimeoutException>()),
      );
      await repo.close('synthetic-route');
      expect(requestIds, hasLength(1));
    },
  );

  testWidgets(
    'a missing policy disables planning even with vehicles and a worker',
    (tester) async {
      var planningCalls = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async => name == 'list_my_vehicles'
            ? fleet()
            : {
                'contract': 'geolock.ngo-routing.v1',
                'ngo_id': 'synthetic-ngo',
                'authorization_enforced': true,
                'policy_id': null,
                'eligible_tasks': [
                  {'task_id': 'synthetic-task'},
                ],
                'routes': [],
              },
        planner: (_) async {
          planningCalls++;
          return {};
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('routing-policy-unavailable')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('generate-route')))
            .onPressed,
        isNull,
      );
      expect(planningCalls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'route detail explains blocked departure without enabling pickup',
    (tester) async {
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (_, params) async => {
          ...detail(start: false),
          'dispatch_block_reason': 'BEFORE_AUTHORIZED_DEPARTURE',
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRouteDetailPage(
            routeId: 'synthetic-route',
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('authorized departure time'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('start-route')))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'five C1 RPCs use current version, owned identity and stable registration retry',
    () async {
      final calls = <String>[];
      final payloads = <Map<String, dynamic>>[];
      var fail = true;
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          calls.add(name);
          payloads.add(Map.of(params));
          if (name == 'list_my_vehicles') return fleet();
          if (name == 'register_my_vehicle' && fail) {
            fail = false;
            throw Exception('synthetic lost response');
          }
          return vehicle();
        },
      );
      await expectLater(repo.register(fields()), throwsException);
      await repo.register(fields());
      expect(payloads[0]['p_request_id'], payloads[1]['p_request_id']);
      expect(await repo.pendingRegistration(), isEmpty);
      await repo.fleet();
      await repo.updateVehicle(
        vehicle(),
        Map.of(fields())..remove('p_available'),
      );
      await repo.availability(vehicle(), false);
      await repo.deactivate(vehicle());
      expect(calls.toSet(), {
        'register_my_vehicle',
        'list_my_vehicles',
        'update_my_vehicle',
        'set_my_vehicle_availability',
        'deactivate_my_vehicle',
      });
      for (final p in payloads) {
        expect(p.containsKey('p_ngo'), isFalse);
        expect(p.containsKey('ngo_user_id'), isFalse);
      }
      expect(payloads.last['p_expected_version'], 4);
    },
  );

  test('cross-owner vehicle is rejected before RPC', () async {
    var calls = 0;
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (n, p) async {
        calls++;
        return {};
      },
    );
    await expectLater(
      repo.deactivate({...vehicle(), 'ngo_user_id': 'other'}),
      throwsFormatException,
    );
    expect(calls, 0);
  });

  test('late account-switched fleet response is discarded', () async {
    String? owner = 'synthetic-ngo';
    final pending = Completer<Object?>();
    final repo = NgoRoutingRepository(
      identity: () => owner,
      rpc: (n, p) => pending.future,
    );
    final read = repo.fleet();
    owner = 'other';
    pending.complete(fleet());
    await expectLater(read, throwsStateError);
  });

  test('unauthenticated calls never reach RPC', () async {
    var calls = 0;
    final repo = NgoRoutingRepository(
      identity: () => null,
      rpc: (n, p) async {
        calls++;
        return {};
      },
    );
    await expectLater(repo.fleet(), throwsStateError);
    expect(calls, 0);
  });

  test(
    'pickup requires a fresh backend check and never trusts task status alone',
    () async {
      final calls = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (n, p) async {
          calls.add(n);
          return detail(authorized: false);
        },
      );
      await expectLater(
        repo.pickup('synthetic-route', 'synthetic-task', complete: false),
        throwsStateError,
      );
      expect(calls, ['get_my_authorized_route']);
    },
  );

  test(
    'confirmed pickup uses the protected RPC without client NGO IDs',
    () async {
      final calls = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (n, p) async {
          calls.add(n);
          if (n == 'get_my_authorized_route') return detail();
          expect(p, {'p_claim': 'synthetic-claim'});
          return null;
        },
      );
      await repo.pickup('synthetic-route', 'synthetic-task', complete: false);
      expect(calls, ['get_my_authorized_route', 'start_pickup']);
    },
  );

  test('wrong route identity is rejected', () async {
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (n, p) async => {...detail(), 'route_id': 'other'},
    );
    await expectLater(repo.detail('synthetic-route'), throwsFormatException);
  });

  test('authorization retries preserve exact request and departure', () async {
    final requests = <Map<String, dynamic>>[];
    var fail = true;
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (n, p) async {
        requests.add(p);
        if (fail) {
          fail = false;
          throw Exception('synthetic timeout');
        }
        return {
          'candidate_id': 'candidate',
          'route_ids': ['synthetic-route'],
        };
      },
    );
    final depart = DateTime.utc(2026, 10, 24, 12);
    await expectLater(repo.authorize('candidate', depart), throwsException);
    await repo.authorize('candidate', depart);
    expect(requests[0], requests[1]);
  });

  test(
    'planning captures selected vehicles in PostgreSQL before invoking worker',
    () async {
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (n, p) async {
          expect(n, 'begin_my_routing_snapshot');
          expect(p['p_vehicle_ids'], ['synthetic-v']);
          return {'ngo_id': 'synthetic-ngo', 'snapshot_id': 'snapshot'};
        },
        planner: (body) async {
          expect(body, {'request_id': 'request', 'snapshot_id': 'snapshot'});
          return {
            'ngo_id': 'synthetic-ngo',
            'snapshot_id': 'snapshot',
            'kind': 'ADVISORY_CANDIDATE',
            'dispatch_authority_issued': true,
          };
        },
      );
      await expectLater(
        repo.plan(['synthetic-v'], 'request', 'policy'),
        throwsFormatException,
      );
    },
  );

  testWidgets('empty fleet explicitly reports no feasible route', (
    tester,
  ) async {
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (n, p) async => {
        'vehicles': [],
        'fleet_outcome': 'NO_FEASIBLE_PLAN',
      },
    );
    await tester.pumpWidget(MaterialApp(home: NgoFleetPage(repository: repo)));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot invent a vehicle'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'account switch clears the previous NGO fleet even if refresh fails',
    (tester) async {
      String? owner = 'synthetic-ngo';
      final events = StreamController<void>.broadcast();
      final repo = NgoRoutingRepository(
        identity: () => owner,
        identityChanges: events.stream,
        rpc: (n, p) async {
          if (owner == 'synthetic-ngo') {
            return fleet();
          }
          throw StateError('Synthetic new account read failure');
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: NgoFleetPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic van'), findsOneWidget);
      owner = 'other-ngo';
      events.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Synthetic van'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets('fleet form has no default capacity and rejects invalid values', (
    tester,
  ) async {
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (n, p) async => {
        'vehicles': [],
        'fleet_outcome': 'NO_FEASIBLE_PLAN',
      },
    );
    await tester.pumpWidget(MaterialApp(home: NgoFleetPage(repository: repo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Register vehicle'));
    await tester.pumpAndSettle();
    final capacity = find.widgetWithText(TextFormField, 'Capacity (kg)');
    expect(tester.widget<TextFormField>(capacity).controller!.text, isEmpty);
    await tester.enterText(capacity, '-1');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a positive number.'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'missing routing overview never treats claim cards as routing eligibility',
    (tester) async {
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (n, p) async {
          if (n == 'list_my_vehicles') return fleet();
          if (n == 'get_my_claim_cards_v2') {
            return [
              {
                'claim_id': 'claimed',
                'title': 'Claimed donation',
                'task_status': 'CONFIRMED',
              },
            ];
          }
          throw const PostgrestException(
            message: 'not deployed',
            code: 'PGRST202',
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Claimed donation'), findsNothing);
      expect(
        find.text('Routing eligibility could not be confirmed'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('generate-route')))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'route actions disabled without backend authorization even if flags claim ready',
    (tester) async {
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (n, p) async => detail(authorized: false),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRouteDetailPage(
            routeId: 'synthetic-route',
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('start-route')))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('real engine-shaped comparison stays advisory with ordered stops', (
    tester,
  ) async {
    final candidate = {
      'ngo_id': 'synthetic-ngo',
      'snapshot_id': 'snapshot',
      'kind': 'ADVISORY_CANDIDATE',
      'dispatch_authority_issued': false,
      'methods': [
        for (final method in [
          'fcfs',
          'nearest_neighbour',
          'distance_only',
          'proposed',
        ])
          {
            'method': method,
            'validation': {
              'valid': true,
              'metrics': {
                'total_travel_km': 2,
                'total_route_minutes': 3,
                'served_count': 1,
                'unserved_count': 0,
              },
            },
            'plan': {
              'method': method,
              'dispatch_authority_issued': false,
              'routes': [
                {
                  'vehicle_id': 'synthetic-v',
                  'return_us': 180000000,
                  'end_node_id': '101',
                  'stops': [
                    {
                      'task_id': 'synthetic-task',
                      'road_node_id': '102',
                      'cumulative_load_kg': 10,
                    },
                  ],
                },
              ],
            },
          },
      ],
    };
    SharedPreferences.setMockInitialValues({
      'ngo_planning_request_synthetic-ngo':
          '{"status":"candidate_ready","snapshot_id":"snapshot","request_id":"original"}',
    });
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (name, params) async {
        if (name == 'list_my_vehicles') {
          return fleet();
        }
        if (name == 'begin_my_routing_snapshot') {
          return {'ngo_id': 'synthetic-ngo', 'snapshot_id': 'snapshot'};
        }
        return {
          'ngo_id': 'synthetic-ngo',
          'contract': 'geolock.ngo-routing.v1',
          'authorization_enforced': true,
          'policy_id': 'policy',
          'eligible_tasks': [
            {'task_id': 'synthetic-task', 'load_kg': 10},
          ],
          'routes': [],
        };
      },
      planner: (_) async => throw StateError('Saved result must not plan'),
      savedPlanner: (_) async => {
        ...candidate,
        'saved_result_display_only': true,
      },
    );
    await tester.pumpWidget(MaterialApp(home: NgoRoutesPage(repository: repo)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Route support'));
    await tester.tap(find.byTooltip('Route support'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.text('View saved Proposed result (read only)'),
    );
    await tester.tap(find.text('View saved Proposed result (read only)'));
    await tester.pumpAndSettle();
    expect(
      find.text('Advisory candidate — NOT database-authorized'),
      findsOneWidget,
    );
    expect(find.textContaining('distance_only'), findsNothing);
    expect(find.textContaining('nearest_neighbour'), findsNothing);
    expect(find.textContaining('fcfs'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Pickup synthetic-task'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Pickup synthetic-task'), findsOneWidget);
    expect(find.text('Request database authorization'), findsNothing);
    expect(find.text('Choose departure time'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('authorization display expires and disables pickup actions', (
    tester,
  ) async {
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (n, p) async => detail(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NgoRouteDetailPage(routeId: 'synthetic-route', repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('start-route')))
          .onPressed,
      isNotNull,
    );
    await tester.pump(const Duration(seconds: 31));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('start-route')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'revoked authorization between display and click prevents dispatch',
    (tester) async {
      var reads = 0, writes = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (n, p) async {
          if (n == 'get_my_authorized_route') {
            return detail(authorized: ++reads == 1);
          }
          if (n == 'get_my_claim_cards_v2') return [];
          writes++;
          return null;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRouteDetailPage(
            routeId: 'synthetic-route',
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-route')));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(find.textContaining('Pickup is unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
