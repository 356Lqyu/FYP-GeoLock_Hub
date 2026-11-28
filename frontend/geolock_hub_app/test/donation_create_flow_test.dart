import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/donation_collection_path.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/donation_photo_errors.dart';
import 'package:geolock_hub_app/donation_photo_rules.dart';
import 'package:geolock_hub_app/location/location_picker_page.dart';
import 'package:geolock_hub_app/location/location_result.dart';
import 'package:geolock_hub_app/location/road_routing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

double _total(int quantity, double unitWeightKg) => donationTotalWeightKg([
  (quantity: quantity, unitWeightGrams: (unitWeightKg * 1000).round()),
])!;

void main() {
  test('collection labels distinguish donation paths from listing sources', () {
    expect(collectionPathBadgeLabel('DIRECT_HOUSEHOLD'), 'Direct Pickup');
    expect(collectionPathBadgeLabel('COMMUNITY_HUB'), 'Hub Collection');
    expect(collectionPathBadgeLabel('DIRECT_PICKUP'), 'Direct Pickup');
    expect(collectionPathBadgeLabel('HUB_COLLECTION'), 'Hub Collection');
    expect(
      collectionPathBadgeLabel(null, listingSourceType: 'DIRECT_DONATION'),
      'Direct Pickup',
    );
    expect(
      collectionPathBadgeLabel(null, listingSourceType: 'HUB_BATCH'),
      'Hub Collection',
    );
    expect(
      collectionPathBadgeLabel(
        'COMMUNITY_HUB',
        listingSourceType: 'DIRECT_DONATION',
      ),
      'Hub Collection',
    );
    expect(
      collectionPathBadgeLabel(
        'UNKNOWN_PATH',
        listingSourceType: 'DIRECT_DONATION',
      ),
      isNull,
    );
    expect(collectionPathBadgeLabel('HUB_BATCH'), isNull);
    expect(collectionPathBadgeLabel('DIRECT_DONATION'), isNull);
    expect(
      collectionPathBadgeLabel(null, listingSourceType: 'DIRECT_PICKUP'),
      isNull,
    );
    expect(
      collectionPathBadgeLabel(null, listingSourceType: 'UNKNOWN_SOURCE'),
      isNull,
    );
  });

  group('weight → collection path preview', () {
    test('9.9 kg previews community hub', () {
      final total = _total(99, 0.1);
      expect(total, 9.9);
      expect(previewCollectionPath(total), 'HUB_COLLECTION');
      expect(
        collectionPathPreviewText(total),
        'Total 9.9 kg → Community hub: you will drop it at a hub you choose',
      );
    });

    test('10.0 kg previews direct pickup (threshold is inclusive)', () {
      final total = _total(100, 0.1);
      expect(total, 10.0);
      expect(previewCollectionPath(total), 'DIRECT_PICKUP');
      expect(
        collectionPathPreviewText(total),
        'Total 10.0 kg → Direct pickup: an NGO will collect from your location',
      );
    });

    test('10.1 kg previews direct pickup', () {
      final total = _total(101, 0.1);
      expect(total, 10.1);
      expect(previewCollectionPath(total), 'DIRECT_PICKUP');
    });

    test('sums several items and withholds an incomplete total', () {
      const items = [
        (quantity: 3, unitWeightGrams: 2500),
        (quantity: 2, unitWeightGrams: 1250),
      ];
      expect(donationTotalWeightKg(items), 10.0);
      expect(
        donationTotalWeightKg([
          ...items,
          (quantity: null, unitWeightGrams: 4000),
        ]),
        isNull,
      );
    });

    test('rounds unit weights before multiplying by quantity', () {
      expect(parseDonationUnitWeight('0.0004').grams, isNull);
      expect(parseDonationUnitWeight('0.0005').grams, 1);
      expect(parseDonationUnitWeight('0.0015').grams, 2);
      expect(parseDonationUnitWeight('0.5005').grams, 501);
      expect(parseDonationUnitWeight('5.005e-1').grams, 501);
      expect(collectionPathPreviewText(9.999), contains('9.999 kg'));
      expect(parseDonationQuantity('1.5'), isNull);
      expect(parseDonationQuantity('2147483648'), isNull);
    });

    test(
      'bounds scientific notation and decimal rounding without throwing',
      () {
        const invalid = 'Enter a valid unit weight.';
        const tooSmall = 'Unit weight must be at least 0.001 kg.';
        final huge = '9' * 20000;
        final zeros = '0' * 20000;
        for (final input in [
          huge,
          '1e$huge',
          '1e+$huge',
          '${huge}x',
          '1e',
          '1e+-3',
          '.',
          '+.',
          '1.2.3',
          '1 2',
          '0x10',
          '+NaN',
          '-Infinity',
          '999999999.9995',
          '1e9',
        ]) {
          expect(parseDonationUnitWeight(input), (grams: null, error: invalid));
        }
        for (final input in ['1e-$huge', '0.00049999999999999999999']) {
          expect(parseDonationUnitWeight(input), (
            grams: null,
            error: tooSmall,
          ));
        }
        for (final (input, grams) in [
          ('0.00050000000000000000000', 1),
          ('0.50049999999999999999999', 500),
          ('0.50050000000000000000000', 501),
          ('999999999.99949999999999999999999', 999999999999),
          ('  +.5e+${zeros}0  ', 500),
          ('1${zeros}e-20000', 1000),
          ('0.${zeros}1e20001', 1000),
        ]) {
          expect(parseDonationUnitWeight(input), (grams: grams, error: null));
        }
      },
    );

    testWidgets('preview card labels itself as a preview', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: CollectionPathPreviewCard(totalKg: 12)),
        ),
      );
      expect(
        find.text(
          'Total 12.0 kg → Direct pickup: an NGO will collect from your location',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Preview'), findsOneWidget);
    });
  });

  testWidgets('donation form validates continuously and submits once', (
    tester,
  ) async {
    const categoryId = 'ea085f22-e2d4-4fa0-93db-e516b12b8c28';
    const actor = '353ddd38-30e5-44b5-a5b1-044f7bda725e';
    const photoId = 'ebce111c-314e-4933-80f1-b370df3b9c44';
    final storageList = Completer<http.Response>();
    var storageCalls = 0;
    final submissions = <Map<String, dynamic>>[];
    http.Response jsonResponse(
      Object value, {
      int status = 200,
      http.Request? request,
    }) => http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json'},
      request: request,
    );

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await _initOfflineSupabase(tester, (request) async {
      final path = request.url.path;
      if (path.endsWith('/token')) {
        final payload = base64Url
            .encode(
              utf8.encode(
                jsonEncode({
                  'sub': actor,
                  'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                }),
              ),
            )
            .replaceAll('=', '');
        return jsonResponse({
          'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'offline-test-refresh',
          'user': {'id': actor, 'app_metadata': {}, 'user_metadata': {}},
        });
      }
      if (path.endsWith('/get_active_donation_categories')) {
        return jsonResponse([
          {'category_id': categoryId, 'category_name': 'Clothing'},
        ], request: request);
      }
      if (path.contains('/object/list/')) {
        storageCalls++;
        return storageList.future;
      }
      if (path.endsWith('/create_donation_with_item_photos')) {
        submissions.add(jsonDecode(request.body) as Map<String, dynamic>);
        return jsonResponse(
          {'message': 'INVALID_DONATION_ITEM'},
          status: 400,
          request: request,
        );
      }
      throw StateError('Unexpected mock request: $path');
    }, signIn: true);
    await tester.pumpWidget(const MaterialApp(home: CreateDonationPage()));
    final page = find.byType(CreateDonationPage);
    final dynamic state = tester.state(page);
    await tester.runAsync(() async {
      await (state.categories as Future<List<DonationCategory>>).timeout(
        const Duration(seconds: 5),
      );
    });
    await tester.pumpAndSettle();

    FilledButton submitButton() =>
        tester.widget<FilledButton>(find.byType(FilledButton));
    Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    Future<void> edit(String label, String value) async {
      await tester.enterText(field(label), value);
      await tester.pump();
    }

    expect(submitButton().onPressed, isNull);
    await edit('Donation title', 'Clothes');
    expect(submitButton().onPressed, isNull);
    await edit('Description', 'Clean and packed');
    await edit('Item name', 'Shirts');

    // Provide the outputs of the device photo picker and confirmed map picker.
    state.items.single.photo = DonationPhotoSelection(
      id: photoId,
      file: XFile('web/icons/Icon-192.png'),
    );
    state.pickupLocation = const LocationResult(
      address: 'Test pickup',
      latitude: 3.1,
      longitude: 101.6,
      method: LocationSelectionMethod.mapPin,
      roadAccess: RoadAccessResult(routable: true),
    );
    await edit('Quantity', '2');
    expect(submitButton().onPressed, isNull);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clothing').last);
    await tester.pumpAndSettle();
    final staleSubmit = submitButton().onPressed!;

    await edit('Description', '');
    expect(submitButton().onPressed, isNull);
    staleSubmit();
    expect(storageCalls, 0);
    await edit('Description', 'Clean and packed');
    await edit('Quantity', '0');
    expect(submitButton().onPressed, isNull);
    await edit('Quantity', '2');

    for (final (value, message) in [
      ('', 'Enter the unit weight in kg.'),
      ('0', 'Unit weight must be greater than 0 kg.'),
      ('-1', 'Unit weight must be greater than 0 kg.'),
      ('abc', 'Enter a valid unit weight.'),
      ('NaN', 'Enter a valid unit weight.'),
      ('Infinity', 'Enter a valid unit weight.'),
      ('0.0004', 'Unit weight must be at least 0.001 kg.'),
    ]) {
      await edit('Unit weight (kg)', value);
      expect(submitButton().onPressed, isNull, reason: value);
      expect(find.text(message), findsOneWidget);
      expect(
        tester
            .widget<CollectionPathPreviewCard>(
              find.byType(CollectionPathPreviewCard),
            )
            .totalKg,
        isNull,
      );
    }
    expect(storageCalls, 0);
    expect(submissions, isEmpty);

    for (final (weight, total) in [
      ('4.95', 9.9),
      ('5', 10.0),
      ('5.05', 10.1),
    ]) {
      await edit('Unit weight (kg)', weight);
      expect(submitButton().onPressed, isNotNull);
      expect(find.text(collectionPathPreviewText(total)), findsOneWidget);
    }

    await tester.tap(find.text('Add another item'));
    await tester.pump();
    expect(submitButton().onPressed, isNull);
    // The new item is marked as needing a photo; item 1 already has one.
    expect(find.text('Add a photo to item 2.'), findsOneWidget);
    expect(find.text('Photo required'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pump();
    expect(find.text('Photo required'), findsNothing);
    final submit = submitButton().onPressed!;
    submit();
    submit();
    await tester.pump();
    expect(submitButton().onPressed, isNull);
    expect(find.text('Saving...'), findsOneWidget);
    expect(storageCalls, 1);
    storageList.complete(
      jsonResponse([
        {'name': '$photoId.png', 'id': photoId},
      ]),
    );
    for (var attempt = 0; submissions.isEmpty && attempt < 30; attempt++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
    }
    await tester.pumpAndSettle();
    expect(submissions, hasLength(1));
    final sent = submissions.single;
    final sentItem = (sent['p_items'] as List).single as Map;
    expect(sentItem['unit_weight_kg'], 5.05);
    expect(sentItem['item_position'], 1);
    expect(sent, isNot(contains('p_images')));
    final sentPhoto = sentItem['photo'] as Map;
    expect(
      sentPhoto['storage_path'],
      '$actor/pending/${sent['p_request']}/$photoId.png',
    );
    expect(sentPhoto['content_type'], 'image/png');
    expect(sentPhoto['size_bytes'], isA<int>());
    expect(submitButton().onPressed, isNotNull);

    // A retry of the same form reuses the request ID (idempotent on the server).
    submitButton().onPressed!();
    for (var attempt = 0; submissions.length < 2 && attempt < 30; attempt++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
    }
    await tester.pumpAndSettle();
    expect(submissions, hasLength(2));
    expect(submissions[1]['p_request'], sent['p_request']);
    expect(submissions[1]['p_items'], sent['p_items']);

    // Removing the item's photo blocks submission and starts a new request.
    final requestBefore = state.createRequestId as String;
    await tester.tap(find.byTooltip('Remove item photo'));
    await tester.pump();
    expect(state.items.single.photo, isNull);
    expect(state.createRequestId, isNot(requestBefore));
    expect(find.text('Add a photo to item 1.'), findsOneWidget);
    expect(find.text('Photo required'), findsOneWidget);
    expect(submitButton().onPressed, isNull);

    // Choosing a replacement photo enables Submit again (all other fields valid).
    state.items.single.photo = DonationPhotoSelection(
      id: '2f1b7a52-35a3-4a43-8d0c-2a0f2a7f6c11',
      file: XFile('web/icons/Icon-512.png'),
    );
    await edit('Description', 'Clean and packed, new photo');
    expect(find.text('Photo required'), findsNothing);
    expect(find.text('Add a photo to item 1.'), findsNothing);
    expect(submitButton().onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Donate Again copies each item photo to its item and waits for '
      'fresh location confirmation', (tester) async {
    const activeCategory = 'ea085f22-e2d4-4fa0-93db-e516b12b8c28';
    final copy = Completer<List<DonationPhotoSelection>>();
    final copiedPaths = <String>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await _initOfflineSupabase(tester, (request) async {
      final path = request.url.path;
      if (path.endsWith('/get_active_donation_categories')) {
        return http.Response(
          jsonEncode([
            {'category_id': activeCategory, 'category_name': 'Clothing'},
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      throw StateError('Unexpected mock request: $path');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: CreateDonationPage(
          photoCopier: (paths) {
            copiedPaths.addAll(paths);
            return copy.future;
          },
          copyFrom: const {
            'title': 'Packed clothes',
            'description': 'Clean and ready',
            'latitude': 3.1,
            'longitude': 101.6,
            'pickup_address': 'Prior pickup',
            'items': [
              {
                'item_name': 'Shirts',
                'quantity': 2,
                'unit_weight_kg': 5,
                'category_id': 'inactive-category',
                'photo_path': 'donor/old-item-photo.png',
              },
            ],
            'images': [
              {'storage_path': 'donor/old-item-photo.png'},
            ],
          },
        ),
      ),
    );
    final dynamic state = tester.state(find.byType(CreateDonationPage));
    await tester.runAsync(() async {
      await (state.categories as Future<List<DonationCategory>>).timeout(
        const Duration(seconds: 5),
      );
    });
    await tester.pumpAndSettle();
    expect(copiedPaths, ['donor/old-item-photo.png']);
    expect(find.textContaining('Copying item photos'), findsOneWidget);
    expect(state.title.text, 'Packed clothes');
    expect(state.items.single.name.text, 'Shirts');
    expect(state.items.single.category, isNull);
    expect(state.pickupLocation.address, 'Prior pickup');
    expect(state.pickupLocation.roadAccess, isNull);
    FilledButton submitButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Submit Donation'),
    );
    expect(submitButton().onPressed, isNull);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clothing').last);
    await tester.pumpAndSettle();
    expect(find.text(collectionPathPreviewText(10)), findsOneWidget);

    final priorLocation = state.pickupLocation as LocationResult;
    // While the item photo is still copying, nothing can be submitted and the
    // item's photo button stays disabled.
    state.pickupLocation = const LocationResult(
      address: 'Confirmed pickup',
      latitude: 3.1,
      longitude: 101.6,
      method: LocationSelectionMethod.mapPin,
      roadAccess: RoadAccessResult(routable: true),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Donation title'),
      'Packed clothes updated',
    );
    await tester.pump();
    expect(submitButton().onPressed, isNull);
    expect(_photoButton(tester, 'Add item photo').onPressed, isNull);
    state.pickupLocation = priorLocation;

    final copiedPhoto = DonationPhotoSelection(
      id: 'new-copy',
      file: XFile('web/icons/Icon-192.png'),
    );
    copy.complete([copiedPhoto]);
    await tester.pumpAndSettle();
    expect(state.items.single.photo, copiedPhoto);
    expect(find.text('Item photo'), findsOneWidget);
    expect(submitButton().onPressed, isNull);

    state.pickupLocation = const LocationResult(
      address: 'Confirmed pickup',
      latitude: 3.1,
      longitude: 101.6,
      method: LocationSelectionMethod.mapPin,
      roadAccess: RoadAccessResult(routable: true),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Donation title'),
      'Packed clothes ready',
    );
    await tester.pumpAndSettle();
    expect(submitButton().onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Donate Again from a legacy donation copies items only', (
    tester,
  ) async {
    const category = 'ea085f22-e2d4-4fa0-93db-e516b12b8c28';
    final copiedPaths = <String>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await _initOfflineSupabase(tester, (request) async {
      if (request.url.path.endsWith('/get_active_donation_categories')) {
        return _json([
          {'category_id': category, 'category_name': 'Clothing'},
        ], request: request);
      }
      throw StateError('Unexpected mock request: ${request.url.path}');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: CreateDonationPage(
          photoCopier: (paths) async {
            copiedPaths.addAll(paths);
            return const [];
          },
          copyFrom: const {
            'title': 'Old clothes',
            'description': 'Clean',
            'latitude': 3.1,
            'longitude': 101.6,
            'pickup_address': 'Prior pickup',
            // A donation made before item photos: its photos belong to no item.
            'items': [
              {
                'item_id': 'legacy-item',
                'item_name': 'Shirts',
                'quantity': 2,
                'unit_weight_kg': 5,
                'category_id': category,
                'item_position': null,
                'photo_image_id': null,
                'photo_path': null,
              },
            ],
            'images': [
              {'storage_path': 'donor/legacy-donation-photo.png'},
            ],
          },
        ),
      ),
    );
    final dynamic state = tester.state(find.byType(CreateDonationPage));
    await tester.runAsync(() async {
      await (state.categories as Future<List<DonationCategory>>).timeout(
        const Duration(seconds: 5),
      );
    });
    await tester.pumpAndSettle();
    expect(copiedPaths, isEmpty);
    expect(state.copyingPhotos, isFalse);
    expect(state.items.single.name.text, 'Shirts');
    expect(state.items.single.photo, isNull);
    expect(find.textContaining('Its photos are not copied'), findsOneWidget);
    expect(find.textContaining('add a photo to every item'), findsOneWidget);
    expect(find.text('Add a photo to item 1.'), findsOneWidget);
    expect(find.text('Photo required'), findsOneWidget);
    expect(_photoButton(tester, 'Add item photo').onPressed, isNotNull);

    FilledButton submitButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Submit Donation'),
    );
    state.pickupLocation = const LocationResult(
      address: 'Confirmed pickup',
      latitude: 3.1,
      longitude: 101.6,
      method: LocationSelectionMethod.mapPin,
      roadAccess: RoadAccessResult(routable: true),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Donation title'),
      'Old clothes again',
    );
    await tester.pump();
    expect(submitButton().onPressed, isNull);
    state.items.single.photo = DonationPhotoSelection(
      id: 'new-item-photo',
      file: XFile('web/icons/Icon-192.png'),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Donation title'),
      'Old clothes, new photo',
    );
    await tester.pump();
    expect(submitButton().onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Donate Again asks for a replacement when an item photo cannot '
      'be copied', (tester) async {
    const category = 'ea085f22-e2d4-4fa0-93db-e516b12b8c28';
    final copiedPaths = <String>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await _initOfflineSupabase(tester, (request) async {
      if (request.url.path.endsWith('/get_active_donation_categories')) {
        return _json([
          {'category_id': category, 'category_name': 'Clothing'},
        ], request: request);
      }
      throw StateError('Unexpected mock request: ${request.url.path}');
    });
    final copiedShirt = DonationPhotoSelection(
      id: 'copied-shirt',
      file: XFile('web/icons/Icon-192.png'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CreateDonationPage(
          // The shirt photo copies; the trousers photo can no longer be read.
          photoCopier: (paths) async {
            copiedPaths.addAll(paths);
            return paths.single.endsWith('shirt.png') ? [copiedShirt] : [];
          },
          copyFrom: const {
            'title': 'Clothes',
            'description': 'Clean',
            'latitude': 3.1,
            'longitude': 101.6,
            'pickup_address': 'Prior pickup',
            'items': [
              {
                'item_name': 'Shirts',
                'quantity': 2,
                'unit_weight_kg': 1,
                'category_id': category,
                'item_position': 1,
                'photo_path': 'donor/item-shirt.png',
              },
              {
                'item_name': 'Trousers',
                'quantity': 1,
                'unit_weight_kg': 1,
                'category_id': category,
                'item_position': 2,
                'photo_path': 'donor/item-trousers.png',
              },
            ],
          },
        ),
      ),
    );
    final dynamic state = tester.state(find.byType(CreateDonationPage));
    await tester.runAsync(() async {
      await (state.categories as Future<List<DonationCategory>>).timeout(
        const Duration(seconds: 5),
      );
    });
    await tester.pumpAndSettle();
    expect(copiedPaths, ['donor/item-shirt.png', 'donor/item-trousers.png']);
    expect(state.copyingPhotos, isFalse);
    // Each copied photo stays with its own item; the failed one is missing.
    expect(state.items[0].photo, copiedShirt);
    expect(state.items[1].photo, isNull);
    expect(
      find.textContaining('1 item photo could not be copied'),
      findsOneWidget,
    );
    expect(find.text('Add a photo to item 2.'), findsOneWidget);
    expect(find.text('Photo required'), findsOneWidget);

    FilledButton submitButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Submit Donation'),
    );
    state.pickupLocation = const LocationResult(
      address: 'Confirmed pickup',
      latitude: 3.1,
      longitude: 101.6,
      method: LocationSelectionMethod.mapPin,
      roadAccess: RoadAccessResult(routable: true),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Donation title'),
      'Clothes again',
    );
    await tester.pump();
    expect(submitButton().onPressed, isNull);

    state.items[1].photo = DonationPhotoSelection(
      id: 'replacement-trousers',
      file: XFile('web/icons/Icon-512.png'),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Donation title'),
      'Clothes again, replacement photo',
    );
    await tester.pump();
    expect(find.text('Photo required'), findsNothing);
    expect(submitButton().onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('item photos keep their item order through edits and submit', (
    tester,
  ) async {
    const category = 'ea085f22-e2d4-4fa0-93db-e516b12b8c28';
    const actor = '353ddd38-30e5-44b5-a5b1-044f7bda725e';
    const ricePhoto = '5d0f6c1e-8b51-4a6c-9f53-1c2e3d4f5a6b';
    const notebookPhoto = '0f8fad5b-d9cb-469f-a165-70867728950e';
    const clothesPhoto = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
    final submissions = <Map<String, dynamic>>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 3200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await _initOfflineSupabase(tester, (request) async {
      final path = request.url.path;
      if (path.endsWith('/token')) return _token(actor, request);
      if (path.endsWith('/get_active_donation_categories')) {
        return _json([
          {'category_id': category, 'category_name': 'Clothing'},
        ], request: request);
      }
      if (path.contains('/object/list/')) {
        // All photos are already staged, as on a retry.
        return _json([
          {'name': '$ricePhoto.png', 'id': ricePhoto},
          {'name': '$notebookPhoto.png', 'id': notebookPhoto},
          {'name': '$clothesPhoto.png', 'id': clothesPhoto},
        ], request: request);
      }
      if (path.endsWith('/create_donation_with_item_photos')) {
        submissions.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _json(
          {'message': 'STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_2'},
          status: 400,
          request: request,
        );
      }
      throw StateError('Unexpected mock request: $path');
    }, signIn: true);
    await tester.pumpWidget(const MaterialApp(home: CreateDonationPage()));
    final dynamic state = tester.state(find.byType(CreateDonationPage));
    await tester.runAsync(() async {
      await (state.categories as Future<List<DonationCategory>>).timeout(
        const Duration(seconds: 5),
      );
    });
    await tester.pumpAndSettle();
    FilledButton submitButton() =>
        tester.widget<FilledButton>(find.byType(FilledButton));

    await tester.enterText(
      find.widgetWithText(TextField, 'Donation title'),
      'School and pantry',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Packed',
    );
    for (var added = 0; added < 2; added++) {
      await tester.tap(find.text('Add another item'));
      await tester.pump();
    }
    expect(state.items, hasLength(3));
    expect(find.text('Add item photo'), findsNWidgets(3));
    final names = ['Rice', 'Notebooks', 'Clothes'];
    for (var i = 0; i < 3; i++) {
      state.items[i].name.text = names[i];
      state.items[i].category = category;
    }
    state.pickupLocation = const LocationResult(
      address: 'Test pickup',
      latitude: 3.1,
      longitude: 101.6,
      method: LocationSelectionMethod.mapPin,
      roadAccess: RoadAccessResult(routable: true),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Donation title'),
      'School and pantry items',
    );
    await tester.pump();
    // Every item is complete, but no item has a photo yet.
    expect(submitButton().onPressed, isNull);

    expect(find.text('Add a photo to items 1, 2 and 3.'), findsOneWidget);
    expect(find.text('Photo required'), findsNWidgets(3));

    // Items 2 and 3 get photos; item 1 (Rice) still has none, so Submit stays off.
    state.items[1].photo = DonationPhotoSelection(
      id: notebookPhoto,
      file: XFile('web/icons/Icon-192.png'),
    );
    state.items[2].photo = DonationPhotoSelection(
      id: clothesPhoto,
      file: XFile('web/icons/Icon-512.png'),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Packed and labelled',
    );
    await tester.pump();
    expect(find.text('Add item photo'), findsOneWidget);
    expect(find.text('Item photo'), findsNWidgets(2));
    expect(find.text('Add a photo to item 1.'), findsOneWidget);
    expect(find.text('Photo required'), findsOneWidget);
    expect(submitButton().onPressed, isNull);

    // With a photo on every item, Submit is enabled.
    state.items[0].photo = DonationPhotoSelection(
      id: ricePhoto,
      file: XFile('web/icons/Icon-maskable-192.png'),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Packed, labelled and photographed',
    );
    await tester.pump();
    expect(find.text('Add item photo'), findsNothing);
    expect(find.text('Item photo'), findsNWidgets(3));
    expect(find.text('Photo required'), findsNothing);
    expect(submitButton().onPressed, isNotNull);

    Future<void> submitAndWait(int expected) async {
      submitButton().onPressed!();
      for (var i = 0; submissions.length < expected && i < 30; i++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
      }
      await tester.pumpAndSettle();
      expect(submissions, hasLength(expected));
    }

    await submitAndWait(1);
    final first = submissions.single;
    final items = (first['p_items'] as List).cast<Map>();
    expect([for (final item in items) item['item_position']], [1, 2, 3]);
    expect([for (final item in items) item['item_name']], names);
    expect(
      items[0]['photo']['storage_path'],
      '$actor/pending/${first['p_request']}/$ricePhoto.png',
    );
    expect(
      items[1]['photo']['storage_path'],
      '$actor/pending/${first['p_request']}/$notebookPhoto.png',
    );
    expect(
      items[2]['photo']['storage_path'],
      '$actor/pending/${first['p_request']}/$clothesPhoto.png',
    );
    // The server error names the item by its position.
    expect(find.textContaining('photo for item 2'), findsOneWidget);
    expect(
      find.textContaining('STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_2'),
      findsOneWidget,
    );

    // Removing item 1 renumbers the rest; the photos stay with their items
    // and the removed item's photo is no longer sent.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();
    expect(state.items, hasLength(2));
    expect(find.text('Photo required'), findsNothing);
    await submitAndWait(2);
    final second = submissions[1];
    final renumbered = (second['p_items'] as List).cast<Map>();
    expect([
      for (final item in renumbered) item['photo']['storage_path'],
    ], everyElement(isNot(endsWith('/$ricePhoto.png'))));
    expect(second['p_request'], isNot(first['p_request']));
    expect([for (final item in renumbered) item['item_position']], [1, 2]);
    expect(
      [for (final item in renumbered) item['item_name']],
      ['Notebooks', 'Clothes'],
    );
    expect(
      renumbered[0]['photo']['storage_path'],
      endsWith('/$notebookPhoto.png'),
    );
    expect(
      renumbered[1]['photo']['storage_path'],
      endsWith('/$clothesPhoto.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('the form keeps the 30-item maximum', () {
    expect(DonationItemPhotoRules.maxItems, 30);
  });

  group('location picker road access', () {
    const initial = LocationResult(
      address: 'Laut, Selat Melaka',
      latitude: 2.9,
      longitude: 100.9,
      method: LocationSelectionMethod.mapPin,
    );

    Future<FilledButton> pumpPicker(
      WidgetTester tester,
      RoadAccessResult road,
    ) async {
      final checked = <(double, double)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: LocationPickerPage(
            title: 'Pickup location',
            initialLocation: initial,
            roadAccess: RoadAccessRequirement.required,
            roadAccessCheck: (lat, lng) async {
              checked.add((lat, lng));
              return road;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(checked, [(2.9, 100.9)]);
      return tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirm Location'),
      );
    }

    testWidgets('confirm is disabled when the point is not routable', (
      tester,
    ) async {
      final button = await pumpPicker(
        tester,
        const RoadAccessResult(
          routable: false,
          reasonCode: 'NO_DRIVABLE_NODE_WITHIN_500M',
        ),
      );
      expect(button.onPressed, isNull);
      expect(find.textContaining('No drivable road within 500 m'), findsOne);
    });

    testWidgets('confirm is enabled when the point is routable', (
      tester,
    ) async {
      final button = await pumpPicker(
        tester,
        const RoadAccessResult(routable: true, snapDistanceM: 35.4),
      );
      expect(button.onPressed, isNotNull);
      expect(
        find.text('Road access confirmed · 35 m from a drivable road'),
        findsOneWidget,
      );
    });
  });

  group('donation result dialog', () {
    Future<void> pumpDialog(
      WidgetTester tester,
      Map<String, dynamic> detail,
      void Function(bool?) onResult,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onResult(
                await showDialog<bool>(
                  context: context,
                  builder: (_) => DonationResultDialog(detail: detail),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('AVAILABLE / DIRECT_PICKUP / READY', (tester) async {
      bool? result;
      await pumpDialog(tester, {
        'donation_status': 'AVAILABLE',
        'collection_path': 'DIRECT_PICKUP',
        'road_node_status': 'READY',
        'total_weight_kg': 12,
      }, (value) => result = value);
      expect(find.textContaining('Available'), findsOneWidget);
      expect(find.textContaining('Direct Pickup'), findsOneWidget);
      expect(
        find.textContaining(
          'Road route ready: verified NGOs within 20 km by road can claim it',
        ),
        findsOneWidget,
      );
      expect(find.text('Choose a community hub'), findsNothing);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('SUBMITTED / HUB_COLLECTION offers hub selection', (
      tester,
    ) async {
      bool? result;
      await pumpDialog(tester, {
        'donation_status': 'SUBMITTED',
        'collection_path': 'HUB_COLLECTION',
        'road_node_status': null,
        'total_weight_kg': 5,
      }, (value) => result = value);
      expect(find.textContaining('Awaiting Hub Selection'), findsOneWidget);
      expect(find.textContaining('Hub Collection'), findsOneWidget);
      await tester.tap(find.text('Choose a community hub'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    test('non-ready road states use the routing explanation', () {
      expect(routingStatusExplanation('NOT_ROUTABLE'), contains('500 m'));
      expect(routingStatusExplanation('PENDING_NODE'), contains('road node'));
    });
  });

  group('donation server errors', () {
    String message(String raw) => donationPhotoFailureMessage(
      PostgrestException(message: raw, code: 'P0001'),
    );

    test('known codes are readable and keep the raw code', () {
      expect(message('INVALID_DONATION_ITEM'), contains('active'));
      expect(
        message('INVALID_DONATION_ITEM'),
        contains('INVALID_DONATION_ITEM'),
      );
      expect(message('INVALID_TOTAL_WEIGHT'), contains('greater than 0 kg'));
      expect(message('ONE_TO_THREE_PHOTOS_REQUIRED'), contains('1 and 3'));
      expect(message('INVALID_COORDINATES'), contains('coordinates'));
      expect(
        message('IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'),
        contains('new ID'),
      );
    });

    test('photo position suffix still maps to the photo message', () {
      final text = message('INVALID_DONATION_IMAGE_2');
      expect(text, contains('JPG, PNG or WebP'));
      expect(text, contains('INVALID_DONATION_IMAGE_2'));
    });

    test('item-photo errors name the item position', () {
      final invalid = message('INVALID_ITEM_PHOTO_2');
      expect(invalid, contains('photo for item 2'));
      expect(invalid, contains('JPG, PNG or WebP'));
      expect(invalid, contains('INVALID_ITEM_PHOTO_2'));
      expect(
        message('STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED_3'),
        allOf(contains('item 3'), contains('Tap Submit')),
      );
      expect(message('ITEM_PHOTO_ALREADY_ATTACHED_1'), contains('item 1'));
      expect(message('DUPLICATE_ITEM_PHOTO_2'), contains('item 2'));
    });

    test('item-photo rule errors are readable', () {
      expect(
        message('AT_LEAST_ONE_ITEM_PHOTO_REQUIRED'),
        contains('Every item needs a photo'),
      );
      expect(
        message('ITEM_PHOTO_REQUIRED_3'),
        allOf(
          contains('Add a photo to item 3'),
          contains('ITEM_PHOTO_REQUIRED_3'),
        ),
      );
      expect(message('ONE_TO_THIRTY_ITEMS_REQUIRED'), contains('1 and 30'));
      expect(message('ONE_PHOTO_PER_ITEM'), contains('only one photo'));
      expect(message('INVALID_ITEM_POSITIONS'), contains('Tap Submit again'));
    });

    test('unknown codes fall back and still show the code', () {
      expect(message('SOMETHING_NEW_FAILED'), contains('SOMETHING_NEW_FAILED'));
    });
  });
}

http.Response _json(Object value, {int status = 200, http.Request? request}) =>
    http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json'},
      request: request,
    );

http.Response _token(String actor, http.Request request) {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sub': actor,
            'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          }),
        ),
      )
      .replaceAll('=', '');
  return _json({
    'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'offline-test-refresh',
    'user': {'id': actor, 'app_metadata': {}, 'user_metadata': {}},
  }, request: request);
}

/// The mock HTTP handler of the widget test that is running now.
Future<http.Response> Function(http.Request request)? _offlineHandler;

/// Routes this widget test's Supabase traffic to [handler].
///
/// The app keeps its client in a top-level `final _db = Supabase.instance.client`
/// (lib/donation_pages.dart), which Dart initializes once, on first use. A
/// second `Supabase.initialize` in the same test file would therefore never
/// reach the page: it would keep using the first test's client and mock. So
/// this file creates one offline client, on first use, and each test installs
/// its own handler for that client.
Future<void> _initOfflineSupabase(
  WidgetTester tester,
  Future<http.Response> Function(http.Request request) handler, {
  bool signIn = false,
}) async {
  _offlineHandler = handler;
  addTearDown(() => _offlineHandler = null);
  await tester.runAsync(() async {
    if (!_offlineSupabaseReady) {
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
        url: 'http://localhost:54321',
        publishableKey: 'offline-test-key',
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
        ),
        httpClient: MockClient((request) {
          final current = _offlineHandler;
          if (current == null) {
            throw StateError('No mock handler for ${request.url.path}');
          }
          return current(request);
        }),
      );
      _offlineSupabaseReady = true;
    }
    if (signIn) {
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'donor@example.invalid',
        password: 'offline-test',
      );
    }
  });
}

bool _offlineSupabaseReady = false;

/// The enabled state of an item photo button, found by its label.
ButtonStyleButton _photoButton(WidgetTester tester, String label) =>
    tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      ),
    );
