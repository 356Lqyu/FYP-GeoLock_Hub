import 'claim_pickup_photos_test.dart' show PhotoHttpClient;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/claim_pickup_detail_reader.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/routing/claim_coordination.dart';
import 'package:geolock_hub_app/routing/route_resolution_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeClaimDetailReader implements ClaimPickupDetailReader {
  _FakeClaimDetailReader({
    required this.detail,
    this.constituents = const [],
    this.historical,
    this.historyError,
    this.claimCardsFailures = 0,
    this.cardError,
    this.cardFields = const {},
    this.audit = const [],
  });

  final Map<String, dynamic> detail;
  final Object constituents;
  final Map<String, dynamic>? historical;
  final Object? historyError;
  int claimCardsFailures;
  final Object? cardError;
  final Map<String, dynamic> cardFields;
  final List<Map<String, dynamic>> audit;
  final calls = <String>[];
  String? actor = 'ngo-a';

  @override
  String? get identity => actor;

  @override
  Future<Object?> rpc(String name, {Map<String, dynamic>? params}) async {
    calls.add(name);
    switch (name) {
      case 'get_my_claim_cards_v2':
        if (cardError != null) throw cardError!;
        if (claimCardsFailures > 0) {
          claimCardsFailures--;
          throw StateError('temporary claim cards failure');
        }
        final status = detail['claim_status']?.toString() ?? 'RELEASED';
        final expiredAt =
            detail['lease_expires_at']?.toString() ??
            DateTime.now()
                .toUtc()
                .subtract(const Duration(days: 1))
                .toIso8601String();
        final active = status == 'ACTIVE' && detail['lease_status'] == 'ACTIVE';
        return [
          {
            'claim_id': 'claim-released',
            'claim_status': status,
            'lease_status': detail['lease_status'],
            'lease_id': 'lease-a',
            'listing_id': 'listing-a',
            'claimed_at': '2026-11-02T16:44:00Z',
            'task_status': active ? 'CONFIRMED' : 'STALE',
            'source_type': detail['source_type'] ?? 'DIRECT_DONATION',
            'listing_weight_kg': detail['listing_weight_kg'] ?? 20,
            'title': 'Historical goods',
            'lease_expires_at': expiredAt,
            'server_now': DateTime.now().toUtc().toIso8601String(),
            'lease_is_expired': active
                ? DateTime.parse(expiredAt).isBefore(DateTime.now().toUtc())
                : true,
            'lease_recovery_pending': active
                ? DateTime.parse(expiredAt).isBefore(DateTime.now().toUtc())
                : false,
            ...cardFields,
          },
        ];
      case 'get_claimed_listing_detail':
        expect(params, {'p_claim': 'claim-released'});
        return detail;
      case 'get_my_historical_claim_detail':
        expect(params, {'p_claim': 'claim-released'});
        if (historyError != null) throw historyError!;
        return historical ??
            {
              ...detail,
              'read_only': true,
              'claim_created_at': '2026-11-02T16:44:00Z',
              'constituents': constituents,
            };
      case 'get_claimed_listing_constituents_v2':
        return constituents;
      case 'get_donation_images':
        return const [];
      case 'get_authorized_audit_events':
        return audit;
      default:
        throw StateError('Unexpected RPC $name');
    }
  }
}

