import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/location/location_result.dart';
import 'package:geolock_hub_app/location/road_routing.dart';

void main() {
  group('roadOutcomeMessage', () {
    const expected = {
      'OUTSIDE_GEOFENCE': 'More than 20 km from your NGO by road',
      'ROUTE_UNAVAILABLE': 'No drivable road route connects these locations',
      'ELIGIBILITY_UNDETERMINED':
          'Road eligibility has not been calculated yet; try again shortly',
      'CLAIM_CONFLICT': 'Another NGO has already claimed this listing',
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
            onClaim: () {},
            onOpen: () {},
          ),
        ),
      ),
    );

    FilledButton claimButton(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byType(FilledButton));

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
          'Claim unavailable: ${routingStatusExplanation('NOT_ROUTABLE')}',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('trusted road-node'), findsNothing);
      expect(claimButton(tester).onPressed, isNull);
    });

    testWidgets('shows inactive road network when capability is false', (
      tester,
    ) async {
      await pumpCard(tester, capabilityReady: false, routingStatus: 'READY');
      expect(
        find.textContaining('Road network is not active on the server'),
        findsOneWidget,
      );
      expect(claimButton(tester).onPressed, isNull);
    });

    testWidgets('missing status reads as unknown', (tester) async {
      await pumpCard(tester, capabilityReady: true, routingStatus: null);
      expect(find.textContaining('Road status unknown'), findsOneWidget);
    });

    testWidgets('READY with active network can be claimed', (tester) async {
      await pumpCard(tester, capabilityReady: true, routingStatus: 'READY');
      expect(find.text('Claim'), findsOneWidget);
      expect(claimButton(tester).onPressed, isNotNull);
    });
  });
}
