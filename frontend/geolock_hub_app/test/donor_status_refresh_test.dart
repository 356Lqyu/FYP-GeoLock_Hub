import 'package:flutter/material.dart';
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
      await tester.tap(find.text('Claimed'));
      await tester.pumpAndSettle();
      expect(find.text('No matching donations'), findsOneWidget);
      await tester.tap(find.text('All'));
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
    final homeAvailable = find.descendant(
      of: find.byType(DonorHomePage),
      matching: find.text('Available'),
    );
    expect(homeAvailable, findsOneWidget);
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
