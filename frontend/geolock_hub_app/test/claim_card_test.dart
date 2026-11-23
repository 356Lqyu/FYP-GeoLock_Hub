import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/claim_card.dart';
import 'package:geolock_hub_app/claim_cards_controller.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:geolock_hub_app/ui/geolock_role_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> cardJson([Map<String, dynamic> overrides = const {}]) => {
  'claim_id': 'claim-1',
  'listing_id': 'listing-1',
  'claim_status': 'ACTIVE',
  'claimed_at': '2026-10-22T01:00:00Z',
  'lease_id': 'lease-1',
  'lease_status': 'ACTIVE',
  'lease_expires_at': '2026-10-22T07:00:00Z',
  'task_status': 'CONFIRMED',
  'source_type': 'DIRECT_DONATION',
  'listing_weight_kg': 12,
  'title': 'Owned claim',
  'primary_image_path': null,
  'server_now': '2026-10-22T01:00:00Z',
  'lease_is_expired': false,
  'lease_recovery_pending': false,
  ...overrides,
};

void main() {
  test(
    'server-only future, exact boundary and past deadline classification',
    () {
      expect(ClaimCard.fromJson(cardJson()).isValidActive, isTrue);
      for (final deadline in ['2026-10-22T01:00:00Z', '2026-10-22T00:59:59Z']) {
        final card = ClaimCard.fromJson(
          cardJson({
            'lease_expires_at': deadline,
            'lease_is_expired': true,
            'lease_recovery_pending': true,
          }),
        );
        expect(card.displayStatus, ClaimDisplayStatus.expiredPending);
        expect(card.tab, ClaimTab.expired);
        expect(card.canStart || card.canCancel || card.canComplete, isFalse);
      }
    },
  );

  test('status precedence, badges and tabs for all persisted states', () {
    for (final entry in {
      'RELEASED': ClaimDisplayStatus.released,
      'CANCELLED': ClaimDisplayStatus.cancelled,
      'COMPLETED': ClaimDisplayStatus.completed,
      'EXPIRED': ClaimDisplayStatus.expired,
      'RECONCILIATION_REQUIRED': ClaimDisplayStatus.reconciliation,
    }.entries) {
      final card = ClaimCard.fromJson(cardJson({'claim_status': entry.key}));
      expect(card.displayStatus, entry.value);
      expect(card.badge, isNotEmpty);
      expect(card.isValidActive, isFalse);
      expect(
        card.tab,
        entry.key == 'RECONCILIATION_REQUIRED'
            ? ClaimTab.reconciliation
            : entry.key == 'EXPIRED'
            ? ClaimTab.expired
            : ClaimTab.history,
      );
    }
    expect(
      ClaimCard.fromJson(cardJson({'task_status': 'COLLECTED'})).badge,
      'Collected',
    );
    expect(
      ClaimCard.fromJson(
        cardJson({
          'claim_status': 'COMPLETED',
          'lease_status': 'RECONCILIATION_REQUIRED',
        }),
      ).badge,
      'Reconciliation required',
    );
    expect(
      ClaimCard.fromJson(cardJson({'case_status': 'MANUAL_REVIEW'})).tab,
      ClaimTab.reconciliation,
    );
    expect(
      ClaimCard.fromJson(
        cardJson({
          'claim_status': 'RELEASED',
          'release_reason': 'EXPIRED_SAFE_RELEASE',
        }),
      ).releaseReason,
      'EXPIRED_SAFE_RELEASE',
    );
  });

  test('missing or inconsistent evidence fails closed', () {
    for (final values in <Map<String, dynamic>>[
      {'lease_id': null},
      {'listing_id': null},
      {'lease_expires_at': null},
      {'server_now': null},
      {'lease_is_expired': null},
      {'lease_status': 'RELEASED'},
      {'task_status': null},
      {'lease_recovery_pending': true},
      {'lease_is_expired': true},
      {'lease_is_expired': 'false'},
      {'server_now': '2026-10-22T01:00:00'},
    ]) {
      final card = ClaimCard.fromJson(cardJson(values));
      expect(card.badge, 'Status Needs Review', reason: '$values');
      expect(card.tab, ClaimTab.active);
      expect(card.canStart || card.canCancel || card.canComplete, isFalse);
    }
    expect(() => parseClaimCards({'error': 'denied'}), throwsFormatException);
    expect(() => parseClaimCards([null]), throwsFormatException);
  });

  test('action gates distinguish confirmed, planned and dispatched tasks', () {
    final confirmed = ClaimCard.fromJson(cardJson());
    expect(confirmed.canStart && confirmed.canCancel, isTrue);
    expect(confirmed.canComplete, isFalse);
    final planned = ClaimCard.fromJson(cardJson({'task_status': 'PLANNED'}));
    expect(planned.canStart, isTrue);
    expect(planned.canCancel, isFalse);
    final dispatched = ClaimCard.fromJson(
      cardJson({'task_status': 'DISPATCHED'}),
    );
    expect(dispatched.canComplete, isTrue);
    expect(dispatched.canStart || dispatched.canCancel, isFalse);
  });

  test(
    'presentation preserves original values and photo path without broadening access',
    () {
      final json = cardJson({'primary_image_path': 'authorized/object.jpg'});
      final card = ClaimCard.fromJson(json);
      expect(card.raw, json);
      expect(card.primaryImagePath, 'authorized/object.jpg');
      expect(() => card.raw['claim_id'] = 'other', throwsUnsupportedError);
    },
  );

  test(
    'stale reads and account changes cannot publish old private cards',
    () async {
      final first = Completer<Object?>(), second = Completer<Object?>();
      var calls = 0, user = 'ngo-a';
      final reader = ClaimCardsController(
        load: () => ++calls == 1 ? first.future : second.future,
        identity: () => user,
      );
      addTearDown(reader.dispose);
      final old = reader.refresh(), current = reader.refresh();
      second.complete([
        cardJson({'title': 'Current'}),
      ]);
      await current;
      first.complete([
        cardJson({'title': 'Stale'}),
      ]);
      await old;
      expect(reader.cards.single.title, 'Current');
      user = 'ngo-b';
      expect(reader.cards, isEmpty);
      expect(reader.fresh, isFalse);
      reader.invalidate();
      expect(reader.cards, isEmpty);
    },
  );

  test(
    'account switch during read and authorization failures clear rows',
    () async {
      var user = 'ngo-a';
      final pending = Completer<Object?>();
      final reader = ClaimCardsController(
        load: () => pending.future,
        identity: () => user,
      );
      addTearDown(reader.dispose);
      final read = reader.refresh();
      user = 'ngo-b';
      pending.complete([cardJson()]);
      await read;
      expect(reader.cards, isEmpty);
      expect(reader.error, isNotNull);
      expect(reader.fresh, isFalse);
    },
  );

  testWidgets('every tab uses badges and expired actions are disabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.2)),
          child: child!,
        ),
        home: MyClaimsPage(
          claimsLoader: () async => [
            cardJson(),
            cardJson({
              'claim_id': 'expired',
              'title': 'Expired claim',
              'lease_expires_at': '2026-10-22T01:00:00Z',
              'lease_is_expired': true,
              'lease_recovery_pending': true,
            }),
            cardJson({
              'claim_id': 'released',
              'title': 'Released claim',
              'claim_status': 'RELEASED',
              'source_type': 'HUB_BATCH',
            }),
            cardJson({
              'claim_id': 'reconciliation',
              'title': 'Handover review',
              'claim_status': 'RECONCILIATION_REQUIRED',
              'task_status': 'DISPATCHED',
            }),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in [
      'Active (1)',
      'Reconciliation (1)',
      'Expired (1)',
      'History (1)',
      'All (4)',
    ]) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
    }
    expect(find.text('Owned claim'), findsOneWidget);
    final activeBadge = find.widgetWithText(GeoStatusChip, 'Active');
    final activeCard = find.byKey(const ValueKey('claim-claim-1'));
    expect(
      tester.getCenter(activeBadge).dx,
      greaterThan(tester.getCenter(activeCard).dx),
    );
    expect(
      tester.getTopLeft(activeBadge).dy,
      lessThan(tester.getTopLeft(find.text('Owned claim')).dy),
    );
    expect(find.widgetWithText(GeoStatusChip, 'Direct Pickup'), findsOneWidget);
    expect(find.textContaining('Lease expiry (database)'), findsOneWidget);
    expect(find.textContaining('Claim ID:'), findsNothing);
    expect(find.textContaining('Pickup task ·'), findsNothing);

    Future<void> selectTab(String name) async {
      final chip = find.byKey(ValueKey('claims-tab-$name'));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    }

    await selectTab('expired');
    expect(find.text('Expired, awaiting recovery'), findsOneWidget);
    expect(find.textContaining('database controls recovery'), findsOneWidget);
    expect(find.text('Start Pickup'), findsNothing);
    expect(find.byKey(const ValueKey('claim-routes-expired')), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel Claim'))
          .onPressed,
      isNull,
    );
    await selectTab('history');
    expect(find.text('Released claim'), findsOneWidget);
    final releasedBadge = find.widgetWithText(GeoStatusChip, 'Released');
    expect(tester.widget<GeoStatusChip>(releasedBadge).tone, GeoTone.neutral);
    expect(find.widgetWithText(GeoStatusChip, 'Hub Collection'), findsOneWidget);
    await selectTab('reconciliation');
    final reconciliationBadge = find.widgetWithText(
      GeoStatusChip,
      'Reconciliation required',
    );
    expect(
      tester.widget<GeoStatusChip>(reconciliationBadge).tone,
      GeoTone.warning,
    );
    expect(
      find.textContaining('next pickup on its route stays blocked'),
      findsOneWidget,
    );
    expect(find.text('View reconciliation'), findsOneWidget);
    await selectTab('all');
    expect(find.text('Owned claim'), findsOneWidget);
    await selectTab('active');
    expect(find.text('Released claim'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'live claim actions open managed routing and refresh claims on return',
    (tester) async {
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MyClaimsPage(
            claimsLoader: () async {
              reads++;
              return [cardJson()];
            },
            routesBuilder: () => Scaffold(
              appBar: AppBar(title: const Text('Managed route destination')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Start Pickup'), findsNothing);
      expect(find.textContaining('Awaiting route planning'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('claim-routes-claim-1')));
      await tester.pumpAndSettle();
      expect(find.text('Managed route destination'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(reads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'refresh, resume, errors and deadline reads preserve selected tab',
    (tester) async {
      var reads = 0, offline = false;
      await tester.pumpWidget(
        MaterialApp(
          home: MyClaimsPage(
            claimsLoader: () async {
              reads++;
              if (offline) throw StateError('offline');
              return [
                cardJson({'lease_expires_at': '2026-10-22T01:00:02Z'}),
              ];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('claims-tab-expired')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('claims-tab-expired')),
            )
            .selected,
        isTrue,
      );
      offline = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Claim history unavailable'), findsOneWidget);
      expect(find.text('Owned claim'), findsNothing);
      offline = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      final before = reads;
      final refresh = tester
          .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
          .show();
      await tester.pumpAndSettle();
      await refresh;
      expect(reads, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'successful and rejected pickup actions refresh server evidence',
    (tester) async {
      for (final reject in [false, true]) {
        var reads = 0, actions = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: MyClaimsPage(
              key: ValueKey(reject),
              claimsLoader: () async {
                reads++;
                return [cardJson()];
              },
              actionRunner: (operation, id, request) async {
                expect(operation, 'START_PICKUP');
                actions++;
                if (reject) throw StateError('STALE_OR_EXPIRED_LEASE');
                return null;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Start Pickup'));
        await tester.pumpAndSettle();
        expect(actions, 1);
        expect(reads, 2);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cancellation retains request-id workflow and refreshes rejected result',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MyClaimsPage(
            claimsLoader: () async {
              reads++;
              return [cardJson()];
            },
            actionRunner: (operation, id, request) async {
              expect(operation, 'CANCEL_CLAIM');
              expect(request, isNotEmpty);
              return {'outcome': 'REJECTED', 'reason_code': 'ROUTE_ACTIVITY'};
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel Claim'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel claim'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'failed authorization read removes previously authorized photo data',
    () async {
      var denied = false;
      final reader = ClaimCardsController(
        identity: () => 'ngo-a',
        load: () async {
          if (denied) throw StateError('ACTIVE_NGO_ONLY');
          return [
            cardJson({'primary_image_path': 'owned/private.jpg'}),
          ];
        },
      );
      addTearDown(reader.dispose);
      await reader.refresh();
      expect(reader.cards.single.primaryImagePath, 'owned/private.jpg');
      denied = true;
      await reader.refresh();
      expect(reader.cards, isEmpty);
      expect(reader.fresh, isFalse);
      expect(reader.error, isNotNull);
    },
  );

  testWidgets('uncertain cancellation retries reuse the same request id', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MyClaimsPage(
          claimsLoader: () async => [cardJson()],
          actionRunner: (operation, id, request) async {
            requests.add(request);
            throw StateError('network outcome unknown');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.text('Cancel Claim'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel claim'));
      await tester.pumpAndSettle();
    }
    expect(requests, hasLength(2));
    expect(requests.first, isNotNull);
    expect(requests.last, requests.first);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('handover action uses the existing completion workflow', (
    tester,
  ) async {
    var operation = '', reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MyClaimsPage(
          claimsLoader: () async {
            reads++;
            return [
              cardJson({'task_status': 'DISPATCHED'}),
            ];
          },
          actionRunner: (action, id, request) async {
            operation = action;
            return null;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm Handover'));
    await tester.pumpAndSettle();
    expect(operation, 'COMPLETE_PICKUP');
    expect(reads, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reconciliation takes precedence and restricts pickup actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MyClaimsPage(
          claimsLoader: () async => [
            cardJson({'lease_status': 'RECONCILIATION_REQUIRED'}),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Reconciliation claims have their own section in My Claims.
    expect(find.text('Reconciliation required'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('claims-tab-reconciliation')));
    await tester.pumpAndSettle();
    expect(find.text('Reconciliation required'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('claim-reconciliation-claim-1')),
      findsOneWidget,
    );
    expect(find.text('Start Pickup'), findsNothing);
    expect(find.byKey(const ValueKey('claim-routes-claim-1')), findsNothing);
    expect(find.text('Claim details'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('return from claim details refreshes the selected view', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MyClaimsPage(
          claimsLoader: () async {
            reads++;
            return [cardJson()];
          },
          detailBuilder: (_) =>
              Scaffold(appBar: AppBar(title: const Text('Detail destination'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claim details'));
    await tester.pumpAndSettle();
    expect(find.text('Detail destination'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(reads, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Home excludes expired stored-ACTIVE claims from both action counts',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NgoHomePage(
            listingsLoader: () async => [],
            routingLoader: () async => true,
            ngoNameLoader: () async => 'Test NGO',
            claimsLoader: () async => [
              cardJson(),
              cardJson({
                'claim_id': 'expired',
                'lease_expires_at': '2026-10-22T01:00:00Z',
                'lease_is_expired': true,
                'lease_recovery_pending': true,
              }),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final active = find.ancestor(
        of: find.text('Active claims'),
        matching: find.byType(DashboardStatCard),
      );
      expect(
        find.descendant(of: active, matching: find.text('1')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
