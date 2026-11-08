import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/claim_pickup_detail_reader.dart';
import 'package:geolock_hub_app/donation_pages.dart';
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
  });

  final Map<String, dynamic> detail;
  final Object constituents;
  final Map<String, dynamic>? historical;
  final Object? historyError;
  int claimCardsFailures;
  final calls = <String>[];
  String? actor = 'ngo-a';

  @override
  String? get identity => actor;

  @override
  Future<Object?> rpc(String name, {Map<String, dynamic>? params}) async {
    calls.add(name);
    switch (name) {
      case 'get_my_claim_cards_v2':
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
      case 'get_claimed_listing_constituents':
        return constituents;
      case 'get_donation_images':
        return const [];
      case 'get_authorized_audit_events':
        return const [];
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

  testWidgets('released NGO claim is readable but clearly read only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final reader = _FakeClaimDetailReader(
      detail: releasedDetail(),
      historical: {
        ...releasedDetail(),
        'read_only': true,
        'claim_created_at': '2026-11-02T16:44:00Z',
        'constituents': [
          {
            'donation_id': 'donation-a',
            'title': 'Historical goods',
            'total_weight_kg': 20,
            'donation_status': 'AVAILABLE',
            'primary_image_path': null,
            'batch_cover_path': null,
            'items': [
              {
                'item_name': 'Canned beans',
                'category_name': 'Food',
                'quantity': 2,
                'unit_label': 'cans',
                'unit_weight_kg': 0.5,
              },
            ],
          },
        ],
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ClaimPickupDetailPage(claimId: 'claim-released', reader: reader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Historical claim — read only'), findsOneWidget);
    expect(
      find.textContaining('Donation Progress · Historical goods'),
      findsOneWidget,
    );
    expect(
      find.text('Released after no handover was confirmed'),
      findsOneWidget,
    );
    expect(find.text('Confirm handover'), findsNothing);
    expect(find.text('Confirm no handover'), findsNothing);
    expect(find.text('Canned beans'), findsOneWidget);
    expect(find.text('Food · 2 cans · 0.5 kg each'), findsOneWidget);
    expect(find.text('Test address'), findsNothing);
    expect(find.text('3.1, 101.6'), findsNothing);
    expect(reader.calls, contains('get_my_historical_claim_detail'));
    expect(reader.calls, isNot(contains('get_claimed_listing_detail')));
    expect(
      reader.calls.any(
        (name) =>
            name.toLowerCase().contains('claim') && !name.startsWith('get_'),
      ),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('released history degrades honestly when migration is absent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final reader = _FakeClaimDetailReader(
      detail: releasedDetail(),
      historyError: const PostgrestException(
        message: 'CLAIM_NOT_FOUND_OR_FORBIDDEN',
        code: 'PGRST202',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ClaimPickupDetailPage(claimId: 'claim-released', reader: reader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Historical claim — read only'), findsOneWidget);
    expect(
      find.text('Historical details temporarily unavailable'),
      findsOneWidget,
    );
    expect(
      find.text('Historical item details temporarily unavailable'),
      findsNothing,
    );
    expect(find.textContaining('CLAIM_NOT_FOUND_OR_FORBIDDEN'), findsNothing);
    expect(find.text('Test address'), findsNothing);
    expect(reader.calls, isNot(contains('get_claimed_listing_detail')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('active claim detail continues to load constituents normally', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2200);
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
        home: ClaimPickupDetailPage(claimId: 'claim-released', reader: reader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Historical claim — read only'), findsNothing);
    expect(
      find.textContaining('Donation Progress · Active goods'),
      findsOneWidget,
    );
    expect(reader.calls, contains('get_claimed_listing_constituents'));
    expect(find.text('Test address'), findsOneWidget);
    expect(find.text('3.1, 101.6'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('denied detail errors do not render raw database text', (
    tester,
  ) async {
    final reader = _FakeClaimDetailReader(
      detail: releasedDetail(),
      historyError: const PostgrestException(
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
      expect(find.text('Historical claim — read only'), findsOneWidget);
      expect(find.text('Private donor pickup location hidden'), findsOneWidget);
      expect(find.text('Test address'), findsNothing);
      expect(reader.calls, contains('get_my_historical_claim_detail'));
      expect(reader.calls, isNot(contains('get_claimed_listing_detail')));
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
    expect(find.text('Historical claim — read only'), findsOneWidget);
    expect(find.text('EXPIRED'), findsNothing);
    expect(find.text('Test address'), findsNothing);
    expect(find.text('Private donor pickup location hidden'), findsOneWidget);
    expect(reader.calls, contains('get_my_historical_claim_detail'));
    expect(find.text('Confirm no handover'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reconciliation-required claim retains its protected actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = {
      ...releasedDetail(),
      'claim_status': 'RECONCILIATION_REQUIRED',
      'lease_status': 'RECONCILIATION_REQUIRED',
      'listing_status': 'CLAIMED',
    };
    final reader = _FakeClaimDetailReader(detail: detail);
    await tester.pumpWidget(
      MaterialApp(
        home: ClaimPickupDetailPage(claimId: 'claim-released', reader: reader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Handover requires reconciliation'), findsOneWidget);
    expect(find.text('Confirm handover'), findsOneWidget);
    expect(find.text('Confirm no handover'), findsOneWidget);
    expect(find.text('Test address'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('claim detail retry refresh uses a synchronous setState callback', (
    tester,
  ) async {
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
        home: ClaimPickupDetailPage(claimId: 'claim-released', reader: reader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Handover requires reconciliation'), findsOneWidget);
    expect(reader.calls.where((name) => name == 'get_my_claim_cards_v2'), hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

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
