// Offline UI transport; not a live route, location or handover test.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/route_card_view.dart';
import 'route_execution_test.dart' as synthetic;

class WidgetLane extends synthetic.Lane {
  bool closed = false;
  bool expiryPendingRecovery = false;
  final calls = <String>[];
  @override
  Map<String, dynamic> detail() => {
    ...super.detail(),
    if (closed) 'route_status': 'COMPLETED',
    'authorization_confirmed': !closed,
    'can_close': !closed && states.every((s) => s == 'COLLECTED'),
    'vehicle_label': 'Test van',
    'validation_status': 'ATTESTED',
    'total_distance_km': 3,
    'total_duration_min': 40,
    'total_load_kg': 30,
    'pickup_count': 3,
    'departure_at': '2026-10-30T00:00:00Z',
    'actual_started_at': states.first == 'PLANNED'
        ? null
        : '2026-10-30T00:00:01Z',
    'depot': {'latitude': 3.2, 'longitude': 101.6},
    'stops': [
      for (final s in super.detail()['stops'] as List<Map<String, dynamic>>)
        {
          ...s,
          if (expiryPendingRecovery) 'lease_expired_pending_recovery': true,
          'title': 'Donation ${s['stop_order']}',
          'load_kg': 10,
          'pickup_latitude': 3.21,
          'pickup_longitude': 101.61,
          'planned_arrival': '2026-10-30T00:01:00Z',
        },
    ],
  };
  @override
  Future<Object?> rpc(String name, Map<String, dynamic> params) async {
    calls.add(name);
    if (name == 'get_my_mixed_route_close_receipt') {
      final request = params['p_request'];
      return {
        'found': true,
        'request_id': request,
        'route_id': 'route',
        'result': {
          'route_id': 'route',
          'route_status': 'ABANDONED',
          'request_id': request,
        },
      };
    }
    if (name == 'close_my_collected_route') {
      expect(states, everyElement('COLLECTED'));
      expect(params, {'p_route': 'route', 'p_depot_return_confirmed': true});
      writes.add('close');
      closed = true;
      return null;
    }
    return super.rpc(name, params);
  }
}

