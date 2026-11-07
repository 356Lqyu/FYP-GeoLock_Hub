// Synthetic presentation checks only: no platform maps, workers or DEV access.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/proposed_route_view.dart';
import 'route_details_presentation_test.dart' as fixtures;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final status in [
    'AUTHORISED',
    'IN_PROGRESS',
    'COMPLETED',
    'CANCELLED',
    'ABANDONED',
    'DRAFT',
    null,
  ]) {
    testWidgets(
      'Route details map is created only for active routes: $status',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 5000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final active = status == 'AUTHORISED' || status == 'IN_PROGRESS';
        final data = fixtures.fixture(authority: active, start: active);
        data['route_status'] = status;
        if (status == 'COMPLETED' || status == 'ABANDONED') {
          data['actual_started_at'] = '2026-10-28T17:00:01Z';
          for (final (index, stop)
              in (data['stops'] as List<Map<String, dynamic>>).indexed) {
            final collected = status == 'COMPLETED' || index == 0;
            stop['task_status'] = collected ? 'COLLECTED' : 'STALE';
            if (!collected) stop['deferred_status'] = 'RESOLVED_UNCOLLECTED';
          }
        }
        // Deliberately keep coordinates even on closed fixtures: status, not
        // missing coordinates or an empty depot, must prevent map construction.
        final original = jsonEncode(data);
        final calls = <String>[];
        var mapBuilds = 0;
        final repository = NgoRoutingRepository(
          identity: () => 'synthetic-ngo',
          rpc: (name, _) async {
            calls.add(name);
            if (name == 'get_my_authorized_route') return data;
            if (name == 'get_my_claim_cards_v2') {
              return fixtures.activeClaimCards(data);
            }
            fail('Unexpected RPC from presentation: $name');
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: NgoRouteDetailPage(
              routeId: 'synthetic-route',
              repository: repository,
              mapBuilder: (_) {
                mapBuilds++;
                return const SizedBox(
                  height: 40,
                  child: Text('Test route map'),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(ProposedRouteMap),
          active ? findsOneWidget : findsNothing,
        );
        expect(mapBuilds, active ? greaterThan(0) : 0);
        expect(
          find.text('Road geometry unavailable - markers only.'),
          active ? findsOneWidget : findsNothing,
        );
        for (final title in ['1. Test 10', '2. test c', '3. Test 42']) {
          expect(find.text(title), findsOneWidget);
        }
        if (status == 'COMPLETED') {
          expect(find.text('Completed pickup'), findsNWidgets(3));
        } else if (status == 'ABANDONED') {
          expect(find.text('Completed pickup'), findsOneWidget);
          expect(find.text('Not collected — resolved'), findsNWidgets(2));
        } else if (status == 'CANCELLED') {
          expect(find.text('Not started'), findsNWidgets(3));
        }
        expect(find.byKey(const Key('route-diagnostics')), findsNothing);
        for (final internal in [
          'ATTESTED',
          'synthetic-route',
          'synthetic-snapshot',
          'synthetic-candidate',
          '1755847853',
          'node-0',
        ]) {
          expect(find.textContaining(internal), findsNothing);
        }
        expect(
          find.text('8.11 km · 44.41 min · 77 kg · 3 pickups'),
          findsOneWidget,
        );
        expect(calls, ['get_my_authorized_route', 'get_my_claim_cards_v2']);
        expect(
          jsonEncode(data),
          original,
          reason: 'Display must retain raw evidence',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final terminal in ['COMPLETED', 'CANCELLED', 'ABANDONED']) {
    testWidgets(
      'Refresh unmounts the active map when route becomes $terminal',
      (tester) async {
        var data = fixtures.fixture();
        var mapBuilds = 0;
        final calls = <String>[];
        final repository = NgoRoutingRepository(
          identity: () => 'synthetic-ngo',
          rpc: (name, _) async {
            calls.add(name);
            if (name == 'get_my_claim_cards_v2') {
              return fixtures.activeClaimCards(data);
            }
            expect(name, 'get_my_authorized_route');
            return data;
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: NgoRouteDetailPage(
              routeId: 'synthetic-route',
              repository: repository,
              mapBuilder: (_) {
                mapBuilds++;
                return const SizedBox(height: 40);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ProposedRouteMap), findsOneWidget);
        final previousBuilds = mapBuilds;
        data = {
          ...data,
          'route_status': terminal,
          'authorization_confirmed': false,
        };
        await tester.tap(find.byIcon(Icons.refresh));
        await tester.pumpAndSettle();
        expect(find.byType(ProposedRouteMap), findsNothing);
        expect(mapBuilds, previousBuilds);
        await tester.pump(const Duration(seconds: 2));
        expect(mapBuilds, previousBuilds);
        expect(calls, [
          'get_my_authorized_route',
          'get_my_claim_cards_v2',
          'get_my_authorized_route',
          'get_my_claim_cards_v2',
        ]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
