// Item-level donation photos in the Donor, NGO and Hub detail views, and the
// unchanged galleries of legacy donations. No network or live database:
// Storage signing fails offline, so thumbnails show their placeholders.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/claim_pickup_detail_reader.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/hub_admin/hub_admin_controller.dart';
import 'package:geolock_hub_app/hub_admin/hub_donation_detail_page.dart';
import 'package:geolock_hub_app/hub_admin/hub_service.dart';
import 'package:geolock_hub_app/hub_admin/hub_widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> itemRow(
  String donation,
  int position,
  String name, {
  String? photo,
}) => {
  'donation_id': donation,
  'item_id': '$donation-item-$position',
  'item_position': position,
  'item_name': name,
  'category_name': 'Household Essentials',
  'quantity': position,
  'unit_label': 'piece',
  'unit_weight_kg': 1.5,
  'item_condition': 'GOOD',
  'photo_image_id': photo == null ? null : 'img-$donation-$position',
  'photo_path': photo,
  'photo_content_type': photo == null ? null : 'image/jpeg',
};

Finder get itemPhotoThumbnails => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics && widget.properties.label == 'View item photo',
);

class ItemPhotoClaimReader implements ClaimPickupDetailReader {
  ItemPhotoClaimReader({this.batch = false, this.items, this.itemsError});
  final bool batch;
  final List<Map<String, dynamic>>? items;
  final Object? itemsError;
  final calls = <String>[];
  @override
  String get identity => 'ngo';
  @override
  Future<Object?> rpc(String name, {Map<String, dynamic>? params}) async {
    calls.add(name);
    final expiry = DateTime.now()
        .toUtc()
        .add(const Duration(days: 1))
        .toIso8601String();
    final source = batch ? 'HUB_BATCH' : 'DIRECT_DONATION';
    final donations = ['donation-a', if (batch) 'donation-b'];
    switch (name) {
      case 'get_my_claim_cards_v2':
        return [
          {
            'claim_id': 'claim',
            'claim_status': 'ACTIVE',
            'lease_status': 'ACTIVE',
            'lease_id': 'lease',
            'listing_id': 'listing',
            'source_type': source,
            'task_status': 'CONFIRMED',
            'lease_expires_at': expiry,
            'server_now': DateTime.now().toUtc().toIso8601String(),
            'lease_is_expired': false,
            'lease_recovery_pending': false,
          },
        ];
      case 'get_claimed_listing_detail':
        return {
          'claim_id': 'claim',
          'claim_status': 'ACTIVE',
          'source_type': source,
          'donation_ids': donations,
          'lease_status': 'ACTIVE',
          'lease_expires_at': expiry,
          'listing_weight_kg': 10,
        };
      case 'get_claimed_listing_constituents_v2':
        return [
          for (final id in donations)
            {
              'donation_id': id,
              'title': 'Title of $id',
              'donation_status': 'CLAIMED',
              'total_weight_kg': 5,
              'primary_image_path': '$id/item-2.jpg',
              'batch_cover_path': batch ? 'batch/cover.jpg' : null,
            },
        ];
      case 'get_donation_images':
        final id = params!['p_donation'];
        return [
          {'storage_path': '$id/item-2.jpg'},
          {'storage_path': '$id/item-3.jpg'},
        ];
      case 'get_claimed_listing_items':
        if (itemsError != null) throw itemsError!;
        return items;
      case 'get_authorized_audit_events':
        return [];
      default:
        throw StateError('Unexpected read $name');
    }
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'offline-test-key',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      // Signing a photo URL fails offline; thumbnails keep their placeholder.
      httpClient: MockClient((request) async => http.Response('{}', 503)),
    );
  });

  void tallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('donor donation details', () {
    Widget page(List<Map<String, dynamic>> items, List<String> images) =>
        MaterialApp(
          home: DonationDetailPage(
            donationId: 'donation-a',
            detailLoader: () async => {
              'title': 'Pantry and school items',
              'description': 'Packed',
              'status': 'AVAILABLE',
              'collection_path': 'DIRECT_PICKUP',
              'items': items,
              'images': [
                for (final path in images) {'storage_path': path},
              ],
            },
          ),
        );

    testWidgets(
      'each item photo is beside its item, with no duplicate gallery',
      (tester) async {
        tallScreen(tester);
        await tester.pumpWidget(
          page(
            [
              itemRow('donation-a', 1, 'Rice'),
              itemRow('donation-a', 2, 'Notebooks', photo: 'a/item-2.jpg'),
              itemRow('donation-a', 3, 'Clothes', photo: 'a/item-3.jpg'),
            ],
            ['a/item-2.jpg', 'a/item-3.jpg'],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(DonationPhotoCarousel), findsNothing);
        expect(itemPhotoThumbnails, findsNWidgets(2));
        for (final name in ['Rice', 'Notebooks', 'Clothes']) {
          expect(find.text(name), findsOneWidget);
        }
        // The photo sits in the same row as its item.
        final notebookRow = find.ancestor(
          of: find.text('Notebooks'),
          matching: find.byType(Row),
        );
        expect(
          find.descendant(of: notebookRow.first, matching: itemPhotoThumbnails),
          findsOneWidget,
        );
        final riceRow = find.ancestor(
          of: find.text('Rice'),
          matching: find.byType(Row),
        );
        expect(
          find.descendant(of: riceRow.first, matching: itemPhotoThumbnails),
          findsNothing,
        );
      },
    );

    testWidgets('legacy donation keeps its donation-level gallery', (
      tester,
    ) async {
      tallScreen(tester);
      await tester.pumpWidget(
        page(
          [
            {'item_id': 'x', 'item_name': 'Rice', 'photo_path': null},
          ],
          ['legacy/one.jpg', 'legacy/two.jpg'],
        ),
      );
      await tester.pumpAndSettle();
      final carousel = tester.widget<DonationPhotoCarousel>(
        find.byType(DonationPhotoCarousel),
      );
      expect(carousel.paths, ['legacy/one.jpg', 'legacy/two.jpg']);
      expect(itemPhotoThumbnails, findsNothing);
    });

    testWidgets('tapping an item photo opens it larger', (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(
        page(
          [itemRow('donation-a', 1, 'Rice', photo: 'a/item-1.jpg')],
          ['a/item-1.jpg'],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(itemPhotoThumbnails);
      await tester.pumpAndSettle();
      expect(find.text('Item photo'), findsOneWidget);
      expect(
        tester
            .widget<DonationPhotoCarousel>(find.byType(DonationPhotoCarousel))
            .paths,
        ['a/item-1.jpg'],
      );
    });
  });

  group('NGO listing details', () {
    const listing = <String, dynamic>{
      'listing_id': 'listing-1',
      'source_type': 'DIRECT_DONATION',
      'routing_status': 'READY',
      'title': 'Pantry donation',
      'listing_weight_kg': 12,
      'primary_image_path': 'a/item-2.jpg',
    };

    Widget page(List<Map<String, dynamic>> items, List<String> images) =>
        MaterialApp(
          home: NgoListingDetailsPage(
            listing: listing,
            identity: () => 'ngo-a',
            routingLoader: () async => true,
            listingsLoader: () async => [listing],
            detailsLoader: () async => {
              'images': [
                for (final path in images) {'storage_path': path},
              ],
              'items': items,
              'constituents': [
                {
                  'donation_id': 'donation-a',
                  'title': 'Pantry donation',
                  'total_weight_kg': 12,
                  'donation_status': 'AVAILABLE',
                  'primary_image_path': images.isEmpty ? null : images.first,
                },
              ],
              'listing_discovered_available': true,
              'progress_status': 'AVAILABLE',
            },
          ),
        );

    testWidgets('authorized items show name, category, quantity, condition '
        'and photo', (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(
        page(
          [
            itemRow('donation-a', 1, 'Rice'),
            itemRow('donation-a', 2, 'Notebooks', photo: 'a/item-2.jpg'),
          ],
          ['a/item-2.jpg'],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Items (2)'), findsOneWidget);
      expect(find.text('Rice'), findsOneWidget);
      expect(find.text('Notebooks'), findsOneWidget);
      expect(
        find.text('Household Essentials · Qty 2 · Good condition'),
        findsOneWidget,
      );
      expect(itemPhotoThumbnails, findsOneWidget);
      expect(find.byType(DonationPhotoCarousel), findsNothing);
    });

    testWidgets('legacy listing keeps its gallery and shows no item photos', (
      tester,
    ) async {
      tallScreen(tester);
      await tester.pumpWidget(page([], ['legacy/one.jpg']));
      await tester.pumpAndSettle();
      expect(find.textContaining('Items ('), findsNothing);
      expect(
        tester
            .widget<DonationPhotoCarousel>(find.byType(DonationPhotoCarousel))
            .paths,
        contains('legacy/one.jpg'),
      );
    });
  });

  group('NGO claim details', () {
    Future<void> open(WidgetTester tester, ItemPhotoClaimReader reader) async {
      tallScreen(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: ClaimPickupDetailPage(
            claimId: 'claim',
            reader: reader,
            photoUrlResolver: (path) async =>
                throw const StorageException('offline', statusCode: '503'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'direct claim shows item photos instead of a duplicate gallery',
      (tester) async {
        final reader = ItemPhotoClaimReader(
          items: [
            itemRow('donation-a', 1, 'Rice'),
            itemRow(
              'donation-a',
              2,
              'Notebooks',
              photo: 'donation-a/item-2.jpg',
            ),
            itemRow('donation-a', 3, 'Clothes', photo: 'donation-a/item-3.jpg'),
          ],
        );
        await open(tester, reader);
        expect(reader.calls, contains('get_claimed_listing_items'));
        await tester.scrollUntilVisible(
          find.text('Items (3)'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byType(DonationPhotoCarousel), findsNothing);
        expect(itemPhotoThumbnails, findsNWidgets(2));
        expect(find.text('Clothes'), findsOneWidget);
      },
    );

    testWidgets('batch claim keeps the hub batch photo and groups items', (
      tester,
    ) async {
      final reader = ItemPhotoClaimReader(
        batch: true,
        items: [
          itemRow('donation-a', 1, 'Rice'),
          itemRow('donation-a', 2, 'Notebooks', photo: 'donation-a/item-2.jpg'),
          itemRow('donation-a', 3, 'Clothes', photo: 'donation-a/item-3.jpg'),
          itemRow('donation-b', 1, 'Soap', photo: 'donation-b/item-2.jpg'),
          itemRow('donation-b', 2, 'Towels', photo: 'donation-b/item-3.jpg'),
        ],
      );
      await open(tester, reader);
      await tester.scrollUntilVisible(
        find.text('Items (5)'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final carousel = tester.widget<DonationPhotoCarousel>(
        find.byType(DonationPhotoCarousel),
      );
      expect(carousel.paths, ['batch/cover.jpg']);
      expect(find.text('Title of donation-a'), findsWidgets);
      expect(find.text('Title of donation-b'), findsWidgets);
    });

    testWidgets('a failed item read keeps the existing gallery', (
      tester,
    ) async {
      final reader = ItemPhotoClaimReader(
        itemsError: const PostgrestException(message: 'not deployed'),
      );
      await open(tester, reader);
      await tester.scrollUntilVisible(
        find.byType(DonationPhotoCarousel),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<DonationPhotoCarousel>(find.byType(DonationPhotoCarousel))
            .paths,
        containsAll(['donation-a/item-2.jpg', 'donation-a/item-3.jpg']),
      );
      expect(find.textContaining('Items ('), findsNothing);
    });
  });

  group('hub donation details', () {
    final controller = HubAdminController(
      HubSummary.fromRow(const {'hub_id': 'hub-a', 'hub_name': 'Hub A'}),
    );
    Map<String, dynamic> detail() => {
      'donation_id': 'donation-a',
      'title': 'Pantry donation',
      'total_weight_kg': 4.5,
      'items': [
        {
          'item_name': 'Rice',
          'category': 'Food',
          'item_condition': 'GOOD',
          'quantity': 1,
          'unit_label': 'bag',
          'unit_weight_kg': 4.5,
        },
      ],
      'image_paths': ['a/item-2.jpg', 'a/item-3.jpg'],
    };
    Iterable<HubPhoto> photos(WidgetTester tester) =>
        tester.widgetList<HubPhoto>(find.byType(HubPhoto));

    testWidgets('each item shows its own photo and the strip is hidden', (
      tester,
    ) async {
      tallScreen(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: HubDonationDetailPage(
            controller: controller,
            donationId: 'donation-a',
            detailLoader: () async => detail(),
            itemsLoader: () async => [
              itemRow('donation-a', 1, 'Rice'),
              itemRow('donation-a', 2, 'Notebooks', photo: 'a/item-2.jpg'),
              itemRow('donation-a', 3, 'Clothes', photo: 'a/item-3.jpg'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Items (3)'), findsOneWidget);
      expect(find.text('Notebooks'), findsOneWidget);
      expect(
        [for (final photo in photos(tester)) (photo.path, photo.size)],
        [('a/item-2.jpg', 56.0), ('a/item-3.jpg', 56.0)],
      );
    });

    testWidgets('a lapsed booking withholds paths but still hides the strip', (
      tester,
    ) async {
      tallScreen(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: HubDonationDetailPage(
            controller: controller,
            donationId: 'donation-a',
            detailLoader: () async => detail(),
            itemsLoader: () async => [
              {
                ...itemRow('donation-a', 1, 'Rice'),
                'photo_image_id': 'img-1',
                'photo_path': null,
              },
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(photos(tester), isEmpty);
      expect(find.text('Rice'), findsOneWidget);
    });

    for (final legacyCase in ['no item photos', 'item read fails']) {
      testWidgets('legacy donation keeps the photo strip ($legacyCase)', (
        tester,
      ) async {
        tallScreen(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: HubDonationDetailPage(
              controller: controller,
              donationId: 'donation-a',
              detailLoader: () async => detail(),
              itemsLoader: () async => legacyCase == 'item read fails'
                  ? throw const PostgrestException(message: 'not deployed')
                  : [itemRow('donation-a', 1, 'Rice')],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          [for (final photo in photos(tester)) (photo.path, photo.size)],
          [('a/item-2.jpg', 180.0), ('a/item-3.jpg', 180.0)],
        );
        expect(find.text('Rice'), findsOneWidget);
      });
    }
  });
}
