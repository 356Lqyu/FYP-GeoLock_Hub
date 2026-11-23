import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/routing/route_resolution_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DonorTabHarness extends StatefulWidget {
  const _DonorTabHarness({super.key});

  @override
  State<_DonorTabHarness> createState() => _DonorTabHarnessState();
}

class _DonorTabHarnessState extends State<_DonorTabHarness> {
  int _index = 0;
  final _signals = [0, 0];
  String _status = 'CLAIMED';
  int homeReads = 0;
  int listReads = 0;

  List<Map<String, dynamic>> _load() => [
    {
      'donation_id': 'donation-a',
      'title': 'Rice donation',
      'donation_status': _status,
      'collection_path': 'DIRECT_PICKUP',
      'total_weight_kg': 20,
      'item_count': 1,
      'created_at': '2026-10-22T01:00:00Z',
    },
  ];

  void _select(int index) => setState(() {
    _index = index;
    _signals[index]++;
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _index,
      children: [
        DonorHomePage(
          onDonations: () => _select(1),
          refreshSignal: _signals[0],
          donationsLoader: () async {
            homeReads++;
            return _load();
          },
          profileLoader: () async => {'full_name': 'Test Donor'},
        ),
        DonorMyDonationsPage(
          refreshSignal: _signals[1],
          donationsLoader: () async {
            listReads++;
            return _load();
          },
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _index,
      onDestinationSelected: _select,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.list), label: 'My Donations'),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: () => setState(() => _status = 'AVAILABLE'),
      child: const Icon(Icons.refresh),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('donation filters count all loaded rows at 320 px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const statuses = [
      'AVAILABLE',
      'AT_HUB',
      'CLAIMED',
      'PICKUP_IN_PROGRESS',
      'COLLECTED',
      'CANCELLED',
    ];
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.2)),
          child: child!,
        ),
        home: Scaffold(
          body: DonorMyDonationsPage(
            donationsLoader: () async => [
              for (final status in statuses)
                {
                  'donation_id': status,
                  'title': 'Donation $status',
                  'donation_status': status,
                  'collection_path': 'DIRECT_PICKUP',
                },
            ],
            reconciliationCasesLoader: () async => [
              {
                'donation_id': 'PICKUP_IN_PROGRESS',
                'source_type': 'DIRECT_DONATION',
                'case_status': 'OPEN',
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const filters = {
      'All': statuses,
      'Active': ['AVAILABLE', 'AT_HUB', 'CLAIMED', 'PICKUP_IN_PROGRESS'],
      'Reconciliation': ['PICKUP_IN_PROGRESS'],
      'At Hub': ['AT_HUB'],
      'Claimed': ['CLAIMED'],
      'Picked Up': ['PICKUP_IN_PROGRESS', 'COLLECTED'],
      'Completed': ['COLLECTED'],
      'Cancelled': ['CANCELLED'],
    };
    for (final entry in filters.entries) {
      final chip = find.widgetWithText(
        ChoiceChip,
        '${entry.key} (${entry.value.length})',
      );
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
      final list = find.byType(ListView);
      expect(
        tester.widget<ListView>(list).childrenDelegate.estimatedChildCount,
        entry.value.length,
      );
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      for (final status in entry.value) {
        final donation = find.text('Donation $status');
        await tester.scrollUntilVisible(donation, 150, scrollable: scrollable);
        expect(donation, findsOneWidget);
      }
    }
    await tester.enterText(find.byType(TextField), 'missing donation');
    await tester.pumpAndSettle();
    expect(find.text('No matching donations'), findsOneWidget);
    for (final entry in filters.entries) {
      final chip = find.widgetWithText(
        ChoiceChip,
        '${entry.key} (${entry.value.length})',
      );
      final label = find.descendant(of: chip, matching: find.byType(Text));
      await Scrollable.ensureVisible(tester.element(label), alignment: 0.5);
      await tester.pumpAndSettle();
      expect(tester.renderObject<RenderParagraph>(label).didExceedMaxLines, isFalse);
      expect(chip.hitTestable(), findsOneWidget);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 480.0]) {
    testWidgets('donation cards keep long statuses readable at $width px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const title = 'Fresh vegetables for local families';
      const status = 'Hub Assignment Needs Review';
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(1.2),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: DonorMyDonationsPage(
              donationsLoader: () async => [
                {
                  'donation_id': 'hub-donation',
                  'title': title,
                  'donation_status': 'HUB_ASSIGNED',
                  'collection_path': 'COMMUNITY_HUB',
                  'total_weight_kg': 8.5,
                  'item_count': 2,
                  'created_at': '2026-10-22T01:00:00Z',
                },
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final titleText = find.text(title);
      final badgeText = find.text(status);
      expect(
        tester.renderObject<RenderParagraph>(titleText).didExceedMaxLines,
        isFalse,
      );
      expect(
        tester.renderObject<RenderParagraph>(badgeText).didExceedMaxLines,
        isFalse,
      );
      expect(
        tester.getTopLeft(badgeText).dx,
        greaterThanOrEqualTo(tester.getTopRight(titleText).dx),
      );
      expect(
        tester.getTopLeft(badgeText).dy,
        closeTo(tester.getTopLeft(titleText).dy, 6),
      );
      expect(find.text('Hub Collection'), findsOneWidget);
      expect(find.text('Collection method'), findsOneWidget);
      expect(find.text('Weight'), findsOneWidget);
      expect(find.text('8.5 kg'), findsOneWidget);
      expect(find.text('Item entries'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Total item quantity'), findsNothing);
      expect(find.text('Road distance'), findsNothing);
      expect(find.text('Created'), findsOneWidget);
      expect(find.text('22/10/2026'), findsOneWidget);
      expect(find.text('View details →'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'All (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reconciliation count waits for cases and ignores search', (
    tester,
  ) async {
    final cases = Completer<List<Map<String, dynamic>>>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DonorMyDonationsPage(
            donationsLoader: () async => [
              for (final title in ['Rice', 'Oil', 'Blankets', 'Vegetables'])
                {'donation_id': title, 'title': title},
            ],
            reconciliationCasesLoader: () => cases.future,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chip = find.byKey(const ValueKey('donations-filter-Reconciliation'));
    expect(find.text('Reconciliation (—)'), findsOneWidget);
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pump();
    expect(find.text('No handover reconciliation needed'), findsNothing);
    cases.complete([
      for (final (id, source, status) in [
        ('Rice', 'DIRECT_DONATION', 'OPEN'),
        ('Rice', 'DIRECT_DONATION', 'MANUAL_REVIEW'),
        ('Oil', 'DIRECT_DONATION', 'OPEN'),
        ('Blankets', 'HUB_BATCH', 'OPEN'),
        ('Vegetables', 'DIRECT_DONATION', 'RESOLVED'),
        ('Missing donation', 'DIRECT_DONATION', 'OPEN'),
      ])
        {'donation_id': id, 'source_type': source, 'case_status': status},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Reconciliation (2)'), findsOneWidget);
    expect(find.text('Rice'), findsOneWidget);
    expect(find.text('Oil'), findsOneWidget);
    expect(find.text('Blankets'), findsNothing);
    expect(find.text('Vegetables'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Rice');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(DonationSummaryCard),
        matching: find.text('Rice'),
      ),
      findsOneWidget,
    );
    expect(find.text('Oil'), findsNothing);
    expect(find.text('Reconciliation (2)'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Blankets');
    await tester.pumpAndSettle();
    expect(find.text('No matching donations'), findsOneWidget);
    expect(find.text('Reconciliation (2)'), findsOneWidget);
  });

  testWidgets('a successful empty case read shows reconciliation zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DonorMyDonationsPage(
            donationsLoader: () async => [
              {'donation_id': 'case-free', 'title': 'Rice'},
            ],
            reconciliationCasesLoader: () async => [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chip = find.widgetWithText(ChoiceChip, 'Reconciliation (0)');
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.text('No handover reconciliation needed'), findsOneWidget);
  });

  for (final description in [null, '', '  ', 'Four sealed bags.']) {
    testWidgets(
      'donor detail shows only a nonblank donation description ($description)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: DonationDetailPage(
              donationId: 'donation-a',
              detailLoader: () async => {
                'title': 'Rice donation',
                'description': description,
                'status': 'AVAILABLE',
                'collection_path': 'DIRECT_HOUSEHOLD',
                'items': [
                  {
                    'item_name': 'Rice bag',
                    'description': 'Item-specific notes',
                  },
                ],
                'images': [],
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final visible = description?.trim().isNotEmpty ?? false;
        expect(
          find.text('Donation description'),
          visible ? findsOneWidget : findsNothing,
        );
        if (visible) expect(find.text(description!), findsOneWidget);
        expect(find.byType(DonationPhotoCarousel), findsOneWidget);
      },
    );
  }

  testWidgets('donor tabs reload authoritative status when revisited', (
    tester,
  ) async {
    final key = GlobalKey<_DonorTabHarnessState>();
    await tester.pumpWidget(MaterialApp(home: _DonorTabHarness(key: key)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Donations'));
    await tester.pumpAndSettle();
    final cardClaimed = find.descendant(
      of: find.byType(DonationSummaryCard),
      matching: find.text('Claimed'),
    );
    expect(cardClaimed, findsOneWidget);

    // Represents the backend transition while the app is on another tab.
    await tester.tap(find.byIcon(Icons.home));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Donations'));
    await tester.pumpAndSettle();
    expect(key.currentState!.listReads, greaterThanOrEqualTo(3));
    final cardAvailable = find.descendant(
      of: find.byType(DonationSummaryCard),
      matching: find.text('Available'),
    );
    expect(cardAvailable, findsOneWidget);
    expect(cardClaimed, findsNothing);
    final claimed = find.text('Claimed (0)');
    await tester.ensureVisible(claimed);
    await tester.pumpAndSettle();
    await tester.tap(claimed);
    await tester.pumpAndSettle();
    expect(find.text('No matching donations'), findsOneWidget);
    final all = find.text('All (1)');
    await tester.ensureVisible(all);
    await tester.pumpAndSettle();
    await tester.tap(all);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.home));
    await tester.pumpAndSettle();
      final activeCard = find.widgetWithText(
        DashboardStatCard,
        'Active donations',
      );
      expect(
        find.descendant(of: activeCard, matching: find.text('1')),
        findsOneWidget,
      );
    await tester.ensureVisible(find.text('Rice donation'));
    await tester.pumpAndSettle();
    final homeCard = find.descendant(
      of: find.byType(DonorHomePage),
      matching: find.byType(DonationSummaryCard),
    );
    for (final label in [
      'Available',
      'Weight',
      '20 kg',
      'Collection method',
      'Direct Pickup',
      'Item entries',
      'Created',
      '22/10/2026',
    ]) {
      expect(
        find.descendant(of: homeCard, matching: find.text(label)),
        findsOneWidget,
      );
    }
  });

  testWidgets(
    'detail uses the refreshed backend status after confirmed action',
    (tester) async {
      var status = 'CLAIMED';
      var detailReads = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, args) async {
          if (name == 'get_my_donation_route_resolution') {
            return {
              'contract': 'geolock.donor-route-resolution.v1',
              'donation_id': 'donation-a',
              'enabled': true,
              'contexts': <dynamic>[],
            };
          }
          if (name == 'get_my_donation_claim_reconciliation') {
            return {
              'contract': 'geolock.donor-claim-reconciliation.v1',
              'donation_id': 'donation-a',
            'history_truncated': false,
            'association_conflict': false,
              'contexts': [
                {
                'donation_id': 'donation-a',
                  'claim_id': 'claim-a',
                  'task_id': 'task-a',
                  'route_id': 'route-a',
                  'case_id': 'case-a',
                  'title': 'Rice donation',
                'source_type': 'DIRECT_DONATION',
                'case_status': 'OPEN',
                  'can_submit_evidence': true,
                  'allowed_assertions': ['COLLECTED', 'NOT_COLLECTED'],
                },
              ],
            };
          }
          if (name == 'get_my_claim_reconciliation_receipt') {
            return {'found': false, 'request_id': args['p_request']};
          }
          if (name == 'submit_claim_reconciliation') {
            status = 'AVAILABLE';
            return {'case_id': 'case-a', 'outcome': 'RESOLVED'};
          }
          throw StateError('Unexpected RPC: $name');
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DonationDetailPage(
            donationId: 'donation-a',
            outcomeRepository: repo,
            detailLoader: () async {
              detailReads++;
              return {
                'status': status,
                'collection_path': 'DIRECT_PICKUP',
                'total_weight_kg': 20,
                'items': <dynamic>[],
                'images': <dynamic>[],
                'reservations': <dynamic>[],
                'audit_events': <dynamic>[],
              };
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Claimed'), findsOneWidget);

      await tester.tap(find.text('Not Collected — Goods remain with you'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit statement'));
      await tester.pumpAndSettle();

      // The detail is re-read via the protected injected reader after the
      // receipt and should show that reader's status verbatim.
      expect(detailReads, greaterThanOrEqualTo(2));
      expect(status, 'AVAILABLE');
      expect(find.text('Available'), findsOneWidget);
      expect(find.text('Claimed'), findsNothing);
    },
  );
}
