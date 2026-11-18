// Phase 2 per-task lease routing: effective candidate deadline, protected stop
// removal (detach), uncertain-outcome replay and execution continuation.
// Synthetic offline transport mirroring the SQL contract verified locally.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/route_execution_controller.dart';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';
import 'option_c_fake_backend.dart';

/// Started 3-stop per-task route; stop 3 can no longer meet its claim deadline.
class LeaseLane {
  final states = ['DISPATCHED', 'PLANNED', 'PLANNED'];
  final detached = [false, false, false];
  bool stop3Infeasible = true;
  bool loseDetachResponse = false;
  bool rejectDetach = false;
  final calls = <String>[];
  final detachRequests = <String>[];
  final startedClaims = <String>[];
  final receipts = <String, Map<String, dynamic>>{};
  bool closed = false;

  NgoRoutingRepository repo() =>
      NgoRoutingRepository(identity: () => ngo, rpc: rpc);

  int get _current {
    final d = states.indexWhere((s) => s == 'DISPATCHED');
    if (d >= 0) return d;
    for (var i = 0; i < 3; i++) {
      if (!detached[i] && states[i] == 'PLANNED') return i;
    }
    return -1;
  }

  bool get _blocked =>
      stop3Infeasible && !detached[2] && states[2] == 'PLANNED';

  Map<String, dynamic> detail() {
    final cur = _current;
    final dispatched = states.contains('DISPATCHED');
    return {
      'contract': 'geolock.ngo-routing.v1',
      'ngo_id': ngo,
      'route_id': 'route',
      'route_status': closed ? 'COMPLETED' : 'IN_PROGRESS',
      'authorization_confirmed': !closed,
      'lease_policy': 'PER_TASK_SERVICE_COMPLETION',
      'vehicle_label': 'Van',
      'total_distance_km': 9,
      'total_duration_min': 40,
      'total_load_kg': 36,
      'pickup_count': 3,
      'departure_at': '2026-11-18T01:00:00Z',
      'actual_started_at': '2026-11-18T01:00:00Z',
      'depot': {'latitude': 3.2, 'longitude': 101.6},
      'next_executable_task_id': dispatched || cur < 0 ? null : 't$cur',
      'dispatch_block_reason': !dispatched && _blocked
          ? 'DISPATCH_WINDOW_OR_LEASE_EXPIRED'
          : null,
      'can_close':
          !closed &&
          !dispatched &&
          [for (var i = 0; i < 3; i++) detached[i] || states[i] == 'COLLECTED']
              .every((x) => x),
      'closure_outcome': 'COMPLETED',
      'stops': [
        for (var i = 0; i < 3; i++)
          {
            'task_id': 't$i',
            'claim_id': 'c$i',
            'title': 'Donation $i',
            'stop_order': i + 1,
            'task_status': detached[i] ? 'CONFIRMED' : states[i],
            'load_kg': 12,
            'planned_arrival': '2026-11-18T01:2$i:00Z',
            'detached': detached[i],
            if (!detached[i]) ...{
              'projected_completion': '2026-11-18T01:3$i:00Z',
              'lease_deadline': i == 2 ? '2026-11-18T01:30:00Z' : '2026-11-18T05:00:00Z',
              'projected_feasible': !(i == 2 && stop3Infeasible),
              'projection_reason': i == 2 && stop3Infeasible ? 'LEASE' : null,
            },
            'can_detach':
                i == 2 && stop3Infeasible && !detached[i] && states[i] == 'PLANNED',
            'can_start':
                !dispatched && !_blocked && cur == i && states[i] == 'PLANNED',
            'can_complete': states[i] == 'DISPATCHED',
            'can_defer': false,
          },
      ],
    };
  }

