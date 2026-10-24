import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/status_timeline.dart';

void main() {
  test('direct and hub collection reservation visibility is path-specific', () {
    expect(shouldShowHubReservationSection('DIRECT_PICKUP'), isFalse);
    expect(shouldShowHubReservationSection('HUB_COLLECTION'), isTrue);
    expect(shouldShowHubReservationSection(null), isFalse);
  });

  test('pending donation milestones do not invent completed timestamps', () {
    final pending = pendingDonationMilestones(
      collectionPath: 'DIRECT_PICKUP',
      currentStatus: 'AVAILABLE',
    );
    expect(pending, ['Claimed', 'Pickup in Progress', 'Collected']);
  });

  test('terminal statuses have no future milestones', () {
    expect(
      pendingDonationMilestones(
        collectionPath: 'HUB_COLLECTION',
        currentStatus: 'CANCELLED',
      ),
      isEmpty,
    );
    expect(
      pendingDonationMilestones(
        collectionPath: 'HUB_COLLECTION',
        currentStatus: 'COLLECTED',
      ),
      isEmpty,
    );
  });

  test(
    'expired or unknown active reservation is not presented as confirmed',
    () {
      expect(
        reservationStatusLabel(
          recordedStatus: 'ACTIVE',
          effectiveStatus: null,
          isLatest: true,
        ),
        contains('validity not available'),
      );
      expect(
        reservationStatusLabel(
          recordedStatus: 'ACTIVE',
          effectiveStatus: 'EXPIRED',
          isLatest: true,
        ),
        'Expired',
      );
    },
  );

  testWidgets('timeline marks future milestones Pending without timestamps', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GeoStatusTimeline(
            title: 'Donation Progress',
            currentStatus: 'Ready for Pickup',
            pendingMilestones: ['Pickup in Progress', 'Collected'],
          ),
        ),
      ),
    );
    expect(find.text('Current status · Ready for Pickup'), findsOneWidget);
    expect(find.text('Pickup in Progress'), findsOneWidget);
    expect(find.text('Collected'), findsOneWidget);
    expect(find.text('Pending'), findsNWidgets(2));
  });

  testWidgets('timeline keeps current status visible when history fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GeoStatusTimeline(
            title: 'Claim History',
            currentStatus: 'Needs Reconciliation',
            errorMessage: 'History could not be loaded.',
          ),
        ),
      ),
    );
    expect(find.text('Current status · Needs Reconciliation'), findsOneWidget);
    expect(find.text('History could not be loaded.'), findsOneWidget);
  });

  test(
    'audit event projection allowlists event types and hides raw details',
    () {
      final events = recordedAuditEvents(
        [
          {
            'event_type': 'START_PICKUP',
            'occurred_at': '2026-10-19T02:30:00Z',
            'resulting_state': 'PICKUP_IN_PROGRESS',
            'details': {'private': 'must not render'},
          },
          {
            'event_type': 'DONOR_PRIVATE_DATA',
            'occurred_at': '2026-10-19T02:31:00Z',
            'details': {'private': 'must not render'},
          },
        ],
        allowedEventTypes: const {'START_PICKUP'},
      );
      expect(events, hasLength(1));
      expect(events.single.title, 'Pickup started');
      expect(events.single.detail, 'Pickup in Progress');
      expect(events.single.occurredAt, isNotNull);
    },
  );
}
