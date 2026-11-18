import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/donation_collection_path.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/donation_photo_errors.dart';
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

    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      final supabase = await Supabase.initialize(
        url: 'http://localhost:54321',
        publishableKey: 'offline-test-key',
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
        ),
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/token')) {
            final payload = base64Url
                .encode(
                  utf8.encode(
                    jsonEncode({
                      'sub': actor,
                      'exp':
                          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
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
          if (path.endsWith('/create_donation_with_images')) {
            submissions.add(jsonDecode(request.body) as Map<String, dynamic>);
            return jsonResponse(
              {'message': 'INVALID_DONATION_ITEM'},
              status: 400,
              request: request,
            );
          }
          throw StateError('Unexpected mock request: $path');
        }),
      );
      addTearDown(supabase.dispose);
      await supabase.client.auth.signInWithPassword(
        email: 'donor@example.invalid',
        password: 'offline-test',
      );
    });
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
    state.photos.add(
      DonationPhotoSelection(
        id: photoId,
        file: XFile('web/icons/Icon-192.png'),
      ),
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
    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pump();
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
    expect(
      (submissions.single['p_items'] as List).single['unit_weight_kg'],
      5.05,
    );
    expect(submitButton().onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
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
      expect(find.textContaining('Direct pickup'), findsOneWidget);
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
      expect(find.textContaining('Community hub'), findsOneWidget);
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

    test('unknown codes fall back and still show the code', () {
      expect(message('SOMETHING_NEW_FAILED'), contains('SOMETHING_NEW_FAILED'));
    });
  });
}