Map<String, dynamic> releasedDetail() => {
  'claim_id': 'claim-released',
  'claim_status': 'RELEASED',
  'claim_close_reason': 'RECONCILED_NO_HANDOVER',
  'claim_closed_at': '2026-11-03T06:03:14Z',
  'listing_id': 'listing-a',
  'listing_status': 'AVAILABLE',
  'source_type': 'DIRECT_DONATION',
  'donation_id': 'donation-a',
  'pickup_address': 'Test address',
  'latitude': 3.1,
  'longitude': 101.6,
  'listing_weight_kg': 20,
  'lease_status': 'RELEASED',
  'lease_expires_at': '2026-11-03T00:00:00Z',
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('four donor claims show latest and collapse earlier history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rows = [
      for (var i = 1; i <= 3; i++)
        {
          'claim_id': 'old-$i',
          'claimed_at': '2026-10-0${i}T00:00:00Z',
          'blocking_reason': 'NO_OPEN_RECONCILIATION',
          'donor_evidence': {'handover_confirmed': null},
          'ngo_evidence': {'handover_confirmed': null},
        },
      {
        'claim_id': 'latest',
        'claimed_at': '2026-11-03T06:03:14Z',
        'case_status': 'RESOLVED_RELEASED',
        'resolved_at': '2026-11-03T06:03:14Z',
        'donor_evidence': {'handover_confirmed': false},
        'ngo_evidence': {'handover_confirmed': false},
      },
    ];
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'donor-a',
      rpc: (name, _) async {
        if (name == 'get_my_donation_route_resolution') {
          return {
            'contract': 'geolock.donor-route-resolution.v1',
            'donation_id': 'donation-a',
            'enabled': false,
            'contexts': [],
          };
        }
        if (name == 'get_my_donation_claim_reconciliation') {
          return {
            'contract': 'geolock.donor-claim-reconciliation.v1',
            'donation_id': 'donation-a',
            'contexts': rows,
            'history_truncated': false,
            'association_conflict': false,
          };
        }
        throw StateError('Unexpected RPC $name');
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DonorPickupOutcomeNotice(
              donationId: 'donation-a',
              repository: repo,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Latest claim outcome'), findsOneWidget);
    expect(find.text('Claim outcome: Resolved — released'), findsOneWidget);
    expect(find.text('Your statement: Not Collected'), findsOneWidget);
    expect(find.text('NGO statement: Not Collected'), findsOneWidget);
    expect(find.text('Claim History (3 previous)'), findsOneWidget);
    expect(
      find.textContaining('No reconciliation required or recorded'),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('donor-claim-history')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('No reconciliation required or recorded'),
      findsNWidgets(3),
    );
    expect(find.textContaining('No statement recorded'), findsNWidgets(6));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual review and contradictory statements stay prominent', (
    tester,
  ) async {
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'donor-a',
      rpc: (name, _) async {
        if (name == 'get_my_donation_route_resolution') {
          return {
            'contract': 'geolock.donor-route-resolution.v1',
            'donation_id': 'donation-a',
            'enabled': false,
            'contexts': [],
          };
        }
        return {
          'contract': 'geolock.donor-claim-reconciliation.v1',
          'donation_id': 'donation-a',
          'history_truncated': false,
          'association_conflict': false,
          'contexts': [
            {
              'claim_id': 'claim-review',
              'opened_at': '2026-11-03T06:00:00Z',
              'case_status': 'MANUAL_REVIEW',
              'donor_evidence': {'handover_confirmed': true},
              'ngo_evidence': {'handover_confirmed': false},
            },
          ],
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DonorPickupOutcomeNotice(
              donationId: 'donation-a',
              repository: repo,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('under manual review'), findsWidgets);
    expect(find.textContaining('statements conflict'), findsOneWidget);
    expect(find.text('Your statement: Collected'), findsOneWidget);
    expect(find.text('NGO statement: Not Collected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'released history shows recorded release and never requests media',
    (tester) async {
      var photoRequests = 0;
      final reader = _FakeClaimDetailReader(
        detail: releasedDetail(),
        cardFields: {
          'primary_image_path': 'cover.jpg',
          'close_reason': 'RECONCILED_NO_HANDOVER',
        },
        audit: [
          {
            'event_type': 'CANCEL_CLAIM',
            'occurred_at': '2026-11-03T06:03:14Z',
            'outcome': 'SUCCESS',
          },
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ClaimPickupDetailPage(
            claimId: 'claim-released',
            reader: reader,
            photoUrlResolver: (_) async {
              photoRequests++;
              throw StateError('Unexpected signing');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(Chip, 'Released'), findsOneWidget);
      expect(find.text('Direct Pickup'), findsOneWidget);
      expect(find.text('Claim created'), findsOneWidget);
      expect(find.text('Claim released'), findsOneWidget);
      expect(find.text('Listing availability'), findsNothing);
      expect(find.textContaining('Current status'), findsNothing);
      expect(
        find.byKey(const Key('claim-reconciliation-notice')),
        findsNothing,
      );
      await tester.scrollUntilVisible(find.text('Release reason'), 150);
      expect(find.text('Claim ID'), findsOneWidget);
      expect(find.text('claim-released'), findsOneWidget);
      expect(find.text('Lease expiry'), findsOneWidget);
      expect(find.text('Pickup task'), findsOneWidget);
      expect(find.text('RECONCILED_NO_HANDOVER'), findsOneWidget);
      expect(find.text('Test address'), findsNothing);
      expect(find.text('3.1, 101.6'), findsNothing);
      expect(find.byType(DonationPhotoCarousel), findsNothing);
      expect(photoRequests, 0);
      expect(reader.calls, [
        'get_my_claim_cards_v2',
        'get_authorized_audit_events',
      ]);
    },
  );

  for (final coverState in ['allowed', 'denied', 'absent']) {
    testWidgets(
      'collected history keeps the timeline when cover is $coverState',
      (tester) async {
        final requestedPaths = <String>[];
        final reader = _FakeClaimDetailReader(
          detail: {...releasedDetail(), 'claim_status': 'COMPLETED'},
          cardFields: {
            'task_status': 'COLLECTED',
            if (coverState != 'absent') 'primary_image_path': 'cover.jpg',
          },
          historyError: const PostgrestException(
            message: 'function missing',
            code: 'PGRST202',
          ),
          audit: [
            {
              'event_type': 'COMPLETE_PICKUP',
              'occurred_at': '2026-11-03T06:03:14Z',
              'outcome': 'SUCCESS',
            },
          ],
        );
        debugNetworkImageHttpClientProvider = () => PhotoHttpClient();
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: ClaimPickupDetailPage(
                claimId: 'claim-released',
                reader: reader,
                photoUrlResolver: (path) async {
                  requestedPaths.add(path);
                  if (coverState == 'denied') {
                    throw StateError('Signing denied');
                  }
                  return 'https://example.invalid/collected-cover.jpg';
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
        } finally {
          debugNetworkImageHttpClientProvider = null;
        }
        expect(find.widgetWithText(Chip, 'Collected'), findsOneWidget);
        expect(find.text('Handover completed'), findsOneWidget);
        expect(find.text('Listing availability'), findsNothing);
        expect(find.text('Claim Lease Status'), findsNothing);
        expect(find.text('Test address'), findsNothing);
        expect(find.text('3.1, 101.6'), findsNothing);
        expect(
          find.text('Historical details temporarily unavailable'),
          findsNothing,
        );
        expect(
          find.byKey(const Key('collected-claim-cover')),
          coverState == 'allowed' ? findsOneWidget : findsNothing,
        );
        expect(requestedPaths, coverState == 'absent' ? [] : ['cover.jpg']);
        expect(reader.calls, [
          'get_my_claim_cards_v2',
          'get_authorized_audit_events',
        ]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('active claim detail continues to load constituents normally', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = {
      ...releasedDetail(),
      'claim_status': 'ACTIVE',
      'claim_close_reason': null,
      'claim_closed_at': null,
      'lease_status': 'ACTIVE',
      'lease_expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(days: 1))
          .toIso8601String(),
    };
    final reader = _FakeClaimDetailReader(
      detail: detail,
      cardFields: {'title': 'Active goods for local families'},
      constituents: [
        {
          'donation_id': 'donation-a',
          'title': 'Active goods',
          'total_weight_kg': 10,
          'donation_status': 'CLAIMED',
          'primary_image_path': null,
          'batch_cover_path': null,
        },
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.2)),
          child: child!,
        ),
        home: ClaimPickupDetailPage(claimId: 'claim-released', reader: reader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Historical claim — read only'), findsNothing);
    final title = find.text('Active goods for local families');
    final badge = find.widgetWithText(Chip, 'Active');
    expect(title, findsOneWidget);
    expect(badge, findsOneWidget);
    expect(
      tester.getTopLeft(badge).dx,
      greaterThan(tester.getTopLeft(title).dx),
    );
    expect(
      tester.getTopLeft(find.text('Direct Pickup')).dy,
      greaterThan(tester.getTopLeft(badge).dy),
    );
    expect(find.text('20 kg'), findsOneWidget);
    expect(find.text('DIRECT_DONATION'), findsNothing);
    expect(find.text('Claim summary'), findsOneWidget);
    expect(find.text('Lease expiry'), findsOneWidget);
    expect(find.text('Pickup task'), findsOneWidget);
    expect(find.text('Claim'), findsNothing);
    expect(find.text('Lease'), findsNothing);
    expect(reader.calls, contains('get_claimed_listing_constituents_v2'));
    expect(find.text('Test address'), findsOneWidget);
    expect(find.text('3.1, 101.6'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Claim and Pickup History'), 180);
    expect(find.text('Claim and Pickup History'), findsOneWidget);
    expect(find.textContaining('Donation Progress'), findsNothing);
    expect(find.textContaining('Current status'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('denied detail errors do not render raw database text', (
    tester,
  ) async {
    final reader = _FakeClaimDetailReader(
      detail: releasedDetail(),
      cardError: const PostgrestException(
        message: 'CLAIM_NOT_FOUND_OR_FORBIDDEN private-detail',
        code: 'P0001',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ClaimPickupDetailPage(claimId: 'claim-released', reader: reader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('could not verify access'), findsOneWidget);
    expect(find.textContaining('private-detail'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'active claim with expired lease is read-only and location-free',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final detail = {
        ...releasedDetail(),
        'claim_status': 'ACTIVE',
        'lease_status': 'ACTIVE',
        'lease_expires_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 5))
            .toIso8601String(),
      };
      final reader = _FakeClaimDetailReader(
        detail: detail,
        historical: {...detail, 'read_only': true, 'constituents': const []},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ClaimPickupDetailPage(
            claimId: 'claim-released',
            reader: reader,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(Chip, 'Expired, awaiting recovery'),
        findsOneWidget,
      );
      expect(
        find.textContaining('database still controls recovery'),
        findsOneWidget,
      );
      expect(find.text('Test address'), findsNothing);
      expect(reader.calls, [
        'get_my_claim_cards_v2',
        'get_authorized_audit_events',
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('EXPIRED claim history is visible without donor location', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = {
      ...releasedDetail(),
      'claim_status': 'EXPIRED',
      'lease_status': 'EXPIRED',
      'claim_close_reason': 'LEASE_EXPIRED',
    };
    final reader = _FakeClaimDetailReader(
      detail: detail,
      historical: {
        ...detail,
        'read_only': true,
        'claim_created_at': '2026-11-02T16:44:00Z',
        'pickup_address': null,
        'latitude': null,
        'longitude': null,
        'constituents': const [],
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ClaimPickupDetailPage(claimId: 'claim-released', reader: reader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Chip, 'Expired'), findsOneWidget);
    expect(find.text('Test address'), findsNothing);
    expect(find.text('Private donor pickup location hidden'), findsNothing);
    expect(find.text('Confirm no handover'), findsNothing);
    expect(reader.calls, [
      'get_my_claim_cards_v2',
      'get_authorized_audit_events',
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  for (final state in ['CANCELLED', 'ACTIVE']) {
    testWidgets(
      'minimal safe details for $state without operational evidence',
      (tester) async {
        final reader = _FakeClaimDetailReader(
          detail: {...releasedDetail(), 'claim_status': state},
          cardFields: {'primary_image_path': 'ignored.jpg'},
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ClaimPickupDetailPage(
              claimId: 'claim-released',
              reader: reader,
              photoUrlResolver: (_) async =>
                  throw StateError('Unexpected signing'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(
            Chip,
            state == 'ACTIVE' ? 'Status Needs Review' : 'Cancelled',
          ),
          findsOneWidget,
        );
        expect(find.text('Claim created'), findsOneWidget);
        expect(find.text('Claim Lease Status'), findsNothing);
        expect(find.text('Test address'), findsNothing);
        expect(reader.calls, [
          'get_my_claim_cards_v2',
          'get_authorized_audit_events',
        ]);
      },
    );
  }

  testWidgets(
    'reconciliation-required claim links to the single reconciliation interface',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final detail = {
        ...releasedDetail(),
        'claim_status': 'RECONCILIATION_REQUIRED',
        'lease_status': 'RECONCILIATION_REQUIRED',
        'listing_status': 'CLAIMED',
      };
      final reader = _FakeClaimDetailReader(
        detail: detail,
        cardFields: {'task_status': 'DISPATCHED'},
        constituents: [
          {
            'donation_id': 'donation-a',
            'donation_description': 'Description must remain hidden in reconciliation.',
          },
        ],
      );
      final coordinationReads = <String>[];
      final coordination = ClaimCoordinationRepository(
        identity: () => 'ngo-user',
        rpc: (name, params) async {
          coordinationReads.add(name);
          expect(name, 'get_my_claim_coordination');
          return {
            'contract': 'geolock.claim-coordination.v2',
            'claim_id': 'claim-released',
            'case_id': 'case-1',
            'case_status': 'OPEN',
            'evidence_round': 1,
            'evidence_version': 1,
            'blocker': 'AWAITING_COUNTERPART',
            'can_submit': true,
            'can_resolve': false,
            'can_request_review': false,
            'can_accept_review': false,
            'review_waiting': false,
            'statements': <dynamic>[],
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(1.2),
            ),
            child: child!,
          ),
          home: ClaimPickupDetailPage(
            claimId: 'claim-released',
            reader: reader,
            coordinationRepository: coordination,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Concise notice only: no response form on the claim detail page.
      expect(find.text('Handover requires reconciliation'), findsOneWidget);
      expect(
        find.textContaining('The next pickup on its route stays blocked'),
        findsOneWidget,
      );
      expect(find.text('Confirm handover'), findsNothing);
      expect(find.text('Confirm no handover'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Handover'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'No Handover'), findsNothing);
      expect(coordinationReads, isEmpty, reason: 'no embedded panel read');
      expect(find.text('Test address'), findsNothing);
      expect(tester.takeException(), isNull);
      // The link opens the existing v2 panel, which owns the statements.
      tester.view.physicalSize = const Size(1000, 2200);
      await tester.pumpAndSettle();
      expect(find.text('Description must remain hidden in reconciliation.'), findsNothing);
      final link = find.byKey(const Key('claim-detail-view-reconciliation'));
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(coordinationReads, ['get_my_claim_coordination']);
      expect(find.widgetWithText(FilledButton, 'Handover'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'No Handover'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('claim refresh hides the old description at 320 px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = {
      ...releasedDetail(),
      'claim_status': 'ACTIVE',
      'listing_status': 'CLAIMED',
      'lease_status': 'ACTIVE',
      'lease_expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    };
    final reader = _FakeClaimDetailReader(
      detail: detail,
      constituents: [
        {
          'donation_id': 'donation-a',
          'donation_description': 'Four unopened bags, ready for pickup.',
        },
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.2)),
          child: child!,
        ),
        home: ClaimPickupDetailPage(claimId: 'claim-released', reader: reader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Four unopened bags, ready for pickup.'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    detail['claim_status'] = 'COMPLETED';
    detail['lease_status'] = 'COMPLETED';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Description'), findsNothing);
    expect(find.text('Four unopened bags, ready for pickup.'), findsNothing);
    expect(find.text('Test address'), findsNothing);
    expect(
      reader.calls.where((name) => name == 'get_claimed_listing_constituents_v2'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'claim detail retry refresh uses a synchronous setState callback',
    (tester) async {
      final reader = _FakeClaimDetailReader(
        detail: {
          ...releasedDetail(),
          'claim_status': 'RECONCILIATION_REQUIRED',
          'lease_status': 'RECONCILIATION_REQUIRED',
          'listing_status': 'CLAIMED',
        },
        claimCardsFailures: 1,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ClaimPickupDetailPage(
            claimId: 'claim-released',
            reader: reader,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Handover requires reconciliation'), findsOneWidget);
      expect(
        reader.calls.where((name) => name == 'get_my_claim_cards_v2'),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('claim detail errors use safe authorization/network messages', () {
    expect(
      claimDetailsErrorMessage(
        const PostgrestException(message: 'private raw text', code: 'P0001'),
      ),
      contains('could not verify access'),
    );
    expect(
      claimDetailsErrorMessage(const SocketException('private endpoint')),
      contains('Check your connection'),
    );
    expect(
      claimDetailsErrorMessage(
        const PostgrestException(message: 'function missing', code: 'PGRST202'),
      ),
      contains('temporarily unavailable'),
    );
    expect(
      claimDetailsErrorMessage(StateError('private raw text')),
      isNot(contains('private raw text')),
    );
  });
}
