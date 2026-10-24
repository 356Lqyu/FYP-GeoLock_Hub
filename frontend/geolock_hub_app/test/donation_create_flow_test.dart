import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/donation_collection_path.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/donation_photo_errors.dart';
import 'package:geolock_hub_app/location/location_picker_page.dart';
import 'package:geolock_hub_app/location/location_result.dart';
import 'package:geolock_hub_app/location/road_routing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

double _total(int quantity, double unitWeightKg) =>
    donationTotalWeightKg([(quantity: quantity, unitWeightKg: unitWeightKg)]);

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

    test('sums several items and ignores incomplete rows', () {
      final total = donationTotalWeightKg([
        (quantity: 3, unitWeightKg: 2.5),
        (quantity: 2, unitWeightKg: 1.25),
        (quantity: null, unitWeightKg: 4),
        (quantity: 2, unitWeightKg: -1),
      ]);
      expect(total, 10.0);
    });

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
