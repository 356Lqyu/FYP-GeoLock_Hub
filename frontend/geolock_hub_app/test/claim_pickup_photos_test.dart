import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/claim_pickup_detail_reader.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Exercise successful image decoding without contacting Storage or a network.
class PhotoHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => PhotoRequest();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PhotoRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => PhotoResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PhotoResponse extends Stream<List<int>> implements HttpClientResponse {
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
  );
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PhotoReader implements ClaimPickupDetailReader {
  PhotoReader({this.batch = false, this.paths = true, this.photoError});
  final bool batch, paths;
  final Object? photoError;
  final photoIds = <String>[];
  @override
  String get identity => 'ngo';
  @override
  Future<Object?> rpc(String name, {Map<String, dynamic>? params}) async {
    final expiry = DateTime.now()
        .toUtc()
        .add(const Duration(days: 1))
        .toIso8601String();
    final source = batch ? 'HUB_BATCH' : 'DIRECT_DONATION';
    switch (name) {
      case 'get_my_claim_cards_v2':
        return [
          {
            'claim_id': 'claim',
            'claim_status': 'ACTIVE',
            'lease_status': 'ACTIVE',
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
          'donation_ids': ['donation-a'],
          'lease_status': 'ACTIVE',
          'lease_expires_at': expiry,
          'listing_weight_kg': 10,
        };
      case 'get_claimed_listing_constituents':
        return [
          for (final id in ['donation-a', if (batch) 'donation-b'])
            {
              'donation_id': id,
              'title': id,
              'donation_status': 'CLAIMED',
              'total_weight_kg': 5,
              'primary_image_path': paths ? '$id/cover.jpg' : null,
              'batch_cover_path': batch && paths ? 'batch/cover.jpg' : null,
            },
        ];
      case 'get_donation_images':
        photoIds.add(params!['p_donation'] as String);
        if (photoError != null) throw photoError!;
        return paths
            ? [
                {'storage_path': '${params['p_donation']}/cover.jpg'},
                {'storage_path': '${params['p_donation']}/second.jpg'},
              ]
            : [];
      case 'get_authorized_audit_events':
        return [];
      default:
        throw StateError('Unexpected read $name');
    }
  }
}

Future<void> openPhotos(WidgetTester t, PhotoReader reader) async {
  t.view.physicalSize = const Size(1000, 2600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      home: ClaimPickupDetailPage(
        claimId: 'claim',
        reader: reader,
        photoUrlResolver: (path) async => 'https://example.invalid/$path',
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.scrollUntilVisible(
    find.byType(DonationPhotoCarousel),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  // Image decoding runs on the engine's real event loop, outside the fake clock.
  await t.runAsync(() async {
    for (final image in t.widgetList<Image>(find.byType(Image))) {
      await precacheImage(
        image.image,
        t.element(find.byType(DonationPhotoCarousel)),
      );
    }
  });
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    debugNetworkImageHttpClientProvider = () => PhotoHttpClient();
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
  });
  for (final batch in [false, true]) {
    testWidgets('authorized constituent IDs supply photos; batch=$batch', (
      t,
    ) async {
      final reader = PhotoReader(batch: batch);
      await openPhotos(t, reader);
      final carousel = t.widget<DonationPhotoCarousel>(
        find.byType(DonationPhotoCarousel),
      );
      expect(
        carousel.paths,
        containsAll(['donation-a/cover.jpg', 'donation-a/second.jpg']),
      );
      expect(carousel.paths.toSet().length, carousel.paths.length);
      expect(
        reader.photoIds,
        batch ? ['donation-a', 'donation-b'] : ['donation-a'],
      );
      if (batch) expect(carousel.paths.first, 'batch/cover.jpg');
      expect(find.byType(Image), findsWidgets);
      expect(
        t
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        isTrue,
      );
      expect(
        find.text('No donation photos available to your account'),
        findsNothing,
      );
      await t.pumpWidget(const SizedBox());
      debugNetworkImageHttpClientProvider = null;
    });
  }
  testWidgets('empty authorized photo set has an honest empty state', (
    t,
  ) async {
    await openPhotos(t, PhotoReader(paths: false));
    expect(
      find.text('No donation photos available to your account'),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
    debugNetworkImageHttpClientProvider = null;
  });
  for (final denied in [false, true]) {
    testWidgets('optional metadata error preserves claim details; denied=$denied', (
      t,
    ) async {
      await openPhotos(
        t,
        PhotoReader(
          paths: false,
          photoError: denied
              ? const PostgrestException(message: 'private', code: '42501')
              : TimeoutException('private'),
        ),
      );
      expect(find.text('Claimed Pickup Details'), findsOneWidget);
      expect(
        find.text(
          denied
              ? 'Donation photos are inaccessible with your current permissions.'
              : 'Donation photos could not be loaded. Check your connection and refresh.',
        ),
        findsOneWidget,
      );
      expect(find.text('Donation photos could not be loaded'), findsOneWidget);
      expect(find.textContaining('private'), findsNothing);
      await t.pumpWidget(const SizedBox());
      debugNetworkImageHttpClientProvider = null;
    });
    testWidgets('signed URL error is distinct from empty photos; denied=$denied', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DonationPhotoCarousel(
              paths: const ['photo.jpg'],
              showLoadErrors: true,
              urlResolver: (_) async => throw (denied
                  ? const StorageException('private', statusCode: '403')
                  : TimeoutException('private')),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.text(
          denied
              ? 'Donation photos are inaccessible with your current permissions.'
              : 'Donation photos could not be loaded. Check your connection and refresh.',
        ),
        findsOneWidget,
      );
      expect(find.text('No donation photos'), findsNothing);
      expect(find.textContaining('private'), findsNothing);
      await t.pumpWidget(const SizedBox());
      debugNetworkImageHttpClientProvider = null;
    });
  }
}
