import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';
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
        expect(find.textContaining('AUTHORISED'), findsOneWidget);
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
