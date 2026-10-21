import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/donation_status.dart';
import 'package:geolock_hub_app/status_timeline.dart';

void main() {
  test('actual direct states take precedence over listing and inventory', () {
    const expected = {
      'AVAILABLE': 'Available',
      'CLAIMED': 'Claimed',
      'PICKUP_IN_PROGRESS': 'Pickup in Progress',
      'COLLECTED': 'Collected',
      'CANCELLED': 'Cancelled',
    };
    for (final entry in expected.entries) {
      expect(
        donationStatusLabel(
          status: entry.key,
          collectionPath: 'DIRECT_PICKUP',
          listingStatus: 'CLAIMED',
          inventoryStatus: 'STORED',
        ),
        entry.value,
      );
    }
  });

  test('hub member lifecycle remains distinct from batch publication', () {
    const expected = {
      'SUBMITTED': 'Awaiting Hub Selection',
      'HUB_ASSIGNED': 'Awaiting Drop-off',
      'AT_HUB': 'At Hub',
      'BATCHED': 'Included in a Batch',
      'CLAIMED': 'Claimed',
      'PICKUP_IN_PROGRESS': 'Pickup in Progress',
      'COLLECTED': 'Collected',
    };
    for (final entry in expected.entries) {
      expect(
        donationStatusLabel(
          status: entry.key,
          collectionPath: 'HUB_COLLECTION',
          reservationStatus: 'ACTIVE',
          inventoryStatus: 'BATCHED',
          listingStatus: 'CLAIMED',
        ),
        entry.value,
      );
    }
  });

  test('direct and hub release restore the correct future milestones', () {
    expect(
      pendingDonationMilestones(
        collectionPath: 'DIRECT_PICKUP',
        currentStatus: 'AVAILABLE',
      ),
      ['Claimed', 'Pickup in Progress', 'Collected'],
    );
    expect(
      pendingDonationMilestones(
        collectionPath: 'HUB_COLLECTION',
        currentStatus: 'BATCHED',
      ),
      ['Claimed', 'Pickup in Progress', 'Collected'],
    );
    expect(
      pendingDonationMilestones(
        collectionPath: 'HUB_COLLECTION',
        currentStatus: 'CLAIMED',
      ),
      ['Pickup in Progress', 'Collected'],
    );
  });

  test('historical and current creation events remain readable', () {
    final events = recordedAuditEvents(
      [
        {
          'event_type': 'CREATE_VALIDATE',
          'resulting_state': 'READY_FOR_PICKUP',
        },
        {'event_type': 'CREATE_DONATION', 'resulting_state': 'AVAILABLE'},
        {'event_type': 'DONATION_STATUS_CHANGED', 'resulting_state': 'CLAIMED'},
      ],
      allowedEventTypes: const {
        'CREATE_VALIDATE',
        'CREATE_DONATION',
        'DONATION_STATUS_CHANGED',
      },
    );
    expect(events.map((event) => event.detail), [
      'Ready for Pickup',
      'Available',
      'Claimed',
    ]);
  });
}
