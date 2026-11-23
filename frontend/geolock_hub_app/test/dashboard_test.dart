import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/claim_request.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/donation_status.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  'listing_id': 'listing-1',
  'server_now': '2026-10-22T01:00:00Z',
  'lease_is_expired': false,
  'lease_recovery_pending': false,
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
  for (final ready in [true, false]) {
    testWidgets(
      'dashboard hides positive capability notice and retains unavailable warning: $ready',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NgoHomePage(
                listingsLoader: () async => [],
                claimsLoader: () async => [],
                routingLoader: () async => ready,
                ngoNameLoader: () async => 'NGO',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Trusted route validation configured'), findsNothing);
        expect(
          find.text('The server remains authoritative for every claim.'),
          findsNothing,
        );
        expect(
          find.text('Claiming is unavailable'),
          ready ? findsNothing : findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('My Claims removes only the redundant app bar route icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: MyClaimsPage(claimsLoader: () async => [])),
    );
    await tester.pumpAndSettle();
    final bar = find.byType(AppBar);
    expect(
      find.descendant(of: bar, matching: find.byTooltip('Pickup routes')),
      findsNothing,
    );
    expect(find.text('My Claims'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('donor navigation has four donor-only destinations and selects', (
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
      'Donations',
      'Impact',
      'Profile',
    ]);
    expect(RoleNavigationBar.iconsForRole('DONOR'), [
      Icons.home_outlined,
      Icons.volunteer_activism_outlined,
      Icons.insights_outlined,
      Icons.person_outline,
    ]);
    expect(find.text('Map'), findsNothing);
    expect(find.text('Donation Map'), findsNothing);
    expect(find.text('Discover'), findsNothing);
    expect(find.text('Inventory'), findsNothing);
    await tester.tap(find.text('Donations'));
    expect(selected, 1);
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
      'Drop-offs',
      'Inventory',
      'Listings',
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
      'Awaiting Hub Selection',
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

    expect(find.text('Study Desk'), findsOneWidget);
    expect(find.text('18 kg'), findsOneWidget);
    expect(find.byIcon(Icons.volunteer_activism_outlined), findsOneWidget);
    await tester.tap(find.text('Study Desk'));
    await tester.pumpAndSettle();
    expect(find.text('Listing detail destination'), findsOneWidget);
  });

  group('NGO listings at 320 px with 120% text scaling', () {
    final direct = {
      ..._testListing('Rice bags'),
      'collection_path': 'DIRECT_HOUSEHOLD',
      'distance_m': 5200,
    };
    final hub = {
      ..._testListing('Vegetable boxes'),
      'source_type': 'HUB_BATCH',
      'collection_path': 'COMMUNITY_HUB',
      'listing_weight_kg': 9.75,
      'routing_status': 'NOT_ROUTABLE',
    };

    Future<void> pumpNarrow(WidgetTester tester, Widget page) async {
      await tester.binding.setSurfaceSize(const Size(320, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.2)),
            child: child!,
          ),
          home: page,
        ),
      );
      await tester.pumpAndSettle();
    }

    void expectBadgeAtTopRight(
      WidgetTester tester,
      String label,
      String title,
    ) {
      final badge = find.text(label);
      expect(badge, findsOneWidget);
      final card = find.ancestor(of: badge, matching: find.byType(Card));
      final badgeRect = tester.getRect(badge);
      expect(badgeRect.center.dx, greaterThan(tester.getCenter(card).dx));
      final titleRect = tester.getRect(find.text(title));
      expect(badgeRect.top, closeTo(titleRect.top, 6));
      expect(badgeRect.left, greaterThanOrEqualTo(titleRect.right));
    }

    void expectMetrics(WidgetTester tester) {
      final weight = find.text('12 kg');
      final distance = find.text('5.2 km by road');
      expect(weight, findsOneWidget);
      expect(distance, findsOneWidget);
      expect(find.text('9.75 kg'), findsOneWidget);
      final titleBottom = tester.getBottomLeft(find.text('Rice bags')).dy;
      expect(tester.getTopLeft(weight).dy, greaterThan(titleBottom));
      expect(tester.getTopLeft(distance).dy, greaterThan(titleBottom));
    }

    testWidgets(
      'dashboard shows both badges, distance, and a routing warning',
      (tester) async {
        await pumpNarrow(
          tester,
          Scaffold(
            body: NgoHomePage(
              listingsLoader: () async => [direct, hub],
              claimsLoader: () async => [],
              routingLoader: () async => true,
              ngoNameLoader: () async => 'Test NGO',
            ),
          ),
        );

        expectBadgeAtTopRight(tester, 'Direct Pickup', 'Rice bags');
        expectBadgeAtTopRight(tester, 'Hub Collection', 'Vegetable boxes');
        expectMetrics(tester);
        expect(find.textContaining('Road route ready'), findsNothing);
        expect(
          find.textContaining('No drivable road was found'),
          findsOneWidget,
        );
        Rect statCard(String label) {
          final text = find.text(label);
          expect(
            tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
            isFalse,
          );
          return tester.getRect(
            find.ancestor(of: text, matching: find.byType(Card)),
          );
        }

        final discovery = statCard('Discovery results');
        final active = statCard('Active claims');
        final pickups = statCard('Pickups to action');
        expect(discovery.top, active.top);
        expect(discovery.width, active.width);
        expect(pickups.top, greaterThan(discovery.bottom));
        expect(pickups.top, greaterThan(active.bottom));
        expect(pickups.left, discovery.left);
        expect(pickups.right, active.right);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'eligible page shows one explanation and retains claim warnings',
      (tester) async {
        await pumpNarrow(
          tester,
          EligibleListingsPage(
            listingsLoader: () async => [direct, hub],
            routingLoader: () async => false,
          ),
        );

        expectBadgeAtTopRight(tester, 'Direct Pickup', 'Rice bags');
        expectBadgeAtTopRight(tester, 'Hub Collection', 'Vegetable boxes');
        expect(
          find.text(
            "Listings are based on your NGO's verified location and road-distance eligibility. Eligibility is checked again when you claim.",
          ),
          findsOneWidget,
        );
        expectMetrics(tester);
        expect(find.textContaining('claiming unavailable'), findsNWidgets(2));
        expect(find.textContaining('Road route ready'), findsNothing);
        expect(
          find.textContaining('The database rechecks eligibility'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('ready eligible card wraps metrics and hides routine notices', (
      tester,
    ) async {
      await pumpNarrow(
        tester,
        Scaffold(
          body: ListView(
            children: [
              EligibleListingCard(
                listing: {
                  ...direct,
                  'listing_weight_kg': 12345.67,
                  'distance_m': 123456789,
                },
                capabilityReady: true,
                onOpen: () {},
              ),
            ],
          ),
        ),
      );

      final weight = find.text('12345.67 kg');
      final distance = find.text('123456.8 km by road');
      expect(weight, findsOneWidget);
      expect(distance, findsOneWidget);
      expect(
        tester.getTopLeft(distance).dy,
        greaterThan(tester.getBottomLeft(weight).dy),
      );
      expect(find.textContaining('Road route ready'), findsNothing);
      expect(
        find.textContaining('The database rechecks eligibility'),
        findsNothing,
      );
      expect(find.textContaining('claiming unavailable'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'eligible listings history opens the signed-in NGO saved attempts',
    (tester) async {
      const actor = '11111111-1111-4111-8111-111111111111';
      SharedPreferences.setMockInitialValues({
        '${claimRequestPrefix(actor)}test-listing': 'test-request',
        '${claimRequestPrefix('another-ngo')}other-listing': 'other-request',
      });
      await tester.runAsync(() async {
        final supabase = await Supabase.initialize(
          url: 'http://localhost:54321',
          publishableKey: 'offline-test-key',
          authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
          ),
          httpClient: MockClient((request) async {
            expect(request.url.path, '/auth/v1/token');
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
            return http.Response(
              jsonEncode({
                'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
                'token_type': 'bearer',
                'expires_in': 3600,
                'refresh_token': 'offline-test-refresh',
                'user': {'id': actor, 'app_metadata': {}, 'user_metadata': {}},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(supabase.dispose);
        await supabase.client.auth.signInWithPassword(
          email: 'ngo@example.invalid',
          password: 'offline-test',
        );
      });

      var listingReads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: EligibleListingsPage(
            listingsLoader: () async {
              listingReads++;
              return [];
            },
            routingLoader: () async => false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Saved claim attempts'));
      await tester.pumpAndSettle();

      expect(find.text('Saved claim attempts'), findsOneWidget);
      expect(find.text('Listing test-listing'), findsOneWidget);
      expect(find.text('Listing other-listing'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Eligible Listings'), findsOneWidget);
      expect(listingReads, 2);
    },
  );

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
            'listing_id': 'listing-1',
            'server_now': '2026-10-22T01:00:00Z',
            'lease_is_expired': false,
            'lease_recovery_pending': false,
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
      final recommendation = find.descendant(
        of: find.byType(ListingPreviewCard),
        matching: find.text('Household Essentials'),
      );
      expect(recommendation, findsOneWidget);

      committed = true; // The backend has confirmed the claim.
      await tester.tap(find.text('My Claims'));
      await tester.pumpAndSettle();
      expect(find.text('Household Essentials'), findsOneWidget);
      expect(claimReads, 2);

      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(recommendation, findsNothing);
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