  Future<Object?> rpc(String name, Map<String, dynamic> p) async {
    calls.add(name);
    switch (name) {
      case 'get_my_authorized_route':
        return detail();
      case 'get_my_claim_cards_v2':
        return [];
      case 'detach_my_unstarted_stop':
        final request = p['p_request'] as String;
        detachRequests.add(request);
        final prior = receipts[request];
        if (prior != null) return {...prior, 'replayed': true};
        if (rejectDetach) {
          throw const PostgrestException(
            message: 'STOP_STILL_FEASIBLE',
            code: 'P0001',
          );
        }
        final i = int.parse((p['p_task'] as String).substring(1));
        expect(states[i], 'PLANNED');
        if (detached[i]) {
          throw const PostgrestException(
            message: 'STOP_ALREADY_RELEASED',
            code: 'P0001',
          );
        }
        detached[i] = true;
        final receipt = {
          'contract': 'geolock.routing-detach-stop.v1',
          'ngo_id': ngo,
          'request_id': request,
          'route_id': p['p_route'],
          'task_id': p['p_task'],
          'claim_id': 'c$i',
          'reason': 'LEASE',
          'claim_status': 'ACTIVE',
          'task_status': 'CONFIRMED',
          'remaining_feasible': true,
          'replayed': false,
        };
        receipts[request] = receipt;
        if (loseDetachResponse) {
          loseDetachResponse = false;
          throw TimeoutException('synthetic lost detach response');
        }
        return receipt;
      case 'start_pickup':
        final i = int.parse((p['p_claim'] as String).substring(1));
        startedClaims.add('c$i');
        if (states.contains('DISPATCHED') || _blocked || detached[i]) {
          throw const PostgrestException(
            message: 'DISPATCH_WINDOW_OR_LEASE_EXPIRED',
            code: 'P0001',
          );
        }
        states[i] = 'DISPATCHED';
        return null;
      case 'complete_pickup':
        final i = int.parse((p['p_claim'] as String).substring(1));
        expect(states[i], 'DISPATCHED');
        states[i] = 'COLLECTED';
        return null;
      case 'close_my_collected_route':
        closed = true;
        return null;
    }
    throw PostgrestException(message: 'FAKE_UNSUPPORTED_$name', code: 'P0001');
  }
}