Future<void> open(WidgetTester tester, WidgetLane l) async {
  await tester.pumpWidget(
    MaterialApp(
      home: NgoRouteDetailPage(
        routeId: 'route',
        repository: l.repo,
        mapBuilder: (_) => const SizedBox(height: 40),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> complete(WidgetTester tester, int index) async {
  final button = find.widgetWithText(FilledButton, 'Complete pickup').at(index);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Confirm'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'expired never-started pickup is labelled and requires confirmation before defer',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final l = WidgetLane()..reconciliationNeeded[0] = true;
      await open(tester, l);
      expect(find.text('Needs reconciliation'), findsOneWidget);
      final skip = find.byKey(const Key('defer-pickup-t0'));
      await tester.ensureVisible(skip);
      await tester.tap(skip);
      await tester.pumpAndSettle();
      expect(find.text('Skip this pickup for now?'), findsOneWidget);
      expect(l.writes, isEmpty);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(
        l.calls,
        contains('defer_my_pickup_for_reconciliation'),
        reason:
            'Protected calls: ${l.calls}; route error: ${tester.widgetList<Text>(find.byKey(const Key('routing-error'))).map((t) => t.data).toList()}',
      );
      expect(l.writes, ['defer:0']);
      expect(l.states[0], 'PLANNED');
      expect(l.deferred[0], isTrue);
      expect(find.text('Needs reconciliation'), findsOneWidget);

      await tester.tap(find.text('Start Route'));
      await tester.pumpAndSettle();
      expect(l.writes, ['defer:0', 'start:1']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('expired lease waits for protected recovery before showing skip', (
    tester,
  ) async {
    final l = WidgetLane()..expiryPendingRecovery = true;
    await open(tester, l);
    expect(find.text('Waiting for expiry recovery'), findsOneWidget);
    expect(
      find.textContaining(
        'protected backend recovery process has not opened reconciliation yet',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('defer-pickup-t0')), findsNothing);
    expect(l.writes, isEmpty);
  });

  testWidgets('uncertain deferral exposes explicit same-request recovery', (
    tester,
  ) async {
    final l = WidgetLane()
      ..reconciliationNeeded[0] = true
      ..lostDeferBeforeCommit = 0;
    await open(tester, l);
    await tester.ensureVisible(find.byKey(const Key('defer-pickup-t0')));
    await tester.tap(find.byKey(const Key('defer-pickup-t0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('retry-saved-deferral')), findsOneWidget);
    final firstRequest = l.deferRequestIds.single;
    await tester.ensureVisible(find.text('Recover saved request'));
    await tester.tap(find.text('Recover saved request'));
    await tester.pumpAndSettle();
    expect(l.deferRequestIds, [firstRequest, firstRequest]);
    expect(l.deferred[0], isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'saved mixed closure is recovered by receipt without another close',
    (tester) async {
      const request = 'original-close-request';
      SharedPreferences.setMockInitialValues({
        'ngo_mixed_route_close_ngo_route': request,
      });
      final l = WidgetLane();
      await open(tester, l);
      expect(
        find.byKey(const Key('recover-mixed-route-close')),
        findsOneWidget,
      );
      expect(l.writes, isEmpty);
      await tester.ensureVisible(find.text('Recover saved closure'));
      await tester.tap(find.text('Recover saved closure'));
      await tester.pumpAndSettle();
      expect(l.calls, contains('get_my_mixed_route_close_receipt'));
      expect(l.calls, isNot(contains('close_my_resolved_route')));
      expect(await l.repo.pendingMixedRouteClosure('route'), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'operator-authorized route adopts execution intent without a local planning record',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const oldJournal = 'preserved-old-route-journal';
      const oldReceipt = 'preserved-old-authorization';
      SharedPreferences.setMockInitialValues({
        'ngo_route_execution_ngo_old-v2': oldJournal,
        'ngo_route_operation_history_ngo_old-operation': oldReceipt,
      });
      final lane = WidgetLane();
      final calls = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, params) async {
          calls.add(name);
          if (name == 'list_my_vehicles') return {'vehicles': []};
          if (name == 'get_my_claim_cards_v2') return [];
          if (name == 'get_my_routing_overview') {
            return {
              'contract': 'geolock.ngo-routing.v1',
              'ngo_id': 'ngo',
              'policy_id': 'policy',
              'authorization_enforced': true,
              'eligible_tasks': [],
              'routes': [
                {...lane.detail(), 'vehicle_id': 'v3'},
              ],
            };
          }
          return lane.rpc(name, params);
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRoutesPage(
            repository: repo,
            mapBuilder: (_) => const SizedBox(height: 40),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(lane.writes, isEmpty);
      expect(await repo.routeOperation(), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_execution_ngo_route',
        ),
        isNull,
      );
      await tester.ensureVisible(find.byType(PickupRouteCard));
      await tester.tap(find.byType(PickupRouteCard));
      await tester.pumpAndSettle();
      expect(lane.writes, isEmpty);
      await tester.tap(find.text('Start Route'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await complete(tester, i);
      }
      final close = find.text('Confirm depot return and close route');
      await tester.ensureVisible(close);
      await tester.tap(close);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(lane.writes, [
        'start:0',
        'complete:0',
        'start:1',
        'complete:1',
        'start:2',
        'complete:2',
        'close',
      ]);
      final prefs = await SharedPreferences.getInstance();
      final execution =
          jsonDecode(prefs.getString('ngo_route_execution_ngo_route')!) as Map;
      expect(execution['intent_id'], isNotEmpty);
      expect(lane.closed, true);
      expect(prefs.getString('ngo_route_execution_ngo_old-v2'), oldJournal);
      expect(
        prefs.getString('ngo_route_operation_history_ngo_old-operation'),
        oldReceipt,
      );
      expect(calls, isNot(contains('begin_my_routing_snapshot')));
      expect(calls, isNot(contains('authorize_my_routing_candidate')));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'lost completion response is reconciled without automatically starting next stop',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final l = WidgetLane();
      await open(tester, l);
      await tester.tap(find.text('Start Route'));
      await tester.pumpAndSettle();
      l.lostComplete = 0;
      await complete(tester, 0);
      expect(l.states, ['COLLECTED', 'PLANNED', 'PLANNED']);
      expect(l.writes, ['start:0', 'complete:0']);
      expect(find.text('Continue route'), findsOneWidget);
      expect(find.byKey(const Key('routing-error')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await open(tester, l);
      expect(l.writes, ['start:0', 'complete:0']);
      await tester.tap(find.text('Continue route'));
      await tester.pumpAndSettle();
      expect(l.writes, ['start:0', 'complete:0', 'start:1']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unconfirmed unchanged pickup disables writes even after refresh and reopen',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final l = WidgetLane();
      await open(tester, l);
      await tester.tap(find.text('Start Route'));
      await tester.pumpAndSettle();
      l.unsentComplete = 0;
      await complete(tester, 0);
      await tester.pumpWidget(const SizedBox());
      await open(tester, l);
      expect(
        find.textContaining('Pickup outcome is not confirmed.'),
        findsOneWidget,
      );
      for (final button in tester.widgetList<FilledButton>(
        find.widgetWithText(FilledButton, 'Complete pickup'),
      )) {
        expect(button.onPressed, isNull);
      }
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(l.writes, ['start:0', 'complete:0']);
      expect((await l.read())['status'], 'uncertain');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Start Route once then complete three stops and confirm return', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final l = WidgetLane();
    await open(tester, l);
    expect(find.text('Start Route'), findsOneWidget);
    expect(find.text('Start pickup'), findsNothing);
    expect(find.textContaining('Planned arrival:'), findsNWidgets(3));
    await tester.tap(find.text('Start Route'));
    await tester.pumpAndSettle();
    expect(l.writes, ['start:0']);
    for (var i = 0; i < 3; i++) {
      await complete(tester, i);
      expect(find.text('Completed pickup'), findsNWidgets(i + 1));
      if (i < 2) {
        expect(l.states[i + 1], 'DISPATCHED');
        expect(find.text('Start Route'), findsNothing);
        expect(find.text('Continue route'), findsNothing);
      }
    }
    expect(l.writes, [
      'start:0',
      'complete:0',
      'start:1',
      'complete:1',
      'start:2',
      'complete:2',
    ]);
    final close = find.text('Confirm depot return and close route');
    await tester.ensureVisible(close);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(l.closed, false);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(l.closed, true);
    expect(l.writes.last, 'close');
    expect(
      find.text('Route completed. No further pickup actions.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reopen performs reads only and retains execution intent', (
    tester,
  ) async {
    final l = WidgetLane();
    await l.controller.startRoute('route');
    final intent = (await l.read())['intent_id'];
    await open(tester, l);
    await tester.pumpWidget(const SizedBox());
    await open(tester, l);
    expect(l.writes, ['start:0']);
    expect((await l.read())['intent_id'], intent);
    expect(find.text('Current pickup'), findsOneWidget);
    expect(find.text('Start Route'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failed next start retains completed stop and shows explicit continuation',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final l = WidgetLane();
      await open(tester, l);
      await tester.tap(find.text('Start Route'));
      await tester.pumpAndSettle();
      l.rejectStart = 1;
      await complete(tester, 0);
      expect(l.states, ['COLLECTED', 'PLANNED', 'PLANNED']);
      expect(find.text('Completed pickup'), findsOneWidget);
      expect(find.textContaining('Previous pickup completed.'), findsOneWidget);
      expect(find.text('Continue route'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await open(tester, l);
      expect(l.writes, ['start:0', 'complete:0', 'start:1']);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
