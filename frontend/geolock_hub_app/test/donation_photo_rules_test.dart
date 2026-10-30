import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/donation_photo_rules.dart';

void main() {
  group('DonationPhotoRules', () {
    test('new donation needs one to three photos', () {
      expect(DonationPhotoRules.validPhotoCount(0), isFalse);
      expect(DonationPhotoRules.validPhotoCount(1), isTrue);
      expect(DonationPhotoRules.validPhotoCount(3), isTrue);
      expect(DonationPhotoRules.validPhotoCount(4), isFalse);
    });

    test('title is required and limited to 80 characters', () {
      expect(DonationPhotoRules.titleError('  '), isNotNull);
      expect(DonationPhotoRules.titleError('Chair'), isNull);
      expect(DonationPhotoRules.titleError('x' * 81), isNotNull);
    });

    test('description is required and limited to 1000 characters', () {
      expect(DonationPhotoRules.descriptionError(''), isNotNull);
      expect(DonationPhotoRules.descriptionError('   '), isNotNull);
      expect(DonationPhotoRules.descriptionError('Condition details'), isNull);
      expect(DonationPhotoRules.descriptionError('x' * 1001), isNotNull);
    });

    test('chosen cover is moved to the first display position', () {
      expect(
        DonationPhotoRules.withCoverFirst(['cover2', 'photo2', 'photo3'], 1),
        ['photo2', 'cover2', 'photo3'],
      );
    });

    test('creation RPC payload has no donor availability dates', () {
      final payload = DonationPhotoRules.createRpcPayload(
        requestId: 'request-id',
        title: '  Study desk  ',
        description: '  Minor scratches  ',
        pickupAddress: 'Pickup address',
        latitude: 3.1,
        longitude: 101.6,
        pickupRoadNodeId: null,
        items: const [
          {'category_id': 'category', 'quantity': 1, 'unit_weight_kg': 10},
        ],
        images: const [
          {
            'storage_path': 'staged/photo.jpg',
            'content_type': 'image/jpeg',
            'size_bytes': 100,
          },
        ],
      );
      expect(payload, isNot(contains('p_availability_start')));
      expect(payload, isNot(contains('p_availability_end')));
      expect(payload.keys.toSet(), {
        'p_request',
        'p_title',
        'p_description',
        'p_pickup_address',
        'p_latitude',
        'p_longitude',
        'p_pickup_road_node_id',
        'p_items',
        'p_images',
      });
      expect(payload['p_title'], 'Study desk');
      expect(payload['p_description'], 'Minor scratches');
    });
  });
}
