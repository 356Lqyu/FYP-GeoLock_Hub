// Offline presentation tests for the NGO / Donor role styling that follows the
// Hub Admin visual language. No Supabase project is contacted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/hub_admin/hub_widgets.dart' show HubColors;
import 'package:geolock_hub_app/routing/claim_coordination.dart';
import 'package:geolock_hub_app/routing/reconciliation_status.dart';
import 'package:geolock_hub_app/ui/geolock_role_style.dart';

Map<String, dynamic> _coordination() => {
  'contract': 'geolock.claim-coordination.v2',
  'claim_id': 'claim-1',
  'case_id': 'case-1',
  'case_status': 'OPEN',
  'evidence_round': 1,
  'evidence_version': 1,
  'blocker': 'AWAITING_COUNTERPART',
  'can_submit': false,
  'can_resolve': false,
  'can_request_review': false,
  'can_accept_review': false,
  'review_waiting': false,
  'statements': <dynamic>[],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('shared reconciliation states get distinct, Hub Admin tones', () {
    final tones = {
      GeoLockStatusText.actionRequired: geoStatusTone(GeoLockStatusText.actionRequired),
      GeoLockStatusText.awaitingCounterpart: geoStatusTone(GeoLockStatusText.awaitingCounterpart),
      GeoLockStatusText.resolvedCollected: geoStatusTone(GeoLockStatusText.resolvedCollected),
      GeoLockStatusText.resolvedReleased: geoStatusTone(GeoLockStatusText.resolvedReleased),
      GeoLockStatusText.reconciliationRequired: geoStatusTone(GeoLockStatusText.reconciliationRequired),
    };
    expect(tones.values.toSet(), hasLength(5), reason: 'each is visually distinct');
    expect(geoStatusTone(GeoLockStatusText.underReview), HubColors.blue);
    expect(geoStatusTone(GeoLockStatusText.expiredAwaitingRecovery), HubColors.amber);
    expect(geoStatusTone(GeoLockStatusText.expiredReleased), HubColors.muted);
    expect(geoStatusTone('Next pickup — blocked'), HubColors.red);
    expect(
      geoStatusTone('Handover · ${GeoLockStatusText.underReview}'),
      HubColors.blue,
    );
    expect(geoStatusTone('Something new'), HubColors.ink);
  });

  testWidgets('role theme gives cards the Hub Admin card style', (tester) async {
    late ThemeData inside;
    await tester.pumpWidget(
      MaterialApp(
        home: GeoRoleTheme(
          child: Builder(
            builder: (context) {
              inside = Theme.of(context);
              return const Scaffold(body: Card(child: Text('card')));
            },
          ),
        ),
      ),
    );
    expect(inside.cardTheme.elevation, 0);
    expect(inside.cardTheme.color, Colors.white);
    final shape = inside.cardTheme.shape as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(16));
    expect(shape.side.color, HubColors.line);
    expect(find.text('card'), findsOneWidget);
  });

  testWidgets('status pill stays a Chip with the same label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: GeoStatusChip(GeoLockStatusText.reconciliationRequired)),
      ),
    );
    expect(
      find.widgetWithText(Chip, GeoLockStatusText.reconciliationRequired),
      findsOneWidget,
    );
  });

  testWidgets(
    'reconciliation summary is styled only on NGO / Donor pages, not Hub Admin',
    (tester) async {
      ClaimCoordinationRepository repo() => ClaimCoordinationRepository(
        identity: () => 'user',
        rpc: (name, params) async => _coordination(),
      );
      // Hub Admin embeds the panel directly (no GeoRoleScope): unchanged chip.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClaimCoordinationPanel(claimId: 'claim-1', repository: repo()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reconciliation-status')), findsOneWidget);
      expect(find.byType(GeoStatusChip), findsNothing);
      // NGO / Donor reconciliation page: same panel, shared role styling.
      await tester.pumpWidget(
        MaterialApp(
          home: ClaimReconciliationPage(
            claimId: 'claim-1',
            viewerRole: 'NGO',
            repository: repo(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GeoRoleTheme), findsOneWidget);
      expect(find.byType(GeoStatusChip), findsOneWidget);
      expect(find.text(GeoLockStatusText.awaitingCounterpart), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('donor My Donations renders in the role style on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DonorMyDonationsPage(
            donationsLoader: () async => [
              {
                'donation_id': 'donation-a',
                'title': 'Rice and canned food for families',
                'donation_status': 'PICKUP_IN_PROGRESS',
                'collection_path': 'DIRECT_PICKUP',
                'total_weight_kg': 20,
                'item_count': 3,
              },
            ],
            reconciliationCasesLoader: () async => [
              {
                'case_id': 'case-a',
                'claim_id': 'claim-a',
                'donation_id': 'donation-a',
                'source_type': 'DIRECT_DONATION',
                'case_status': 'MANUAL_REVIEW',
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GeoRoleTheme), findsOneWidget);
    expect(tester.takeException(), isNull);
    final reconciliationFilter = find.widgetWithText(
      ChoiceChip,
      'Reconciliation (1)',
    );
    await tester.ensureVisible(reconciliationFilter);
    await tester.tap(reconciliationFilter);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(Chip, 'Handover · ${GeoLockStatusText.underReview}'),
      findsOneWidget,
    );
    expect(find.text('View Reconciliation'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('NGO My Claims renders in the role style on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MyClaimsPage(
          claimsLoader: () async => [
            {
              'claim_id': 'claim-r',
              'listing_id': 'listing-r',
              'claim_status': 'RECONCILIATION_REQUIRED',
              'lease_status': 'RECONCILIATION_REQUIRED',
              'task_status': 'DISPATCHED',
              'source_type': 'DIRECT_DONATION',
              'title': 'A long donation title that should wrap safely',
            },
          ],
          reconciliationBuilder: (_) => const Scaffold(body: Text('recon')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GeoRoleTheme), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('claims-tab-reconciliation')));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(Chip, GeoLockStatusText.reconciliationRequired),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