Future<void> seedIntent() async {
  // The route was started through Option C Start Route (consent recorded).
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    'ngo_route_execution_${ngo}_route',
    jsonEncode({
      'version': 1,
      'owner': ngo,
      'route_id': 'route',
      'intent_id': 'start-request',
      'history': [],
      'status': 'active',
    }),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('candidate deadline', () {
    testWidgets('card shows the backend effective deadline and its reason', (
      tester,
    ) async {
      final b = Backend()..leaseLimit = const Duration(minutes: 35);
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: b.repo())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('generate-route')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final text = tester
          .widget<Text>(find.byKey(const Key('generated-route-validity')))
          .data!;
      // server_now 09:10, lease-limited deadline 09:35 (not the 10:00 window).
      expect(text, startsWith('Start by '));
      expect(text, contains('24 min'));
      expect(find.text('Limited by a claim deadline in this route.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('start-generated-route')))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('lease-expired candidate cannot be started', (tester) async {
      final b = Backend()..leaseLimit = const Duration(minutes: 5);
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: b.repo())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('generate-route')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('start-generated-route')))
            .onPressed,
        isNull,
      );
      expect(
        find.textContaining('no longer has enough time left'),
        findsOneWidget,
      );
      expect(b.calls, isNot(contains('authorize_and_start_my_route')));
      await tester.pumpWidget(const SizedBox());
    });

    test('friendly messages for Phase 2 rejection codes', () {
      for (final code in [
        'CANDIDATE_DEADLINE_PASSED',
        'STOP_LEASE_INSUFFICIENT',
        'STOP_STILL_FEASIBLE',
        'STOP_ALREADY_STARTED',
        'STOP_CUSTODY_UNCERTAIN',
        'LEASE_EXPIRED_RECOVERY_REQUIRED',
        'DISPATCH_WINDOW_OR_LEASE_EXPIRED',
      ]) {
        final text = routingError(PostgrestException(message: code, code: 'P0001'));
        expect(text, isNot(contains('Database did not confirm')), reason: code);
      }
    });
  });

  group('repository.detachStop', () {
    test('saves the request first, sends once and validates the receipt', () async {
      final l = LeaseLane();
      final r = l.repo();
      final receipt = await r.detachStop('route', 't2');
      expect(receipt['claim_status'], 'ACTIVE');
      expect(l.detachRequests, hasLength(1));
      expect(await r.pendingDetach('route', 't2'), isNull);
      expect(l.calls.where((c) => c == 'start_pickup'), isEmpty);
    });

    test('refuses when the backend does not allow removal', () async {
      final l = LeaseLane()..stop3Infeasible = false;
      await expectLater(
        l.repo().detachStop('route', 't2'),
        throwsA(isA<StateError>()),
      );
      expect(l.detachRequests, isEmpty);
    });

    test('lost response: the same saved request is replayed, never a new one', () async {
      final l = LeaseLane()..loseDetachResponse = true;
      final r = l.repo();
      await expectLater(
        r.detachStop('route', 't2'),
        throwsA(
          isA<RoutingRequestFailure>()
              .having((e) => e.outcomeUnknown, 'unknown', isTrue)
              .having((e) => e.code, 'code', 'STOP_DETACH_OUTCOME_UNKNOWN'),
        ),
      );
      final saved = await r.pendingDetach('route', 't2');
      expect(saved, l.detachRequests.single);
      // The stop now reads as detached (can_detach false), but the saved
      // request still goes through and the backend replays its receipt.
      final again = await r.detachStop('route', 't2');
      expect(again['replayed'], isTrue);
      expect(l.detachRequests, [saved, saved]);
      expect(l.detached, [false, false, true]);
    });

    test('typed rejection keeps the saved ID for a safe retry', () async {
      final l = LeaseLane()..rejectDetach = true;
      final r = l.repo();
      await expectLater(r.detachStop('route', 't2'), throwsA(isA<PostgrestException>()));
      expect(await r.pendingDetach('route', 't2'), l.detachRequests.single);
    });
  });

  group('execution with a detached stop', () {
    test('current stop skips detached stops; continuation dispatches each pickup once',
        () async {
      await seedIntent();
      final l = LeaseLane();
      final c = RouteExecutionController(l.repo());
      expect(RouteExecutionController.currentStop(l.detail())!['task_id'], 't0');
      // Stop 1 completes; stop 2 cannot start while stop 3 is infeasible.
      await c.completeCurrent('route', 't0');
      expect(l.states, ['COLLECTED', 'PLANNED', 'PLANNED']);
      expect(l.startedClaims, isEmpty, reason: 'blocked: never dispatched unsafely');
      final record = await c.reconcile('route', l.detail());
      expect(record['message'], contains('Remove from route'));
      // Protected removal of stop 3, then explicit continue.
      await c.detachStop('route', 't2');
      expect(l.startedClaims, isEmpty, reason: 'removal never dispatches');
      await c.startRoute('route');
      expect(l.startedClaims, ['c1']);
      await c.completeCurrent('route', 't1');
      expect(l.states, ['COLLECTED', 'COLLECTED', 'PLANNED']);
      expect(l.detached, [false, false, true]);
      expect(RouteExecutionController.currentStop(l.detail()), isNull);
      final done = await c.reconcile('route', l.detail());
      expect(done['status'], 'awaiting_depot');
      expect(l.startedClaims, ['c1'], reason: 'no pickup dispatched twice');
    });
  });

  group('route detail page', () {
    testWidgets('only the infeasible stop offers Remove from route; confirm removes it once',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 3400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await seedIntent();
      final l = LeaseLane()..states[0] = 'COLLECTED';
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRouteDetailPage(
            routeId: 'route',
            repository: l.repo(),
            mapBuilder: (_) => const SizedBox(height: 40),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detach-stop-t2')), findsOneWidget);
      expect(find.byKey(const Key('detach-stop-t1')), findsNothing);
      expect(find.byKey(const Key('stop-infeasible-t2')), findsOneWidget);
      expect(find.byKey(const Key('stop-projection-t1')), findsOneWidget);
      expect(find.byKey(const Key('dispatch-block-reason')), findsOneWidget);
      final remove = find.byKey(const Key('detach-stop-t2'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.text('Remove this pickup from the route?'), findsOneWidget);
      expect(l.detachRequests, isEmpty, reason: 'nothing sent before confirmation');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(l.detachRequests, hasLength(1));
      expect(l.detached, [false, false, true]);
      expect(find.text('Removed from route — claim kept'), findsOneWidget);
      expect(find.byKey(const Key('detach-stop-t2')), findsNothing);
      expect(l.startedClaims, isEmpty, reason: 'removal does not start a pickup');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
