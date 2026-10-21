import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/donation_status.dart';

class _MyClaimsNavigationHarness extends StatefulWidget {
  final Future<Object?> Function() claimsLoader;
  final VoidCallback onSuccessfulClaim;

  const _MyClaimsNavigationHarness({
    required this.claimsLoader,
    required this.onSuccessfulClaim,
  });

  @override
  State<_MyClaimsNavigationHarness> createState() =>
      _MyClaimsNavigationHarnessState();
}

class _MyClaimsNavigationHarnessState
    extends State<_MyClaimsNavigationHarness> {
  var _selectedIndex = 0;
  var _claimsRefreshSignal = 0;

  Future<void> _simulateConfirmedClaim() async {
    widget.onSuccessfulClaim();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MyClaimsPage(claimsLoader: widget.claimsLoader),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _selectedIndex,
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('NGO Dashboard'),
              FilledButton(
                onPressed: _simulateConfirmedClaim,
                child: const Text('Claim eligible listing'),
              ),
            ],
          ),
        ),
        MyClaimsPage(
          refreshSignal: _claimsRefreshSignal,
          claimsLoader: widget.claimsLoader,
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) => setState(() {
        _selectedIndex = index;
        if (index == 1) _claimsRefreshSignal++;
      }),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          label: 'Dashboard',
        ),
        NavigationDestination(
          icon: Icon(Icons.assignment_outlined),
          label: 'My Claims',
        ),
      ],
    ),
  );
}

class _NgoRefreshHarness extends StatefulWidget {
  final Future<Object?> Function() homeListingsLoader;
  final Future<Object?> Function() homeClaimsLoader;
  final Future<Object?> Function() discoverLoader;
  final Future<Object?> Function() claimsLoader;

  const _NgoRefreshHarness({
    required this.homeListingsLoader,
    required this.homeClaimsLoader,
    required this.discoverLoader,
    required this.claimsLoader,
  });

  @override
  State<_NgoRefreshHarness> createState() => _NgoRefreshHarnessState();
}

class _NgoRefreshHarnessState extends State<_NgoRefreshHarness> {
  int _index = 0;
  final _signals = List<int>.filled(3, 0);

  void _select(int index) {
    if (index == _index) return;
    setState(() {
      _index = index;
      _signals[index]++;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _index,
      children: [
        Column(
          children: [
            Expanded(
              child: NgoHomePage(
                refreshSignal: _signals[0],
                listingsLoader: widget.homeListingsLoader,
                claimsLoader: widget.homeClaimsLoader,
                routingLoader: () async => true,
                ngoNameLoader: () async => 'Test NGO',
              ),
            ),
          ],
        ),
        EligibleListingsPage(
          refreshSignal: _signals[1],
          listingsLoader: widget.discoverLoader,
          routingLoader: () async => true,
        ),
        MyClaimsPage(
          refreshSignal: _signals[2],
          claimsLoader: widget.claimsLoader,
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _index,
      onDestinationSelected: _select,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.search), label: 'Discover'),
        NavigationDestination(icon: Icon(Icons.assignment), label: 'My Claims'),
      ],
    ),
  );
}

Map<String, dynamic> _testListing(String title) => {
  'listing_id': 'listing-$title',
  'source_type': 'DIRECT_DONATION',
  'title': title,
  'listing_weight_kg': 12,
  'collection_path': 'DIRECT_PICKUP',
  'routing_status': 'READY',
  'primary_image_path': null,
};

Map<String, dynamic> _testClaim() => {
  'claim_id': 'claim-1',
  'claim_status': 'ACTIVE',
  'claimed_at': '2026-10-22T01:00:00Z',
  'lease_id': 'lease-1',
  'lease_status': 'ACTIVE',
  'lease_expires_at': '2026-10-22T07:00:00Z',
  'task_status': 'CONFIRMED',
  'source_type': 'DIRECT_DONATION',
  'listing_weight_kg': 12,
  'title': 'Household Essentials',
  'primary_image_path': null,
};

