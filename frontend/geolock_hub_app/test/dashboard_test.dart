import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:geolock_hub_app/donation_pages.dart';

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
