import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/route_card_view.dart';
import 'route_details_presentation_test.dart' as sample;

Map<String, dynamic> releasedRoute() => {
  ...sample.fixture(start: false),
  'no_collection_cancellation_eligible': true,
  'can_cancel': true,
  'can_close': false,
  'stops': <Map<String, dynamic>>[],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('only authoritative no-collection outcomes support the wording', () {
    final row = releasedRoute();
    expect(routeCardReadiness(row, fresh: true), 'No active pickups remain');
    expect(routeCardReadiness(row, fresh: false), contains('Refresh'));
    row['route_status'] = 'CANCELLED';
    row['no_collection_cancellation_eligible'] = false;
    expect(routeCardReadiness(row, fresh: true), 'Route cancelled');
    row['cancellation_outcome'] = 'NO_COLLECTION';
    expect(
      routeCardReadiness(row, fresh: true),
      'Route cancelled — no pickups completed',
    );
  });

  test('close permission does not assert collection', () {
    final row = {...sample.fixture(start: false), 'can_close': true};
    expect(
      routeCardReadiness(row, fresh: true),
      'Ready for route closure. Confirm return to depot.',
    );
    row['closure_outcome'] = 'ABANDONED';
    expect(
      routeCardReadiness(row, fresh: true),
      'Pickups resolved. Confirm return to depot.',
    );
  });

  test(
    'repository rereads authority before cancellation and rejects stale permission',
    () async {
      var reads = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          expect(name, 'get_my_authorized_route');
          reads++;
          return {...releasedRoute(), 'can_cancel': false};
        },
      );
      await expectLater(repo.cancel('synthetic-route'), throwsStateError);
      expect(reads, 1);
    },
  );

  testWidgets(
    'safe cancellation preserves confirmation, refresh and terminal wording',
    (tester) async {
      var row = releasedRoute();
      final writes = <String>[];
      var reads = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          if (name == 'get_my_claim_cards_v2') return [];
          if (name == 'get_my_authorized_route') {
            reads++;
            return row;
          }
          expect(name, 'cancel_my_unstarted_route');
          expect(params, {'p_route': 'synthetic-route'});
          writes.add(name);
          row = {
            ...row,
            'route_status': 'CANCELLED',
            'authorization_confirmed': false,
            'can_cancel': false,
            'no_collection_cancellation_eligible': false,
            'cancellation_outcome': 'NO_COLLECTION',
          };
          return null;
        },
      );
      tester.view.physicalSize = const Size(1200, 2800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRouteDetailPage(
            routeId: 'synthetic-route',
            repository: repo,
            mapBuilder: (_) => const SizedBox(height: 30),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No active pickups remain'), findsOneWidget);
      expect(find.text('Confirm depot return and close route'), findsNothing);
      final cancel = find.text('Cancel Route — No Pickups Completed');
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      expect(
        find.textContaining('Released claims, pickup outcomes'),
        findsOneWidget,
      );
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(writes, ['cancel_my_unstarted_route']);
      expect(reads, greaterThanOrEqualTo(3));
      expect(
        find.text('Route cancelled — no pickups completed'),
        findsOneWidget,
      );
      expect(find.text('Confirm depot return and close route'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('expired page freshness disables safe cancellation', (
    tester,
  ) async {
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (name, params) async {
        if (name == 'get_my_claim_cards_v2') return [];
        expect(name, 'get_my_authorized_route');
        return releasedRoute();
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NgoRouteDetailPage(
          routeId: 'synthetic-route',
          repository: repo,
          mapBuilder: (_) => const SizedBox(height: 20),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 31));
    final button = find.widgetWithText(
      TextButton,
      'Cancel Route — No Pickups Completed',
    );
    await tester.ensureVisible(button);
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
