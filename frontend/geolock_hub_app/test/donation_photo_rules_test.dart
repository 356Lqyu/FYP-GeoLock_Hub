import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/donation_photo_rules.dart';

void main() {
  group('DonationPhotoRules', () {
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
  });

  group('DonationItemPhotoRules', () {
    test('photos are optional per item but at least one item needs one', () {
      expect(DonationItemPhotoRules.validItemPhotos([]), isFalse);
      expect(DonationItemPhotoRules.validItemPhotos([false]), isFalse);
      expect(DonationItemPhotoRules.validItemPhotos([false, false]), isFalse);
      expect(DonationItemPhotoRules.validItemPhotos([true]), isTrue);
      expect(DonationItemPhotoRules.validItemPhotos([false, true]), isTrue);
    });

    test('a donation keeps the 30-item maximum', () {
      expect(DonationItemPhotoRules.maxItems, 30);
      expect(
        DonationItemPhotoRules.validItemPhotos([
          true,
          ...List.filled(29, false),
        ]),
        isTrue,
      );
      expect(
        DonationItemPhotoRules.validItemPhotos([
          true,
          ...List.filled(30, false),
        ]),
        isFalse,
      );
    });

    test('creation payload gives each item its form position and photo', () {
      final photo = {
        'storage_path': 'donor/pending/request/photo.jpg',
        'content_type': 'image/jpeg',
        'size_bytes': 100,
      };
      final payload = DonationItemPhotoRules.createRpcPayload(
        requestId: 'request-id',
        title: '  Study desk  ',
        description: '  Minor scratches  ',
        pickupAddress: 'Pickup address',
        latitude: 3.1,
        longitude: 101.6,
        pickupRoadNodeId: null,
        items: [
          {'item_name': 'Rice', 'quantity': 1},
          {'item_name': 'Notebooks', 'quantity': 2, 'photo': photo},
          {'item_name': 'Clothes', 'quantity': 3},
        ],
      );
      expect(payload.keys.toSet(), {
        'p_request',
        'p_title',
        'p_description',
        'p_pickup_address',
        'p_latitude',
        'p_longitude',
        'p_items',
        'p_pickup_road_node_id',
      });
      expect(payload, isNot(contains('p_images')));
      expect(payload['p_title'], 'Study desk');
      expect(payload['p_description'], 'Minor scratches');
      final items = payload['p_items'] as List;
      expect([for (final item in items) item['item_position']], [1, 2, 3]);
      expect(
        [for (final item in items) item['item_name']],
        ['Rice', 'Notebooks', 'Clothes'],
      );
      expect(items[0], isNot(contains('photo')));
      expect(items[1]['photo'], photo);
      expect(items[2], isNot(contains('photo')));
    });

    test('blank description is sent as null', () {
      final payload = DonationItemPhotoRules.createRpcPayload(
        requestId: 'r',
        title: 'T',
        description: '   ',
        pickupAddress: 'A',
        latitude: 0,
        longitude: 0,
        pickupRoadNodeId: null,
        items: const [{}],
      );
      expect(payload['p_description'], isNull);
    });

    test('item photo detection also counts photos whose path is withheld', () {
      expect(DonationItemPhotoRules.hasItemPhotos([]), isFalse);
      expect(
        DonationItemPhotoRules.hasItemPhotos([
          {'photo_image_id': null, 'photo_path': null},
        ]),
        isFalse,
      );
      expect(
        DonationItemPhotoRules.hasItemPhotos([
          {'photo_image_id': 'img-1', 'photo_path': null},
        ]),
        isTrue,
      );
      expect(
        DonationItemPhotoRules.hasItemPhotos([
          {'photo_path': 'a.jpg'},
        ]),
        isTrue,
      );
    });

    test('legacy donations keep their gallery unchanged', () {
      final rows = [
        {'item_id': 'i1', 'photo_image_id': null, 'photo_path': null},
      ];
      expect(
        DonationItemPhotoRules.legacyGalleryPaths(['a.jpg', 'b.jpg'], rows),
        ['a.jpg', 'b.jpg'],
      );
      expect(DonationItemPhotoRules.legacyGalleryPaths(['a.jpg'], []), [
        'a.jpg',
      ]);
      expect(DonationItemPhotoRules.legacyGalleryPaths([], rows), isEmpty);
    });

    test('item-photo donations show no duplicate gallery', () {
      final rows = [
        {'photo_image_id': null, 'photo_path': null},
        {'photo_image_id': 'img-2', 'photo_path': 'item2.jpg'},
        {'photo_image_id': 'img-3', 'photo_path': 'item3.jpg'},
      ];
      expect(
        DonationItemPhotoRules.legacyGalleryPaths([
          'item2.jpg',
          'item3.jpg',
          'item2.jpg',
        ], rows),
        isNull,
      );
      // A hub batch photo is not an item photo, so it stays in the gallery.
      expect(
        DonationItemPhotoRules.legacyGalleryPaths([
          'batch/cover.jpg',
          'item2.jpg',
        ], rows),
        ['batch/cover.jpg'],
      );
    });

    test(
      'item photos attach to detail items by id, in stored position order',
      () {
        final merged = DonationItemPhotoRules.attachPhotos(
          [
            {'item_id': 'b', 'item_name': 'Notebooks', 'category_id': 'c2'},
            {'item_id': 'a', 'item_name': 'Rice', 'category_id': 'c1'},
            {'item_id': 'c', 'item_name': 'Clothes', 'category_id': 'c3'},
          ],
          [
            {'item_id': 'a', 'item_position': 1, 'photo_image_id': null},
            {
              'item_id': 'b',
              'item_position': 2,
              'photo_image_id': 'img-b',
              'photo_path': 'b.jpg',
            },
            {
              'item_id': 'c',
              'item_position': 3,
              'photo_image_id': 'img-c',
              'photo_path': 'c.jpg',
            },
          ],
        );
        expect(
          [for (final item in merged) item['item_name']],
          ['Rice', 'Notebooks', 'Clothes'],
        );
        expect(
          [for (final item in merged) item['photo_path']],
          [null, 'b.jpg', 'c.jpg'],
        );
        // Donate Again still has each item's category.
        expect(merged.first['category_id'], 'c1');
      },
    );

    test('legacy items without positions keep their original order', () {
      final merged = DonationItemPhotoRules.attachPhotos(
        [
          {'item_id': 'x', 'item_name': 'First'},
          {'item_id': 'y', 'item_name': 'Second'},
        ],
        [
          {'item_id': 'y', 'item_position': null, 'photo_image_id': null},
          {'item_id': 'x', 'item_position': null, 'photo_image_id': null},
        ],
      );
      expect(
        [for (final item in merged) item['item_name']],
        ['First', 'Second'],
      );
      expect(merged.every((item) => item['photo_path'] == null), isTrue);
    });
  });
}
