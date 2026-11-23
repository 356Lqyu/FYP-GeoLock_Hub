import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';
import 'package:geolock_hub_app/routing/routing_diagnostics_page.dart';
import 'automatic_route_operation_test.dart' as fixtures;

Map<String, dynamic> overview({List<Map<String, dynamic>> routes = const []}) =>
    {
      'contract': 'geolock.ngo-routing.v1',
      'ngo_id': 'ngo',
      'policy_id': 'policy',
      'authorization_enforced': true,
      'eligible_tasks': [
        {
          'task_id': 'fresh',
          'claim_id': 'fresh-claim',
          'title': 'Fresh donation',
          'load_kg': 12,
        },
        {
          'task_id': 'race',
          'claim_id': 'race-claim',
          'title': 'Expired during read',
          'load_kg': 15,
        },
      ],
      'routes': routes,
    };

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final terminal in [
    'CONFIRMED',
    'INFEASIBLE',
    'REJECTED',
    'UNCONFIRMED',
  ]) {
    testWidgets('Route Support reports $terminal without routing writes', (
      tester,
    ) async {
      final operation = <String, dynamic>{
        'request_id': 'request',
        'snapshot_id': 'snapshot',
        'phase': 'combined',
        'status': 'authorization_unknown',
      };
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': jsonEncode(operation),
      });
      final reads = <String>[];
      var outcomeReads = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          reads.add(name);
          if (name == 'get_my_authorized_route') return fixtures.detail();
          fail('Unexpected RPC: $name');
        },
        authorizationReader: (body) async {
          outcomeReads++;
          expect(body, {'request_id': 'request', 'snapshot_id': 'snapshot'});
          return terminal == 'CONFIRMED'
              ? fixtures.receipt()
              : {
                  'kind': 'AUTHORIZATION_UNCONFIRMED',
                  'request_id': 'request',
                  'snapshot_id': 'snapshot',
                  'ngo_id': 'ngo',
                  'operation_terminal':
                      terminal == 'REJECTED' && outcomeReads > 1
                      ? null
                      : terminal,
                };
        },
        combinedPlanner: (_) async => fail('Support cannot run the planner'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RoutingDiagnosticsPage(
            repository: repo,
            operation: operation,
            planning: const {},
          ),
        ),
      );
      expect(find.text('Finish previous attempt'), findsNothing);
      await tester.tap(find.text('Check authorization outcome (read only)'));
      await tester.pumpAndSettle();
      final expected = switch (terminal) {
        'CONFIRMED' => 'Route authorization confirmed.',
        'INFEASIBLE' => 'No feasible route was found. No route was authorized.',
        'REJECTED' => 'The saved routing request was rejected.',
        _ => 'No committed receipt is visible',
      };
      expect(find.textContaining(expected), findsOneWidget);
      expect(
        find.text('Finish previous attempt'),
        {'INFEASIBLE', 'REJECTED'}.contains(terminal)
            ? findsOneWidget
            : findsNothing,
      );
      expect((await repo.routeOperation())['request_id'], 'request');
      if (terminal == 'REJECTED') {
        await tester.tap(find.text('Finish previous attempt'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not finish this attempt'),
          findsOneWidget,
        );
        expect(find.text('Finish previous attempt'), findsNothing);
        expect(outcomeReads, 2);
        expect((await repo.routeOperation())['request_id'], 'request');
      }
      expect(reads, terminal == 'CONFIRMED' ? ['get_my_authorized_route'] : []);
    });
  }

  testWidgets(
    'finishing refreshes eligibility and only an explicit tap creates a new request',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': jsonEncode({
          'request_id': 'old-request',
          'snapshot_id': 'old-snapshot',
          'phase': 'combined',
          'status': 'infeasible',
          'vehicle_ids': ['old-vehicle'],
        }),
      });
      var fleetReads = 0;
      var outcomeReads = 0;
      final snapshotRequests = <String>[];
      final plannedRequests = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, params) async {
          if (name == 'list_my_vehicles') {
            fleetReads++;
            return {
              'vehicles': [
                {
                  'ngo_id': 'ngo',
                  'vehicle_id': 'truck',
                  'vehicle_label': 'Truck',
                  'payload_capacity_kg': 200,
                  'eligible_for_planning': true,
                },
                {
                  'ngo_id': 'ngo',
                  'vehicle_id': 'reserved',
                  'vehicle_label': 'Reserved',
                  'payload_capacity_kg': 50,
                  'eligible_for_planning': false,
                },
              ],
            };
          }
          if (name == 'get_my_routing_overview') {
            return {
              ...overview(),
              'eligible_tasks': [
                {'claim_id': 'cookies', 'title': 'Cookies', 'load_kg': 20},
              ],
            };
          }
          if (name == 'get_my_claim_cards_v2') return [];
          if (name == 'begin_my_routing_snapshot') {
            snapshotRequests.add(params['p_request'] as String);
            expect(params['p_vehicle_ids'], ['truck']);
            return {'ngo_id': 'ngo', 'snapshot_id': 'new-snapshot'};
          }
          fail('Unexpected RPC: $name');
        },
        authorizationReader: (body) async {
          outcomeReads++;
          expect(body, {
            'request_id': 'old-request',
            'snapshot_id': 'old-snapshot',
          });
          return {
            'kind': 'AUTHORIZATION_UNCONFIRMED',
            'ngo_id': 'ngo',
            ...body,
            'operation_terminal': 'INFEASIBLE',
          };
        },
        authorizationCapabilities: (_) async => {
          'contract': 'geolock.routing-auto-now.v1',
          'ngo_id': 'ngo',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        combinedPlanner: (_) async =>
            fail('Option C: Generate Route never calls /v1/plan-and-authorize'),
        // Option C: Generate Route uses the advisory /v1/plan path only.
        planner: (body) async {
          plannedRequests.add(body['request_id'] as String);
          return {
            'kind': 'ADVISORY_CANDIDATE',
            'outcome': 'INFEASIBLE',
            'dispatch_authority_issued': false,
            'ngo_id': 'ngo',
            'snapshot_id': 'new-snapshot',
            'methods': [
              for (final m in ['fcfs', 'nearest_neighbour', 'proposed'])
                {
                  'method': m,
                  'validation': {'valid': false, 'metrics': {}},
                  'plan': {
                    'method': m,
                    'dispatch_authority_issued': false,
                    'routes': [],
                  },
                },
            ],
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      final generate = find.byKey(const Key('generate-route'));
      expect(tester.widget<FilledButton>(generate).onPressed, isNull);
      await tester.tap(find.byTooltip('Route support'));
      await tester.pumpAndSettle();
      expect(find.text('Finish previous attempt'), findsNothing);
      await tester.tap(find.text('Check authorization outcome (read only)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finish previous attempt'));
      await tester.pumpAndSettle();
      expect(
        outcomeReads,
        3,
      ); // Reload, explicit lookup, and fresh finish lookup.
      expect(fleetReads, 2);
      expect(snapshotRequests, isEmpty);
      expect(plannedRequests, isEmpty);
      expect(await repo.routeOperation(), isEmpty);
      expect(tester.widget<FilledButton>(generate).onPressed, isNull);
      await tester.tap(find.text('Reserved · 50 kg'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(generate).onPressed, isNull);
      await tester.tap(find.text('Truck · 200 kg'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
      await tester.tap(generate);
      await tester.pumpAndSettle();
      expect(snapshotRequests.single, isNot('old-request'));
      expect(plannedRequests, snapshotRequests);
      // Option C: the advisory result is kept in the planning record; no
      // combined route operation is created.
      expect(await repo.routeOperation(), isEmpty);
      expect((await repo.pendingPlanning())['status'], 'infeasible');
    },
  );

  for (final saved in [false, true]) {
    testWidgets(
      'capacity guidance preserves original Generate gate; saved=$saved',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (saved) {
          SharedPreferences.setMockInitialValues({
            'ngo_route_operation_ngo': jsonEncode({
              'request_id': 'existing',
              'phase': 'combined',
              'status': 'infeasible',
            }),
          });
        }
        final repo = NgoRoutingRepository(
          identity: () => 'ngo',
          rpc: (name, _) async => switch (name) {
            'list_my_vehicles' => {
              'vehicles': [
                {
                  'ngo_id': 'ngo',
                  'vehicle_id': 'truck',
                  'vehicle_label': 'Truck',
                  'eligible_for_planning': true,
                  'payload_capacity_kg': 200,
                },
              ],
            },
            'get_my_routing_overview' => {
              ...overview(),
              'eligible_tasks': [
                {'claim_id': 'rice', 'title': 'Rice', 'load_kg': 1000},
              ],
            },
            'get_my_claim_cards_v2' => [],
            _ => fail('Unexpected RPC: $name'),
          },
          authorizationReader: (_) async => fail('No receipt read expected'),
          combinedPlanner: (_) async => fail('No planner call expected'),
          planner: (_) async => fail('No planner call expected'),
          authorizationCapabilities: (_) async =>
              fail('No capability call expected'),
        );
        await tester.pumpWidget(
          MaterialApp(home: NgoRoutesPage(repository: repo)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Truck · 200 kg'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('A pickup cannot be split across vehicles'),
          findsOneWidget,
        );
        final button = tester.widget<FilledButton>(
          find.byKey(const Key('generate-route')),
        );
        expect(button.onPressed, saved ? isNull : isNotNull);
        if (saved) {
          expect(
            find.textContaining(
              'No feasible route was found for your previous selection',
            ),
            findsNothing,
          );
          expect(
            find.text('No feasible route was found. No route was authorized.'),
            findsOneWidget,
          );
          expect(find.text('Get help'), findsOneWidget);
        }
      },
    );
  }

  testWidgets(
    'main list contains only backend-admitted, server-unexpired claims',
    (tester) async {
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'list_my_vehicles') return {'vehicles': []};
          if (name == 'get_my_routing_overview') return overview();
          if (name == 'get_my_claim_cards_v2') {
            return [
              {
                'claim_id': 'fresh-claim',
                'title': 'Fresh donation',
                'server_now': '2026-10-28T00:00:00Z',
                'lease_expires_at': '2026-10-28T05:00:00Z',
              },
              {
                'claim_id': 'race-claim',
                'title': 'Expired during read',
                'lease_is_expired': true,
              },
              {
                'claim_id': 'old-claim',
                'title': 'Historical expired claim',
                'lease_recovery_pending': true,
              },
            ];
          }
          throw StateError('No writes');
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fresh donation'), findsOneWidget);
      expect(find.text('Expired during read'), findsNothing);
      expect(find.text('Historical expired claim'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'known preflight interruption requires explicit dismissal and preserves history',
    (tester) async {
      final record = jsonEncode({
        'request_id': 'stable',
        'status': 'blocked',
        'phase': 'preflight',
        'intent': 'GENERATE_AND_AUTHORIZE',
      });
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': record,
      });
      var writes = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'list_my_vehicles') return {'vehicles': []};
          if (name == 'get_my_routing_overview') return overview();
          if (name == 'get_my_claim_cards_v2') return [];
          writes++;
          throw StateError('No writes');
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      expect((await repo.routeOperation())['request_id'], 'stable');
      expect(
        find.text('Route setup stopped before generation.'),
        findsOneWidget,
      );
      final dismiss = find.text('Dismiss interrupted setup');
      await tester.ensureVisible(dismiss);
      await tester.tap(dismiss);
      await tester.pumpAndSettle();
      expect((await repo.routeOperation())['request_id'], 'stable');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(await repo.routeOperation(), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_history_ngo_stable',
        ),
        record,
      );
      expect(writes, 0);
      expect(find.text('Dismiss interrupted setup'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'only preflight evidence, not receipt absence, permits local dismissal',
    () {
      final base = <String, dynamic>{
        'status': 'blocked',
        'phase': 'preflight',
        'intent': 'GENERATE_AND_AUTHORIZE',
      };
      expect(NgoRoutingRepository.isFinishedPreflight(base), isTrue);
      expect(
        NgoRoutingRepository.isFinishedPreflight({
          ...base,
          'phase': 'snapshot',
        }),
        isFalse,
      );
      expect(
        NgoRoutingRepository.isFinishedPreflight({
          ...base,
          'status': 'authorization_unknown',
        }),
        isFalse,
      );
      expect(
        NgoRoutingRepository.isFinishedPreflight({
          ...base,
          'snapshot_id': 'snapshot',
        }),
        isFalse,
      );
      expect(
        NgoRoutingRepository.isFinishedPreflight({
          ...base,
          'authorization': {},
        }),
        isFalse,
      );
    },
  );

  test(
    'reopening reconciles only reads and preserves an unconfirmed request',
    () async {
      final record = jsonEncode({
        'request_id': 'stable',
        'snapshot_id': 'snapshot',
        'status': 'authorization_unknown',
        'phase': 'combined',
        'intent': 'GENERATE_AND_AUTHORIZE',
      });
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': record,
      });
      var reads = 0, writes = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (_, _) async {
          writes++;
          return {};
        },
        combinedPlanner: (_) async {
          writes++;
          return {};
        },
        authorizationCapabilities: (_) async {
          writes++;
          return {};
        },
        authorizationReader: (_) async {
          reads++;
          return {
            'ngo_id': 'ngo',
            'kind': 'AUTHORIZATION_UNCONFIRMED',
            'snapshot_id': 'snapshot',
            'request_id': 'stable',
          };
        },
      );
      await repo.restoreRouteOperation();
      await repo.restoreRouteOperation();
      expect(reads, 2);
      expect(writes, 0);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_ngo',
        ),
        record,
      );
    },
  );

  test(
    'committed route is restored across repository recreation without authorization',
    () async {
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': jsonEncode({
          'request_id': 'request',
          'snapshot_id': 'snapshot',
          'status': 'authorization_unknown',
          'phase': 'combined',
          'intent': 'GENERATE_AND_AUTHORIZE',
        }),
      });
      var writes = 0;
      NgoRoutingRepository make() => NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'get_my_authorized_route') return fixtures.detail();
          writes++;
          return {};
        },
        combinedPlanner: (_) async {
          writes++;
          return {};
        },
        authorizationCapabilities: (_) async {
          writes++;
          return {};
        },
        authorizationReader: (_) async => fixtures.receipt(),
      );
      expect(await make().restoreRouteOperation(), isEmpty);
      expect(writes, 0);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_history_ngo_request',
        ),
        isNotNull,
      );
    },
  );

  testWidgets(
    'database routes reload after navigation with no local operation',
    (tester) async {
      var writes = 0, reads = 0;
      NgoRoutingRepository make() => NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'get_my_authorized_route') return fixtures.detail();
          if (name == 'list_my_vehicles') return {'vehicles': []};
          if (name == 'get_my_claim_cards_v2') return [];
          if (name == 'get_my_routing_overview') {
            reads++;
            return overview(
              routes: [
                {
                  'route_id': 'route',
                  'route_status': 'AUTHORISED',
                  'vehicle_id': 'vehicle',
                  'total_distance_km': 3,
                  'total_duration_min': 12,
                },
              ],
            );
          }
          writes++;
          return {};
        },
      );
      for (var i = 0; i < 2; i++) {
        await tester.pumpWidget(
          MaterialApp(home: NgoRoutesPage(repository: make())),
        );
        await tester.pumpAndSettle();
        expect(find.widgetWithText(Chip, 'Authorised'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
      expect(reads, 2);
      expect(writes, 0);
    },
  );

  test(
    'expired protected Start response blocks pickup without a second authorization',
    () async {
      var writes = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'get_my_authorized_route') {
            return {
              ...fixtures.detail(),
              'dispatch_block_reason': 'DISPATCH_WINDOW_OR_LEASE_EXPIRED',
              'stops': [
                {...fixtures.detail()['stops'][0], 'can_start': false},
              ],
            };
          }
          writes++;
          return {};
        },
      );
      await expectLater(
        repo.pickup('route', 'task', complete: false),
        throwsStateError,
      );
      expect(writes, 0);
    },
  );

  test(
    'unknown response performs one read-only reconciliation and never retries writes',
    () async {
      var writes = 0, reads = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'begin_my_routing_snapshot') {
            writes++;
            return {'ngo_id': 'ngo', 'snapshot_id': 'snapshot'};
          }
          throw StateError('No other write');
        },
        authorizationCapabilities: (_) async => {
          'ngo_id': 'ngo',
          'contract': 'geolock.routing-auto-now.v1',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        combinedPlanner: (_) async {
          writes++;
          throw RoutingRequestFailure(
            'lost response',
            code: 'PLANNER_TIMEOUT',
            phase: 'combined_route',
            outcomeUnknown: true,
          );
        },
        authorizationReader: (_) async {
          reads++;
          return {
            'ngo_id': 'ngo',
            'kind': 'AUTHORIZATION_UNCONFIRMED',
            'snapshot_id': 'snapshot',
            'request_id': 'request',
          };
        },
      );
      await expectLater(
        repo.generateAndAuthorize(['vehicle'], 'request', 'policy'),
        throwsStateError,
      );
      expect(writes, 2);
      expect(reads, 1);
      final op = await repo.routeOperation();
      expect(op['request_id'], 'request');
      expect(op['failure_code'], 'PLANNER_TIMEOUT');
      expect(op['failure_stage'], 'combined_route');
    },
  );
}
