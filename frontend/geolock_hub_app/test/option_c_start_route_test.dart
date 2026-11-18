// Option C Phase 1 — Generate Route → review → Start Route.
// Synthetic offline transport that mirrors the backend contract verified by the
// local PostgreSQL fixture tests. No Supabase connection, no DEV evidence.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/route_execution_controller.dart';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';
import 'option_c_fake_backend.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('repository', () {
    test('Generate Route plans only and reads backend validity', () async {
      final b = Backend();
      final r = b.repo();
      final result = await r.generateRoute(['van'], 'req-1', 'policy');
      expect(result['candidate_id'], 'candidate');
      expect(result['candidate_status']['startable'], isTrue);
      expect(result['candidate_status']['valid_until'], '2026-11-18T10:00:00.000Z');
      expect(b.calls, ['begin_my_routing_snapshot', 'get_my_route_candidate_status']);
      expect(b.planCalls, 1);
      expect(b.routeId, isNull, reason: 'nothing authorised by generation');
      expect((await r.pendingPlanning())['candidate_id'], 'candidate');
    });

    test('Start Route is one atomic RPC; no start_pickup for stop 1', () async {
      final b = Backend();
      final r = b.repo();
      await r.generateRoute(['van'], 'req-1', 'policy');
      b.calls.clear();
      final receipt = await r.authorizeAndStart('candidate');
      expect(receipt['route_status'], 'IN_PROGRESS');
      expect(receipt['started_task_id'], 't0');
      expect(b.calls, ['authorize_and_start_my_route']);
      expect(b.calls, isNot(contains('start_pickup')));
      final saved = await r.savedStartRequest('candidate');
      expect(saved, receipt['request_id']);
      expect(await r.pendingPlanning(), isEmpty, reason: 'archived after start');
    });

    test('request ID is persisted BEFORE the RPC is sent', () async {
      final b = Backend()..startGate = Completer<void>();
      final r = b.repo();
      final pending = r.authorizeAndStart('candidate');
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ngo_route_start_${ngo}_candidate'), isNotNull);
      b.startGate!.complete();
      await pending;
    });

    test('double press shares one in-flight call', () async {
      final b = Backend()..startGate = Completer<void>();
      final r = b.repo();
      final a = r.authorizeAndStart('candidate');
      final c = r.authorizeAndStart('candidate');
      b.startGate!.complete();
      final ra = await a, rc = await c;
      expect(ra['route_id'], rc['route_id']);
      expect(
        b.calls.where((c) => c == 'authorize_and_start_my_route'),
        hasLength(1),
      );
      await expectLater(
        r.authorizeAndStart('candidate'),
        completion(containsPair('route_id', 'route')),
        reason: 'later press reads the saved receipt, no new start',
      );
      expect(
        b.calls.where((c) => c == 'authorize_and_start_my_route'),
        hasLength(1),
      );
    });

    test('lost response after commit is recovered from the receipt', () async {
      final b = Backend()..loseStartResponse = true;
      final r = b.repo();
      final receipt = await r.authorizeAndStart('candidate');
      expect(receipt['route_id'], 'route');
      expect(b.calls, ['authorize_and_start_my_route', 'get_my_route_start_receipt']);
      expect(b.states, ['DISPATCHED', 'PLANNED']);
    });

    test('timeout before commit keeps the same request for a safe retry', () async {
      final b = Backend()..timeoutBeforeCommit = true;
      final r = b.repo();
      await expectLater(
        r.authorizeAndStart('candidate'),
        throwsA(
          isA<RoutingRequestFailure>()
              .having((e) => e.outcomeUnknown, 'unknown', isTrue)
              .having((e) => e.code, 'code', 'ROUTE_START_OUTCOME_UNKNOWN'),
        ),
      );
      final first = await r.savedStartRequest('candidate');
      expect(b.routeId, isNull);
      final receipt = await r.authorizeAndStart('candidate');
      expect(receipt['request_id'], first, reason: 'same request ID reused');
      expect(b.requests.keys, [first]);
    });

    test('typed rejections roll back and surface friendly messages', () async {
      for (final code in [
        'CANDIDATE_EXPIRED',
        'ONE_VEHICLE_ROUTE_REQUIRED',
        'PLAN_STALE_TASK',
        'PLAN_STALE_VEHICLE',
        'ROUTE_START_NOT_CONFIRMED',
      ]) {
        SharedPreferences.setMockInitialValues({});
        final b = Backend()..rejectStartWith = code;
        final r = b.repo();
        Object? error;
        try {
          await r.authorizeAndStart('candidate');
        } catch (e) {
          error = e;
        }
        expect(error, isA<PostgrestException>(), reason: code);
        expect(routingError(error!), isNot(contains('Database did not confirm')),
            reason: code);
        expect(b.routeId, isNull, reason: code);
        expect(b.calls, isNot(contains('get_my_route_start_receipt')),
            reason: 'a P0001 rejection needs no receipt read ($code)');
      }
    });

    test('receipt for another candidate is refused', () async {
      final b = Backend();
      final r = b.repo();
      await r.authorizeAndStart('candidate');
      final saved = (await r.savedStartRequest('candidate'))!;
      await expectLater(
        r.startReceipt(saved, 'other-candidate'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('execution after atomic start', () {
    test('adopted start continues to stop 2 after completion; stop 1 never re-sent',
        () async {
      final b = Backend();
      final r = b.repo();
      final controller = RouteExecutionController(r);
      final receipt = await r.authorizeAndStart('candidate');
      await controller.adoptAtomicStart(receipt);
      final prefs = await SharedPreferences.getInstance();
      final record =
          jsonDecode(prefs.getString('ngo_route_execution_${ngo}_route')!) as Map;
      expect(record['intent_id'], receipt['request_id']);
      expect(record['status'], 'active');
      b.calls.clear();
      await controller.completeCurrent('route', 't0');
      expect(b.states, ['COLLECTED', 'DISPATCHED']);
      expect(
        b.calls.where((c) => c == 'start_pickup' || c == 'complete_pickup'),
        ['complete_pickup', 'start_pickup'],
      );
      await controller.completeCurrent('route', 't1');
      expect(b.states, ['COLLECTED', 'COLLECTED']);
      expect(b.calls.where((c) => c == 'start_pickup'), hasLength(1));
      // Replayed receipt must not reset the journal.
      await controller.adoptAtomicStart({...receipt, 'replayed': true});
      final after =
          jsonDecode(prefs.getString('ngo_route_execution_${ngo}_route')!) as Map;
      expect(after['status'], isNot('active'));
    });

    test('adopt refuses an unconfirmed receipt', () async {
      final b = Backend();
      final controller = RouteExecutionController(b.repo());
      await expectLater(
        controller.adoptAtomicStart({'route_id': 'route'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('page', () {
    Future<void> pump(WidgetTester tester, Backend b) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRoutesPage(
            repository: b.repo(),
            mapBuilder: (m) => Text('Map markers: ${m.length}'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
    }

    testWidgets('Generate Route shows the route and validity; Start Route starts it',
        (tester) async {
      final b = Backend();
      await pump(tester, b);
      expect(find.text('Generate Route'), findsOneWidget);
      expect(find.text('Generate & Authorize Route'), findsNothing);
      expect(find.byKey(const Key('start-generated-route')), findsNothing);
      await tester.tap(find.byKey(const Key('generate-route')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('generated-route-card')), findsOneWidget);
      expect(find.textContaining('Start by'), findsOneWidget);
      expect(find.textContaining(' left'), findsOneWidget);
      expect(b.routeId, isNull, reason: 'generation authorises nothing');
      final start = find.byKey(const Key('start-generated-route'));
      expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(b.routeId, 'route');
      expect(b.calls.where((c) => c == 'authorize_and_start_my_route'), hasLength(1));
      expect(b.calls, isNot(contains('start_pickup')));
      expect(b.calls, isNot(contains('authorize_my_routing_candidate')));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('expired candidate disables Start Route', (tester) async {
      final b = Backend()..expired = true;
      await pump(tester, b);
      await tester.tap(find.byKey(const Key('generate-route')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('start-generated-route'))).onPressed,
        isNull,
      );
      expect(find.textContaining('expired'), findsWidgets);
      expect(b.calls, isNot(contains('authorize_and_start_my_route')));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('multi-route candidate disables Start Route', (tester) async {
      final b = Backend()..multiRoute = true;
      await pump(tester, b);
      await tester.tap(find.byKey(const Key('generate-route')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('start-generated-route'))).onPressed,
        isNull,
      );
      expect(find.textContaining('more than one vehicle'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
