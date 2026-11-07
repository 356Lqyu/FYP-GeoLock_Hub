// Offline presentation and protected-action gates only; no live Supabase calls.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/route_display_formatters.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';

const originalAddress =
    '422, 422, Jalan E 2/3, Taman Ehsan, 52100 Kuala Lumpur, Selangor,Malaysia, Taman Ehsan, Kuala Lumpur, Selangor, 52100, Malaysia';
const cleanAddress =
    '422, Jalan E 2/3, Taman Ehsan, 52100 Kuala Lumpur, Selangor, Malaysia';

Map<String, dynamic> fixture({
  bool authority = true,
  bool start = true,
  bool complete = false,
}) => {
  'contract': 'geolock.ngo-routing.v1',
  'ngo_id': 'synthetic-ngo',
  'route_id': 'synthetic-route',
  'snapshot_id': 'synthetic-snapshot',
  'candidate_id': 'synthetic-candidate',
  'vehicle_id': 'v2',
  'route_status': 'AUTHORISED',
  'authorization_confirmed': authority,
  'validation_status': 'ATTESTED',
  'vehicle_label': 'V2',
  'total_distance_km': 8.107,
  'total_duration_min': 44.405,
  'total_load_kg': 77.0,
  'pickup_count': 3,
  'pickup_location_count': 3,
  'departure_at': '2026-10-28T16:51:13.945122+00:00',
  'actual_started_at': null,
  'depot_road_node_id': '1755847853',
  'depot': {'latitude': 3.21755, 'longitude': 101.62384},
  'can_close': false,
  'can_cancel': false,
  'stops': [
    for (var i = 0; i < 3; i++)
      {
        'task_id': 'task-$i',
        'claim_id': 'claim-$i',
        'stop_order': i + 1,
        'title': ['Test 10', 'test c', 'Test 42'][i],
        'load_kg': [15, 12, 50][i],
        'task_status': complete ? 'DISPATCHED' : 'PLANNED',
        'source_type': 'DIRECT_DONATION',
        'pickup_road_node_id': 'node-$i',
        'pickup_latitude': 3.22 + i * .001,
        'pickup_longitude': 101.62,
        'pickup_address': originalAddress,
        'actual_started_at': null,
        'planned_arrival': [
          '2026-10-28T16:52:22Z',
          '2026-10-28T17:02:55Z',
          '2026-10-28T17:19:32Z',
        ][i],
        'can_start': i == 0 && start,
        'can_complete': i == 0 && complete,
      },
  ],
};

