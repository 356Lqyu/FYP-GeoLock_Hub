// Synthetic protected-read responses only; no DEV connection or writes.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/route_card_view.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'route_details_presentation_test.dart' as sample;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'pickup lifecycle refreshes detail and list after depot closure',
    (tester) async {
      // Synthetic transport only. This verifies UI wiring, not a DEV handover.
      var stage = 0, overviewReads = 0;
      final writes = <String>[];
      Map<String, dynamic> current() => {
        ...sample.fixture(start: false),
        'route_status': stage == 0
            ? 'AUTHORISED'
            : stage == 3
            ? 'COMPLETED'
            : 'IN_PROGRESS',
        'authorization_confirmed': stage < 3,
        'can_close': stage == 2,
        'pickup_count': 1,
        'total_load_kg': 15,
        'stops': [
          {
            ...(sample.fixture()['stops'] as List).first
                as Map<String, dynamic>,
            'task_status': stage == 0
                ? 'PLANNED'
                : stage == 1
                ? 'DISPATCHED'
                : 'COLLECTED',
            'can_start': stage == 0,
            'can_complete': stage == 1,
          },
        ],
      };
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          switch (name) {
            case 'get_my_routing_overview':
              overviewReads++;
              return {
                'contract': 'geolock.ngo-routing.v1',
                'ngo_id': 'synthetic-ngo',
                'eligible_tasks': [],
                'routes': [current()],
                'policy_id': 'policy',
                'authorization_enforced': true,
              };
            case 'list_my_vehicles':
              return {'vehicles': [], 'fleet_outcome': 'NO_FEASIBLE_PLAN'};
            case 'get_my_claim_cards_v2':
              // Direct pickup UI now requires fresh lease evidence as well as
              // route authority. Keep this lifecycle fixture executable.
              return sample.activeClaimCards(current());
            case 'get_my_authorized_route':
              expect(params, {'p_route': 'synthetic-route'});
              return current();
            case 'start_pickup':
              expect(stage, 0);
              expect(params, {'p_claim': 'claim-0'});
              stage = 1;
            case 'complete_pickup':
              expect(stage, 1);
              expect(params, {
                'p_claim': 'claim-0',
                'p_handover_confirmed': true,
              });
              stage = 2;
            case 'close_my_collected_route':
              expect(stage, 2);
              expect(params, {
                'p_route': 'synthetic-route',
                'p_depot_return_confirmed': true,
              });
              stage = 3;
            default:
              fail('Unexpected RPC: $name');
          }
          writes.add(name);
          return null;
        },
      );
      tester.view.physicalSize = const Size(1200, 2800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRoutesPage(
            repository: repo,
            mapBuilder: (_) => const SizedBox(height: 60),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byType(PickupRouteCard);
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.ensureVisible(find.byKey(const Key('start-route')));
      await tester.tap(find.byKey(const Key('start-route')));
      await tester.pumpAndSettle();
      expect(stage, 1);
      expect(find.byKey(const Key('start-route')), findsNothing);
      await tester.tap(find.text('Complete pickup'));
      await tester.pumpAndSettle();
      expect(stage, 1); // Confirmation is required before mutation.
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(stage, 2);
      final close = find.text('Confirm depot return and close route');
      await tester.ensureVisible(close);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(stage, 2);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(
        find.text('Route completed. No further pickup actions.'),
        findsOneWidget,
      );
      expect(writes, [
        'start_pickup',
        'complete_pickup',
        'close_my_collected_route',
      ]);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(overviewReads, 2);
      expect(find.text('V2 · COMPLETED'), findsOneWidget);
      expect(find.textContaining('Route completed'), findsOneWidget);
      expect(writes.length, 3); // Returning to the list performs reads only.
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('bounded detail reads preserve failures and deduplicate IDs', () async {
    var active = 0, peak = 0, calls = 0;
    final result = await loadRouteCardDetails(
      [
        for (var i = 0; i < 8; i++) {'route_id': '$i'},
        {'route_id': '0'},
      ],
      (id) async {
        active++;
        calls++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
        if (id == '2') throw StateError('unavailable');
        return {'route_id': id};
      },
    );
    expect(peak, 3);
    expect(calls, 8);
    expect(result.length, 7);
    expect(result.containsKey('2'), isFalse);
  });

  test('readiness requires authority, explicit flag and fresh evidence', () {
    final row = sample.fixture();
    expect(routeCardReadiness(row, fresh: true), 'Ready to start pickup');
    expect(routeCardReadiness(row, fresh: false), contains('Refresh'));
    expect(routeCardReadiness(null, fresh: true), contains('unavailable'));
    expect(
      routeCardReadiness(sample.fixture(authority: false), fresh: true),
      contains('not confirmed'),
    );
    expect(
      routeCardReadiness(sample.fixture(start: false), fresh: true),
      isNot('Ready to start pickup'),
    );
    expect(
      routeCardReadiness({
        ...sample.fixture(start: false),
        'dispatch_block_reason': 'REMAINING_ROUTE_INFEASIBLE',
      }, fresh: true),
      contains('leases'),
    );
    expect(
      routeCardReadiness(
        sample.fixture(start: false, complete: true),
        fresh: true,
      ),
      'Pickup in progress',
    );
  });

  for (final available in [true, false]) {
    testWidgets('route card display with detail available=$available', (
      tester,
    ) async {
      final row = sample.fixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PickupRouteCard(
              overview: row,
              detail: available ? row : null,
              fresh: true,
              onTap: () {},
            ),
          ),
        ),
      );
      expect(
        find.text(
          available ? 'V2 · AUTHORISED' : 'Assigned vehicle · AUTHORISED',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          available
              ? '3 pickups · 77 kg · 8.11 km · 44.41 min'
              : '— pickups · — kg',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          available
              ? 'Actual pickup start: Not started'
              : 'Route details unavailable',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Ready to start pickup'),
        available ? findsOneWidget : findsNothing,
      );
      if (available) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PickupRouteCard(
                overview: row,
                detail: {...row, 'actual_started_at': '2026-12-31T18:15:00Z'},
                fresh: true,
                onTap: () {},
              ),
            ),
          ),
        );
        expect(find.textContaining('1 Jan 2027, 02:15 MYT'), findsOneWidget);
      }
    });
  }

  for (final mode in ['assigned', 'empty', 'failed-read']) {
    final existing = mode != 'empty';
    final failed = mode == 'failed-read';
    testWidgets('confirmed empty eligibility: $mode', (tester) async {
      final operation = jsonEncode({
        'request_id': 'preserved-request',
        'status': 'authorized',
      });
      if (mode == 'assigned') {
        SharedPreferences.setMockInitialValues({
          'ngo_route_operation_synthetic-ngo': operation,
        });
      }
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, _) async {
          calls.add(name);
          switch (name) {
            case 'list_my_vehicles':
              return {
                'vehicles': [
                  {
                    'vehicle_id': 'v2',
                    'ngo_user_id': 'synthetic-ngo',
                    'vehicle_label': 'V2',
                    'payload_capacity_kg': 500,
                    'active_flag': true,
                    'available_for_planning': true,
                    'eligible_for_planning': false,
                  },
                ],
                'fleet_outcome': 'NO_FEASIBLE_PLAN',
              };
            case 'get_my_routing_overview':
              return {
                'contract': 'geolock.ngo-routing.v1',
                'ngo_id': 'synthetic-ngo',
                'eligible_tasks': [],
                'routes': existing ? [sample.fixture()] : [],
                'policy_id': 'policy',
                'authorization_enforced': true,
              };
            case 'get_my_claim_cards_v2':
              return [];
            case 'get_my_authorized_route':
              if (failed) throw StateError('detail unavailable');
              return sample.fixture();
            default:
              throw StateError('Unexpected RPC: $name');
          }
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No eligible claimed pickup tasks'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Existing pickups are assigned to your route below',
        ),
        existing && !failed ? findsOneWidget : findsNothing,
      );
      expect(
        find.textContaining('Reserved for an existing route'),
        existing && !failed ? findsOneWidget : findsNothing,
      );
      expect(
        find.textContaining('register an available vehicle'),
        findsNothing,
      );
      if (failed) {
        expect(
          find.textContaining('Route details unavailable'),
          findsOneWidget,
        );
        expect(find.textContaining('Ready to start pickup'), findsNothing);
      }
      if (mode == 'assigned') {
        expect(
          find.text(
            'Previously authorized route retained. Review it below; this is not a new authorization.',
          ),
          findsOneWidget,
        );
        expect(find.text('Route setup needs attention.'), findsNothing);
        expect(
          (await SharedPreferences.getInstance()).getString(
            'ngo_route_operation_synthetic-ngo',
          ),
          operation,
        );
      }
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('generate-route')))
            .onPressed,
        isNull,
      );
      expect(
        calls.every(
          (c) => {
            'list_my_vehicles',
            'get_my_routing_overview',
            'get_my_claim_cards_v2',
            'get_my_authorized_route',
          }.contains(c),
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