void main() {
  testWidgets('donor navigation has five donor-only destinations and selects', (
    tester,
  ) async {
    var selected = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: RoleNavigationBar(
            role: 'DONOR',
            selectedIndex: 0,
            onDestinationSelected: (index) => selected = index,
          ),
        ),
      ),
    );

    expect(RoleNavigationBar.labelsForRole('DONOR'), [
      'Home',
      'Map',
      'Donations',
      'Impact',
      'Profile',
    ]);
    expect(find.text('Discover'), findsNothing);
    expect(find.text('Inventory'), findsNothing);
    await tester.tap(find.text('Donations'));
    expect(selected, 2);
  });

  test('each role receives its own five-tab labels', () {
    expect(RoleNavigationBar.labelsForRole('NGO'), [
      'Home',
      'Discover',
      'My Claims',
      'Pickups',
      'Profile',
    ]);
    expect(RoleNavigationBar.labelsForRole('HUB_ADMIN'), [
      'Home',
      'Inventory',
      'Receive',
      'Collections',
      'Profile',
    ]);
  });

  test('donation state labels reflect the simplified lifecycle', () {
    expect(
      donationStatusLabel(
        status: 'SUBMITTED',
        collectionPath: 'HUB_COLLECTION',
      ),
      'Awaiting Hub Selection',
    );
    expect(
      donationStatusLabel(
        status: 'READY_FOR_PICKUP',
        collectionPath: 'DIRECT_PICKUP',
      ),
      'Ready for Pickup',
    );
    expect(
      donationStatusLabel(status: 'HUB_ASSIGNED', reservationStatus: 'EXPIRED'),
      'Hub Reservation Expired',
    );
    // Legacy rows can be displayed safely during migration rollout, but the
    // application no longer treats VALIDATED as an operational state.
    expect(
      donationStatusLabel(
        status: 'VALIDATED',
        collectionPath: 'HUB_COLLECTION',
      ),
      'Awaiting Hub Selection',
    );
  });

  testWidgets('dashboard statistics render live values and labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DashboardStatCard(
            label: 'Active donations',
            value: '3',
            icon: Icons.inventory_2_outlined,
          ),
        ),
      ),
    );
    expect(find.text('Active donations'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('NGO home listing preview opens details with image fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListingPreviewCard(
            row: {
              'listing_id': 'listing-1',
              'source_type': 'DIRECT_DONATION',
              'title': 'Study Desk',
              'listing_weight_kg': 18,
              'collection_path': 'DIRECT_PICKUP',
              'distance_m': 5200,
              'routing_status': 'READY',
              'primary_image_path': null,
            },
            onTap: () => Navigator.push(
              tester.element(find.byType(ListingPreviewCard)),
              MaterialPageRoute(
                builder: (_) =>
                    const Scaffold(body: Text('Listing detail destination')),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Study Desk · 18 kg'), findsOneWidget);
    expect(find.byIcon(Icons.volunteer_activism_outlined), findsOneWidget);
    await tester.tap(find.text('Study Desk · 18 kg'));
    await tester.pumpAndSettle();
    expect(find.text('Listing detail destination'), findsOneWidget);
  });

  testWidgets(
    'Claim → My Claims → Dashboard → My Claims reloads backend data',
    (tester) async {
      var claimCommitted = false;
      var reads = 0;
      Future<Object?> loadClaims() async {
        reads++;
        if (!claimCommitted) return <Map<String, dynamic>>[];
        return <Map<String, dynamic>>[
          {
            'claim_id': 'claim-1',
            'claim_status': 'ACTIVE',
            'claimed_at': '2026-10-22T01:00:00Z',
            'lease_id': 'lease-1',
            'lease_status': 'ACTIVE',
            'lease_expires_at': '2026-10-22T07:00:00Z',
            'task_status': 'CONFIRMED',
            'source_type': 'DIRECT_DONATION',
            'listing_weight_kg': 12,
            'title': 'Household Essentials',
            'primary_image_path': null,
          },
        ];
      }

      await tester.pumpWidget(
        MaterialApp(
          home: _MyClaimsNavigationHarness(
            claimsLoader: loadClaims,
            onSuccessfulClaim: () => claimCommitted = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 1); // The IndexedStack page has its initial snapshot.

      await tester.tap(find.text('Claim eligible listing'));
      await tester.pumpAndSettle();
      expect(find.text('Household Essentials'), findsOneWidget);
      expect(reads, 2); // The post-claim route performs a fresh read.

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('NGO Dashboard'), findsOneWidget);

      await tester.tap(find.text('My Claims'));
      await tester.pumpAndSettle();
      expect(find.text('Household Essentials'), findsOneWidget);
      expect(reads, 3); // Bottom-tab re-entry refreshes the kept-alive page.
    },
  );

  testWidgets(
    'Claim → My Claims → Home refresh removes claimed recommendation',
    (tester) async {
      var committed = false;
      var listingReads = 0;
      var claimReads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _NgoRefreshHarness(
            homeListingsLoader: () async {
              listingReads++;
              return committed
                  ? <Map<String, dynamic>>[]
                  : [_testListing('Household Essentials')];
            },
            homeClaimsLoader: () async => <Map<String, dynamic>>[],
            discoverLoader: () async => <Map<String, dynamic>>[],
            claimsLoader: () async {
              claimReads++;
              return committed ? [_testClaim()] : <Map<String, dynamic>>[];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Household Essentials · 12 kg'), findsOneWidget);

      committed = true; // The backend has confirmed the claim.
      await tester.tap(find.text('My Claims'));
      await tester.pumpAndSettle();
      expect(find.text('Household Essentials'), findsOneWidget);
      expect(claimReads, 2);

      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.text('Household Essentials · 12 kg'), findsNothing);
      expect(find.text('No eligible listings returned'), findsOneWidget);
      expect(listingReads, 2);
    },
  );

  testWidgets('Home → Discover refreshes eligible listings', (tester) async {
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: _NgoRefreshHarness(
          homeListingsLoader: () async => <Map<String, dynamic>>[],
          homeClaimsLoader: () async => <Map<String, dynamic>>[],
          discoverLoader: () async {
            reads++;
            return [_testListing('Discover result $reads')];
          },
          claimsLoader: () async => <Map<String, dynamic>>[],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 1);
    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.textContaining('Discover result 2'), findsOneWidget);
  });

  testWidgets('Discover → My Claims refreshes claims', (tester) async {
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: _NgoRefreshHarness(
          homeListingsLoader: () async => <Map<String, dynamic>>[],
          homeClaimsLoader: () async => <Map<String, dynamic>>[],
          discoverLoader: () async => <Map<String, dynamic>>[],
          claimsLoader: () async {
            reads++;
            return reads == 1 ? <Map<String, dynamic>>[] : [_testClaim()];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 1);
    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My Claims'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('Household Essentials'), findsOneWidget);
  });

  testWidgets('rapid tab switching serializes reads and shows latest data', (
    tester,
  ) async {
    final firstRead = Completer<Object?>();
    final secondRead = Completer<Object?>();
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: _NgoRefreshHarness(
          homeListingsLoader: () async => <Map<String, dynamic>>[],
          homeClaimsLoader: () async => <Map<String, dynamic>>[],
          discoverLoader: () {
            reads++;
            return reads == 1 ? firstRead.future : secondRead.future;
          },
          claimsLoader: () async => <Map<String, dynamic>>[],
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Discover'));
    await tester.pump();
    await tester.tap(find.text('Home'));
    await tester.pump();
    await tester.tap(find.text('Discover'));
    await tester.pump();
    expect(reads, 1); // The first RPC is still active; no overlap.

    firstRead.complete([_testListing('Stale result')]);
    await tester.pump();
    await tester.pump();
    expect(reads, 2);
    expect(find.textContaining('Stale result'), findsNothing);

    secondRead.complete([_testListing('Current result')]);
    await tester.pumpAndSettle();
    expect(find.textContaining('Current result'), findsOneWidget);
    expect(find.textContaining('Stale result'), findsNothing);
  });

  testWidgets(
    'donation summary uses neutral image placeholder and real fields',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DonationSummaryCard(
              donation: {
                'title': 'Books',
                'donation_status': 'COLLECTED',
                'collection_path': 'HUB_COLLECTION',
                'total_weight_kg': 4.5,
                'item_count': 2,
                'created_at': '2026-10-15T00:00:00Z',
              },
              onTap: () {},
            ),
          ),
        ),
      );
      expect(find.text('Books'), findsOneWidget);
      expect(find.text('Collected'), findsOneWidget);
      expect(find.text('2 items · 4.5 kg'), findsOneWidget);
      expect(find.byIcon(Icons.volunteer_activism_outlined), findsOneWidget);
    },
  );

  testWidgets('donation photo carousel has a graceful no-photo state', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DonationPhotoCarousel(paths: [])),
      ),
    );
    expect(find.text('No donation photos'), findsOneWidget);
  });

  testWidgets('donation photo carousel changes photo and counter', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DonationPhotoCarousel(
            paths: const ['first', 'second'],
            urlResolver: (path) async => 'https://example.invalid/$path',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Next photo'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous photo'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
  });
}