List<Map<String, dynamic>> activeClaimCards(
  Map<String, dynamic> data, {
  Duration leaseFor = const Duration(hours: 1),
  DateTime? leaseExpiresAt,
  DateTime? serverNow,
}) {
  final now = (serverNow ?? DateTime.now()).toUtc();
  final expiry = leaseExpiresAt ?? now.add(leaseFor);
  final expired = !expiry.isAfter(now);
  final expires = expiry.toIso8601String();
  return [
    for (final stop in data['stops'] as List<Map<String, dynamic>>)
      {
        'claim_id': stop['claim_id'],
        'listing_id': 'listing-${stop['stop_order']}',
        'claim_status': 'ACTIVE',
        'lease_id': 'lease-${stop['stop_order']}',
        'lease_status': 'ACTIVE',
        'lease_expires_at': expires,
        'task_status': stop['task_status'],
        'source_type': 'DIRECT_DONATION',
        'server_now': now.toIso8601String(),
        'lease_is_expired': expired,
        'lease_recovery_pending': expired,
      },
  ];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('MYT handles day/year rollover and explicit non-UTC offsets', () {
    expect(
      routeMytTime('2026-10-28T16:51:13.945122Z'),
      '29 Oct 2026, 00:51 MYT',
    );
    expect(routeMytTime('2026-12-31T18:15:00Z'), '1 Jan 2027, 02:15 MYT');
    expect(routeMytTime('2026-10-28T18:51:13+02:00'), '29 Oct 2026, 00:51 MYT');
    expect(
      routeMytTime(DateTime.utc(2026, 10, 28, 16, 51)),
      '29 Oct 2026, 00:51 MYT',
    );
  });
  test('null and ambiguous times do not depend on the phone timezone', () {
    expect(routeMytTime(null, missing: 'Not started'), 'Not started');
    expect(routeMytTime('2026-10-28T16:51:13'), 'Time unavailable');
    expect(routeMytTime('invalid'), 'Time unavailable');
  });
  test(
    'addresses deduplicate exact components and redundant postcode/locality',
    () {
      expect(routeDisplayAddress(originalAddress), cleanAddress);
      expect(
        routeDisplayAddress(
          'Aman Tiga Apartment, Aman Tiga Apartment, Taman Wangsa Permai, 52200 Sungai Buloh, Selangor, Malaysia, Taman Wangsa Permai, Sungai Buloh, Selangor, 52200, Malaysia',
        ),
        'Aman Tiga Apartment, Taman Wangsa Permai, 52200 Sungai Buloh, Selangor, Malaysia',
      );
      expect(routeDisplayAddress(cleanAddress), cleanAddress);
      expect(
        routeDisplayAddress('  Block A, block a,  Jalan  E 2/3 '),
        'Block A, Jalan E 2/3',
      );
    },
  );
  test(
    'address formatting preserves distinct units streets and postcode details',
    () {
      const address =
          'Unit 12, Block 12, Jalan 12, Jalan 12A, 52100 Kuala Lumpur, 52200 Sungai Buloh';
      expect(routeDisplayAddress(address), address);
      expect(routeDisplayAddress(null), 'Address unavailable');
      expect(routeLoadText(77.0), '77');
      expect(routeLoadText(77.25), '77.25');
    },
  );

  testWidgets(
    'compact MYT summary ordered stops and map without technical diagnostics',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final data = fixture();
      final originalDeparture = data['departure_at'];
      final calls = <String>[];
      Set<Marker> markers = {};
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, _) async {
          calls.add(name);
          if (name == 'get_my_claim_cards_v2') return activeClaimCards(data);
          expect(name, 'get_my_authorized_route');
          return data;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRouteDetailPage(
            routeId: 'synthetic-route',
            repository: repo,
            mapBuilder: (value) {
              markers = value;
              return const SizedBox(
                height: 80,
                child: Text('Offline marker map'),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Authorised · V2'), findsOneWidget);
      expect(
        find.text('8.11 km · 44.41 min · 77 kg · 3 pickups'),
        findsOneWidget,
      );
      expect(
        find.text('Planned departure: 29 Oct 2026, 00:51 MYT'),
        findsOneWidget,
      );
      expect(find.text('Actual pickup start: Not started'), findsOneWidget);
      expect(find.textContaining('29 Oct 2026, 01:02 MYT'), findsOneWidget);
      expect(
        find.text('Road geometry unavailable - markers only.'),
        findsOneWidget,
      );
      expect(markers.length, 4);
      expect(
        markers
            .where((m) => m.markerId.value.startsWith('pickup'))
            .every((m) => m.infoWindow.snippet == cleanAddress),
        isTrue,
      );
      expect(find.textContaining('Raw address:'), findsNothing);
      expect(
        tester.getTopLeft(find.text('1. Test 10')).dy,
        lessThan(tester.getTopLeft(find.text('2. test c')).dy),
      );
      expect(
        tester.getTopLeft(find.text('2. test c')).dy,
        lessThan(tester.getTopLeft(find.text('3. Test 42')).dy),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('start-route')))
            .onPressed,
        isNotNull,
      );
      expect(find.text('Start pickup'), findsNothing);
      expect(find.textContaining('Planned arrival:'), findsNWidgets(3));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Complete pickup').first,
            )
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('route-diagnostics')), findsNothing);
      expect(find.textContaining('ATTESTED'), findsNothing);
      expect(find.textContaining('synthetic-route'), findsNothing);
      expect(find.textContaining('synthetic-snapshot'), findsNothing);
      expect(find.textContaining('synthetic-candidate'), findsNothing);
      expect(find.textContaining('1755847853'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(data['departure_at'], originalDeparture);
      expect((data['stops'] as List).first['pickup_address'], originalAddress);
      expect(calls, ['get_my_authorized_route', 'get_my_claim_cards_v2']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final allowed in [false, true]) {
    testWidgets('completion still requires protected authority: $allowed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final data = fixture(authority: allowed, start: false, complete: true);
      data['actual_started_at'] = '2026-10-28T17:00:01Z';
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, _) async {
          if (name == 'get_my_claim_cards_v2') return activeClaimCards(data);
          expect(name, 'get_my_authorized_route');
          return data;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRouteDetailPage(
            routeId: 'synthetic-route',
            repository: repo,
            mapBuilder: (_) => const SizedBox(height: 40),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Actual pickup start: 29 Oct 2026, 01:00 MYT'),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Complete pickup').first,
      );
      expect(button.onPressed, allowed ? isNotNull : isNull);
      expect(find.byKey(const Key('start-route')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(
                FilledButton,
                'Confirm depot return and close route',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('direct route stop location is hidden at lease expiry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = fixture();
    final leaseExpiresAt = DateTime.utc(2030, 1, 1, 0, 0, 6);
    var cardReads = 0;
    final calls = <String>[];
    Set<Marker> markers = {};
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (name, _) async {
        calls.add(name);
        if (name == 'get_my_claim_cards_v2') {
          final firstRead = cardReads++ == 0;
          return activeClaimCards(
            data,
            leaseExpiresAt: leaseExpiresAt,
            serverNow: firstRead
                ? leaseExpiresAt.subtract(const Duration(seconds: 6))
                : leaseExpiresAt,
          );
        }
        expect(name, 'get_my_authorized_route');
        return data;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NgoRouteDetailPage(
          routeId: 'synthetic-route',
          repository: repo,
          mapBuilder: (value) {
            markers = value;
            return const SizedBox(height: 80);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(cleanAddress), findsWidgets);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text(cleanAddress), findsNothing);
    expect(
      markers.where((marker) => marker.markerId.value.startsWith('pickup')),
      isEmpty,
    );
    expect(
      calls.where((name) => name == 'get_my_authorized_route').length,
      greaterThan(1),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
