import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/auth/auth_pages.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/location/location_result.dart';
import 'package:geolock_hub_app/location/road_routing.dart';

void main() {
  testWidgets(
    'NGO signup collects organization details without a location picker',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: RegistrationPage(role: AccountRole.ngo)),
      );
      expect(find.text('NGO Organisation Name'), findsOneWidget);
      expect(
        find.text('Registration / Reference Number (optional)'),
        findsOneWidget,
      );
      expect(find.text('Operating Address and Map Pin'), findsNothing);
      expect(find.text('Select location'), findsNothing);
      expect(
        find.textContaining('after email verification and login'),
        findsOneWidget,
      );
    },
  );

  testWidgets('authenticated NGO location setup requires server road preview', (
    tester,
  ) async {
    var previewCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: buildNgoLocationPicker(
          initialLocation: const LocationResult(
            address: 'Test operating address',
            latitude: 3.1390,
            longitude: 101.6869,
            method: LocationSelectionMethod.mapPin,
          ),
          roadAccessCheck: (_, _) async {
            previewCalls++;
            return const RoadAccessResult(routable: true, snapDistanceM: 42);
          },
          requireRoadPreview: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(previewCalls, 1);
    expect(find.textContaining('42 m from a drivable road'), findsOneWidget);
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Confirm Location'),
    );
    expect(confirm.onPressed, isNotNull);
  });

  testWidgets('Hub Admin signup offers self-registration without hub details', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: RegistrationPage(role: AccountRole.hubAdmin)),
    );
    expect(find.textContaining('Community Hub Admin'), findsOneWidget);
    expect(find.text('Hub name'), findsNothing);
    expect(find.text('Operating Address and Map Pin'), findsNothing);
  });
  group('roadOutcomeMessage', () {
    const expected = {
      'OUTSIDE_GEOFENCE': 'More than 20 km from your NGO by road',
      'ROUTE_UNAVAILABLE': 'No drivable road route connects these locations',
      'ELIGIBILITY_UNDETERMINED':
          'Road eligibility has not been calculated yet; try again shortly',
      'CLAIM_CONFLICT': 'This listing is no longer available to claim',
      'LISTING_EXPIRED': 'This listing has expired',
      'LISTING_NOT_FOUND': 'This listing no longer exists or is not visible',
      'DONATION_NOT_READY': 'The donation is not ready for pickup',
      'BATCH_NOT_PUBLISHED': 'The hub batch has not been published yet',
    };

    for (final entry in expected.entries) {
      test(entry.key, () {
        expect(roadOutcomeMessage(entry.key), '${entry.value} (${entry.key})');
      });
    }

    test('unknown code keeps the raw code', () {
      expect(
        roadOutcomeMessage('SOMETHING_NEW'),
        'Unexpected server reason (SOMETHING_NEW)',
      );
    });

    test('missing code', () {
      expect(roadOutcomeMessage(null), 'The server gave no reason');
    });
  });

  testWidgets('hub location picker keeps Confirm disabled when not routable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: buildHubLocationPicker(
          initialLocation: const LocationResult(
            address: 'Hutan Simpan, Pahang',
            latitude: 3.7,
            longitude: 102.5,
            method: LocationSelectionMethod.mapPin,
          ),
          roadAccessCheck: (_, _) async => const RoadAccessResult(
            routable: false,
            reasonCode: 'NO_DRIVABLE_NODE_WITHIN_500M',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(hubLocationHint), findsOneWidget);
    expect(find.textContaining('No drivable road within 500 m'), findsOne);
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Confirm Location'),
    );
    expect(confirm.onPressed, isNull);
  });

  group('discovery card', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      required bool? capabilityReady,
      required String? routingStatus,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EligibleListingCard(
            listing: {
              'listing_id': 'l-1',
              'title': 'Rice bags',
              'listing_weight_kg': 12,
              'collection_path': 'DIRECT_PICKUP',
              'routing_status': routingStatus,
            },
            capabilityReady: capabilityReady,
            onOpen: () {},
          ),
        ),
      ),
    );

    testWidgets('shows the routing reason when status is not READY', (
      tester,
    ) async {
      await pumpCard(
        tester,
        capabilityReady: true,
        routingStatus: 'NOT_ROUTABLE',
      );
      expect(
        find.textContaining(
          'claiming unavailable: ${routingStatusExplanation('NOT_ROUTABLE')}',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('trusted road-node'), findsNothing);
      expect(find.text('Claim'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('shows inactive road network when capability is false', (
      tester,
    ) async {
      await pumpCard(tester, capabilityReady: false, routingStatus: 'READY');
      expect(
        find.textContaining('Road network is not active on the server'),
        findsOneWidget,
      );
      expect(find.text('Claim'), findsNothing);
    });

    testWidgets('missing status reads as unknown', (tester) async {
      await pumpCard(tester, capabilityReady: true, routingStatus: null);
      expect(find.textContaining('Road status unknown'), findsOneWidget);
    });

    testWidgets('tapping a listing invokes its detail navigation callback', (
      tester,
    ) async {
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EligibleListingCard(
              listing: const {
                'listing_id': 'l-1',
                'title': 'Rice bags',
                'listing_weight_kg': 12,
                'collection_path': 'DIRECT_PICKUP',
                'routing_status': 'READY',
              },
              capabilityReady: true,
              onOpen: () => opened = true,
            ),
          ),
        ),
      );
      await tester.tap(find.textContaining('Rice bags'));
      expect(opened, isTrue);
    });
  });
}
