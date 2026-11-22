// Offline UI/contract tests for the routing, lease-expiry and reconciliation
// UX changes. Synthetic transports only: no Supabase project is contacted.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolock_hub_app/claim_card.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/routing/claim_coordination.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/reconciliation_status.dart';
import 'package:geolock_hub_app/routing/routing_feedback.dart';
import 'option_c_fake_backend.dart';
import 'route_details_presentation_test.dart' as sample;

/// Records planner request IDs and can reject Start with a DETAIL value.
class TrackingBackend extends Backend {
  final planRequestIds = <String>[];
  String? rejectStartDetail;
  int startAttempts = 0;

  @override
  Future<Object?> plan(Map<String, dynamic> body) {
    planRequestIds.add(body['request_id'] as String);
    return super.plan(body);
  }

  @override
  Future<Object?> rpc(String name, Map<String, dynamic> p) async {
    if (name == 'authorize_and_start_my_route') startAttempts++;
    if (name == 'authorize_and_start_my_route' && rejectStartDetail != null) {
      calls.add(name);
      throw PostgrestException(
        message: 'CANDIDATE_DEADLINE_PASSED',
        code: 'P0001',
        details: rejectStartDetail,
      );
    }
    return super.rpc(name, p);
  }
}

Future<void> pumpRoutes(WidgetTester tester, Backend b) async {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: NgoRoutesPage(
        repository: b.repo(),
        mapBuilder: (m) => Text('Map markers: ${m.length}'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pumpAndSettle();
}

Future<void> generate(WidgetTester tester, Finder button) async {
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

Future<void> pressStart(WidgetTester tester) async {
  final start = find.byKey(const Key('start-generated-route'));
  await tester.ensureVisible(start);
  await tester.pump();
  await tester.tap(start);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

FilledButton startButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.byKey(const Key('start-generated-route')),
);

/// Route-detail transport: one authoritative route row plus claim cards.
class DetailBackend {
  DetailBackend(this.route, {this.cards = const []});
  Map<String, dynamic> route;
  List<Map<String, dynamic>> cards;
  int routeReads = 0;
  final calls = <String>[];
  late final repo = NgoRoutingRepository(
    identity: () => 'synthetic-ngo',
    rpc: (name, params) async {
      calls.add(name);
      if (name == 'get_my_claim_cards_v2') return cards;
      if (name == 'get_my_authorized_route') {
        routeReads++;
        return route;
      }
      fail('Unexpected protected RPC from the route detail page: $name');
    },
  );
}

Map<String, dynamic> startedRoute(List<Map<String, dynamic>> stops) => {
  ...sample.fixture(start: false),
  'route_status': 'IN_PROGRESS',
  'actual_started_at': '2026-10-28T16:52:00Z',
  'can_cancel': false,
  'stops': stops,
};

Map<String, dynamic> stop(int i, Map<String, dynamic> values) => {
  ...(sample.fixture()['stops'] as List<Map<String, dynamic>>)[i],
  'can_start': false,
  'can_complete': false,
  ...values,
};

Future<void> pumpDetail(
  WidgetTester tester,
  DetailBackend b, {
  ClaimCoordinationRepository? coordination,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: NgoRouteDetailPage(
        routeId: 'synthetic-route',
        repository: b.repo,
        mapBuilder: (_) => const SizedBox(height: 30),
        coordinationRepository: coordination,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> coordinationRow({
  String caseStatus = 'OPEN',
  bool canSubmit = false,
  bool canResolve = false,
  bool canRequestReview = false,
  bool canAcceptReview = false,
  bool reviewWaiting = false,
  String? blocker = 'AWAITING_COUNTERPART',
  List<Map<String, dynamic>> statements = const [
    {'round': 1, 'participant': 'NGO', 'handover_confirmed': false},
  ],
}) => {
  'contract': 'geolock.claim-coordination.v2',
  'claim_id': 'claim-1',
  'case_id': 'case-1',
  'case_status': caseStatus,
  'evidence_round': 1,
  'evidence_version': 2,
  'blocker': blocker,
  'can_submit': canSubmit,
  'can_resolve': canResolve,
  'can_request_review': canRequestReview,
  'can_accept_review': canAcceptReview,
  'review_waiting': reviewWaiting,
  'statements': statements,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Feature A — expired route proposal', () {
    test('only rollback-final Start rejections count as expiry', () {
      for (final code in [
        'CANDIDATE_EXPIRED',
        'CANDIDATE_DEADLINE_PASSED',
        'PLAN_STALE_TASK',
        'STOP_LEASE_INSUFFICIENT',
      ]) {
        expect(proposalTerminalRejections, contains(code));
      }
      for (final code in [
        'ROUTE_START_OUTCOME_UNKNOWN',
        'ROUTE_START_NOT_CONFIRMED',
        'REQUEST_CONFLICT',
        'AUTHENTICATION_REQUIRED',
      ]) {
        expect(proposalTerminalRejections, isNot(contains(code)), reason: code);
      }
    });

    test('a confirmed lease expiry is distinguished from other causes', () {
      expect(
        proposalExpiredMessage(code: 'CANDIDATE_DEADLINE_PASSED', detail: 'LEASE'),
        proposalClaimsInvalidMessage,
      );
      expect(
        proposalExpiredReason(code: 'CANDIDATE_DEADLINE_PASSED', detail: 'LEASE'),
        contains("claim's lease"),
      );
      expect(proposalExpiredMessage(code: 'PLAN_STALE_TASK'), proposalClaimsInvalidMessage);
      expect(
        proposalExpiredReason(code: 'PLAN_STALE_TASK'),
        contains('changed after this route was generated'),
      );
      expect(
        proposalExpiredMessage(code: 'PLAN_STALE_VEHICLE'),
        contains('vehicle changed'),
      );
      expect(proposalExpiredReason(code: 'CANDIDATE_EXPIRED'), isNull);
      expect(
        proposalExpiredMessage(deadlineReason: 'SERVICE_WINDOW'),
        contains('pickup window'),
      );
    });

    testWidgets('a valid proposal shows no expiry and can be started', (
      tester,
    ) async {
      final b = TrackingBackend();
      await pumpRoutes(tester, b);
      await generate(tester, find.byKey(const Key('generate-route')));
      expect(find.byKey(const Key('route-proposal-expired')), findsNothing);
      expect(startButton(tester).onPressed, isNotNull);
      expect(b.startAttempts, 0, reason: 'generation never starts a route');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'stale claim rejected at Start shows Route proposal expired and disables Start',
      (tester) async {
        final b = TrackingBackend()..rejectStartWith = 'PLAN_STALE_TASK';
        await pumpRoutes(tester, b);
        await generate(tester, find.byKey(const Key('generate-route')));
        expect(startButton(tester).onPressed, isNotNull);
        await pressStart(tester);
        expect(b.startAttempts, 1);
        expect(find.text('Route proposal expired'), findsOneWidget);
        expect(find.text(proposalClaimsInvalidMessage), findsOneWidget);
        expect(
          find.textContaining('changed after this route was generated'),
          findsOneWidget,
        );
        // Candidate status is still "startable" (clock-based), but the
        // confirmed rejection keeps Start disabled after the refresh.
        expect(startButton(tester).onPressed, isNull);
        expect(find.byKey(const Key('generate-new-route')), findsOneWidget);
        expect(b.routeId, isNull, reason: 'the rejection rolled back');
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('lease deadline rejection names the confirmed lease expiry', (
      tester,
    ) async {
      final b = TrackingBackend()..rejectStartDetail = 'LEASE';
      await pumpRoutes(tester, b);
      await generate(tester, find.byKey(const Key('generate-route')));
      await pressStart(tester);
      expect(find.text('Route proposal expired'), findsOneWidget);
      expect(find.text(proposalClaimsInvalidMessage), findsOneWidget);
      expect(find.textContaining("claim's lease"), findsOneWidget);
      expect(startButton(tester).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'Generate New Route creates a fresh planning request and never starts it',
      (tester) async {
        final b = TrackingBackend()..rejectStartWith = 'PLAN_STALE_TASK';
        await pumpRoutes(tester, b);
        await generate(tester, find.byKey(const Key('generate-route')));
        await pressStart(tester);
        expect(b.planRequestIds, hasLength(1));
        await generate(tester, find.byKey(const Key('generate-new-route')));
        expect(b.planRequestIds, hasLength(2));
        expect(b.planRequestIds.toSet(), hasLength(2), reason: 'new request ID');
        expect(b.startAttempts, 1, reason: 'the new route is not auto-started');
        expect(find.byKey(const Key('route-proposal-expired')), findsNothing);
        expect(startButton(tester).onPressed, isNotNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('an unknown start outcome is never shown as expiry', (
      tester,
    ) async {
      final b = TrackingBackend()
        ..timeoutBeforeCommit = true
        ..failReceiptReads = 1;
      await pumpRoutes(tester, b);
      await generate(tester, find.byKey(const Key('generate-route')));
      await pressStart(tester);
      expect(find.byKey(const Key('route-proposal-expired')), findsNothing);
      expect(
        find.textContaining('route start was not confirmed'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Features B–D — started route detail', () {
    testWidgets('pending recovery vs confirmed safe release', (tester) async {
      final b = DetailBackend(
        startedRoute([
          stop(0, {'task_status': 'COLLECTED'}),
          stop(1, {'lease_expired_pending_recovery': true}),
          stop(2, {
            'task_status': 'STALE',
            'deferred_status': 'RESOLVED_UNCOLLECTED',
          }),
        ]),
        cards: [
          {'claim_id': 'claim-2', 'claim_status': 'RELEASED', 'lease_is_expired': true},
        ],
      );
      await pumpDetail(tester, b);
      expect(find.text(GeoLockStatusText.expiredAwaitingRecovery), findsOneWidget);
      expect(find.text(GeoLockStatusText.expiredReleased), findsOneWidget);
      expect(find.textContaining('no action is needed'), findsOneWidget);
      // The released stop stays visible but has no pickup actions.
      expect(find.text('3. Test 42'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Complete pickup'), findsNWidgets(2));
      expect(find.text('View Reconciliation'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('released stop is not called expired without claim evidence', (
      tester,
    ) async {
      final b = DetailBackend(
        startedRoute([
          stop(0, {'task_status': 'COLLECTED'}),
          stop(1, {'task_status': 'STALE', 'deferred_status': 'RESOLVED_UNCOLLECTED'}),
          stop(2, {}),
        ]),
      );
      await pumpDetail(tester, b);
      expect(find.text('Not collected — resolved'), findsOneWidget);
      expect(find.text(GeoLockStatusText.expiredReleased), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'dispatched pickup needing reconciliation blocks the next stop and opens reconciliation',
      (tester) async {
        final b = DetailBackend({
          ...startedRoute([
            stop(0, {'task_status': 'COLLECTED'}),
            stop(1, {'task_status': 'DISPATCHED', 'needs_reconciliation': true}),
            stop(2, {'task_status': 'PLANNED'}),
          ]),
          'dispatch_block_reason': 'PREVIOUS_PICKUP_UNRESOLVED',
          'next_executable_task_id': 'task-2',
        });
        final coordinationCalls = <String>[];
        final coordination = ClaimCoordinationRepository(
          identity: () => 'synthetic-ngo',
          rpc: (name, params) async {
            coordinationCalls.add(name);
            expect(name, 'get_my_claim_coordination');
            expect(params, {'p_claim': 'claim-1'});
            return coordinationRow();
          },
        );
        await pumpDetail(tester, b, coordination: coordination);
        expect(find.text('Stop 2 — Reconciliation required'), findsOneWidget);
        expect(
          find.textContaining("lease expired after dispatch"),
          findsOneWidget,
        );
        expect(find.byKey(const Key('stop-reconciliation-blocks-next')), findsOneWidget);
        expect(find.text('Next pickup — blocked'), findsOneWidget);
        expect(
          find.textContaining('stays blocked until it is resolved'),
          findsOneWidget,
        );
        expect(find.text('Start Route'), findsNothing);
        final readsBefore = b.routeReads;
        final view = find.byKey(const Key('view-reconciliation-task-1'));
        await tester.ensureVisible(view);
        await tester.pump();
        await tester.tap(view);
        await tester.pumpAndSettle();
        expect(find.text('Stop 2 reconciliation'), findsOneWidget);
        expect(find.byKey(const Key('reconciliation-route-notice')), findsOneWidget);
        expect(find.text(GeoLockStatusText.awaitingCounterpart), findsOneWidget);
        expect(find.text('Your statement (this round): Submitted'), findsOneWidget);
        expect(
          find.text('Statement from the donor (this round): Not yet submitted'),
          findsOneWidget,
        );
        expect(coordinationCalls, ['get_my_claim_coordination']);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(b.routeReads, greaterThan(readsBefore), reason: 'authoritative reload');
        expect(b.calls, isNot(contains('start_pickup')));
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('Cancel Unstarted Route is hidden on an IN_PROGRESS route', (
      tester,
    ) async {
      final b = DetailBackend({
        ...startedRoute([
          stop(0, {'task_status': 'DISPATCHED', 'can_complete': true}),
          stop(1, {}),
          stop(2, {}),
        ]),
        // Even a (hypothetical) true flag must not surface it once started.
        'can_cancel': true,
      });
      await pumpDetail(tester, b);
      expect(find.text('Cancel unstarted route'), findsNothing);
      expect(find.text('Cancel Route — No Pickups Completed'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Cancel stays available for a cancellable AUTHORISED route', (
      tester,
    ) async {
      final b = DetailBackend({...sample.fixture(), 'can_cancel': true});
      await pumpDetail(tester, b);
      expect(find.text('Cancel unstarted route'), findsOneWidget);
      b.route = {...sample.fixture(), 'can_cancel': false};
      await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
      await tester.pumpAndSettle();
      expect(find.text('Cancel unstarted route'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Features E–G — reconciliation status', () {
    test('case statuses map to the shared wording', () {
      expect(
        reconciliationSummary(coordinationRow(caseStatus: 'RESOLVED_COLLECTED')).status,
        GeoLockStatusText.resolvedCollected,
      );
      expect(
        reconciliationSummary(coordinationRow(caseStatus: 'RESOLVED_RELEASED')).status,
        GeoLockStatusText.resolvedReleased,
      );
      expect(
        reconciliationSummary(coordinationRow(caseStatus: 'MANUAL_REVIEW', blocker: null)).status,
        GeoLockStatusText.underReview,
      );
      expect(
        reconciliationSummary(coordinationRow()).status,
        GeoLockStatusText.awaitingCounterpart,
      );
      final action = reconciliationSummary(
        coordinationRow(canSubmit: true, statements: const []),
        viewerRole: 'DONOR',
      );
      expect(action.status, GeoLockStatusText.actionRequired);
      expect(action.nextAction, contains('Submit your handover statement'));
      expect(action.viewerResponded, isFalse);
      expect(
        reconciliationSummary(coordinationRow(reviewWaiting: true)).status,
        GeoLockStatusText.underReview,
      );
    });

    test('HUB_BATCH keeps the hub administrator as the counterpart', () {
      expect(
        reconciliationCounterpartLabel(viewerRole: 'NGO', sourceType: 'HUB_BATCH'),
        'hub administrator',
      );
      expect(
        reconciliationCounterpartLabel(viewerRole: 'NGO', sourceType: 'DIRECT_DONATION'),
        'donor',
      );
      expect(reconciliationCounterpartLabel(viewerRole: 'HUB_ADMIN'), 'NGO');
      expect(reconciliationCounterpartLabel(viewerRole: 'DONOR'), 'NGO');
      final hub = reconciliationSummary(
        coordinationRow(),
        viewerRole: 'HUB_ADMIN',
        sourceType: 'HUB_BATCH',
      );
      expect(hub.viewerResponded, isFalse, reason: 'only the NGO has answered');
      expect(hub.counterpartResponded, isTrue);
      expect(hub.nextAction, contains('NGO'));
    });

    testWidgets('panel shows the counterpart for an NGO hub-batch case', (
      tester,
    ) async {
      final repo = ClaimCoordinationRepository(
        identity: () => 'ngo',
        rpc: (name, params) async => coordinationRow(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClaimCoordinationPanel(
              claimId: 'claim-1',
              repository: repo,
              viewerRole: 'NGO',
              sourceType: 'HUB_BATCH',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Statement from the hub administrator (this round): Not yet submitted',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('donor'), findsNothing);
    });

    test('duplicate submissions are refused while one is in flight', () async {
      final gate = Completer<void>();
      var writes = 0;
      final repo = ClaimCoordinationRepository(
        identity: () => 'owner',
        rpc: (name, params) async {
          if (name == 'get_my_coordination_receipt') {
            return {'request_id': params['p_request'], 'found': false};
          }
          writes++;
          await gate.future;
          return {'outcome': 'SUCCESS', 'claim_id': 'claim-1'};
        },
      );
      final params = {
        'p_claim': 'claim-1',
        'p_handover_confirmed': true,
        'p_expected_round': 1,
        'p_expected_version': 2,
      };
      final first = repo.send('claim-1', 'submit_claim_reconciliation_v2', params);
      await expectLater(
        repo.send('claim-1', 'submit_claim_reconciliation_v2', params),
        throwsStateError,
      );
      gate.complete();
      await first;
      expect(writes, 1);
    });

    test('reconciliation claims get their own My Claims section', () {
      final card = ClaimCard.fromJson({
        'claim_id': 'claim-1',
        'claim_status': 'RECONCILIATION_REQUIRED',
        'lease_status': 'RECONCILIATION_REQUIRED',
      });
      expect(card.tab, ClaimTab.reconciliation);
      expect(card.badge, GeoLockStatusText.reconciliationRequired);
    });

    testWidgets('NGO My Claims opens reconciliation from its section', (
      tester,
    ) async {
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
                'title': 'Reconciling donation',
              },
            ],
            reconciliationBuilder: (card) =>
                Scaffold(body: Text('Reconciliation page ${card.claimId}')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reconciling donation'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('claims-tab-reconciliation')));
      await tester.pumpAndSettle();
      expect(find.text('Reconciling donation'), findsOneWidget);
      expect(find.textContaining('next pickup on its route stays blocked'), findsOneWidget);
      final open = find.byKey(const ValueKey('claim-reconciliation-claim-r'));
      await tester.ensureVisible(open);
      await tester.pump();
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.text('Reconciliation page claim-r'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    Widget donorPage({
      required Future<List<Map<String, dynamic>>> Function() cases,
    }) => MaterialApp(
      home: Scaffold(
        body: DonorMyDonationsPage(
          donationsLoader: () async => [
            {
              'donation_id': 'donation-a',
              'title': 'Rice donation',
              'donation_status': 'PICKUP_IN_PROGRESS',
              'collection_path': 'DIRECT_PICKUP',
              'total_weight_kg': 20,
              'item_count': 1,
            },
            {
              'donation_id': 'donation-b',
              'title': 'Oil donation',
              'donation_status': 'CLAIMED',
              'collection_path': 'DIRECT_PICKUP',
              'total_weight_kg': 5,
              'item_count': 1,
            },
          ],
          reconciliationCasesLoader: cases,
        ),
      ),
    );

    testWidgets('donor Reconciliation filter shows only the donor case', (
      tester,
    ) async {
      await tester.pumpWidget(
        donorPage(
          cases: () async => [
            {
              'case_id': 'case-a',
              'claim_id': 'claim-a',
              'donation_id': 'donation-a',
              'source_type': 'DIRECT_DONATION',
              'case_status': 'OPEN',
            },
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Rice donation'), findsWidgets);
      expect(find.textContaining('Oil donation'), findsWidgets);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Reconciliation'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Rice donation'), findsWidgets);
      expect(find.textContaining('Oil donation'), findsNothing);
      expect(
        find.text('Handover · ${GeoLockStatusText.reconciliationRequired}'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('donor reconciliation read failure hides nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        donorPage(cases: () async => throw TimeoutException('synthetic')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Rice donation'), findsWidgets);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Reconciliation'));
      await tester.pumpAndSettle();
      expect(find.text('Reconciliation status unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Single reconciliation interface', () {
    Map<String, dynamic> caseRow({
      String claim = 'claim-d',
      String caseStatus = 'OPEN',
      bool canSubmit = true,
      List<Map<String, dynamic>> statements = const [],
    }) => {
      ...coordinationRow(
        caseStatus: caseStatus,
        canSubmit: canSubmit,
        blocker: caseStatus == 'OPEN' ? 'AWAITING_COUNTERPART' : null,
        statements: statements,
      ),
      'claim_id': claim,
    };

    Map<String, dynamic> donationDetail() => {
      'status': 'PICKUP_IN_PROGRESS',
      'collection_path': 'DIRECT_PICKUP',
      'total_weight_kg': 20,
      'items': <dynamic>[],
      'images': <dynamic>[],
      'reservations': <dynamic>[],
      'audit_events': <dynamic>[],
    };

    Future<void> pumpDonationDetail(
      WidgetTester tester,
      ClaimCoordinationRepository repo,
    ) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: DonationDetailPage(
            donationId: 'donation-d',
            detailLoader: () async => donationDetail(),
            coordinationRepository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'Donation Details shows a status link, not a second response form',
      (tester) async {
        final reads = <String>[];
        final repo = ClaimCoordinationRepository(
          identity: () => 'donor',
          rpc: (name, params) async {
            reads.add(name);
            expect(name, 'get_my_donation_coordination');
            expect(params, {'p_donation': 'donation-d'});
            return {
              'donation_id': 'donation-d',
              'contexts': [caseRow()],
            };
          },
        );
        await pumpDonationDetail(tester, repo);
        expect(find.byKey(const Key('reconciliation-link')), findsOneWidget);
        expect(find.text(GeoLockStatusText.actionRequired), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Handover'), findsNothing);
        expect(find.widgetWithText(OutlinedButton, 'No Handover'), findsNothing);
        final open = find.byKey(const Key('open-reconciliation'));
        await tester.ensureVisible(open);
        await tester.pump();
        await tester.tap(open);
        await tester.pumpAndSettle();
        // The donor answers here, in the existing v2 panel.
        expect(find.widgetWithText(FilledButton, 'Handover'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'No Handover'), findsOneWidget);
        expect(reads, everyElement('get_my_donation_coordination'));
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('Donation Details without a case shows no reconciliation link', (
      tester,
    ) async {
      final repo = ClaimCoordinationRepository(
        identity: () => 'donor',
        rpc: (name, params) async => {'donation_id': 'donation-d', 'contexts': []},
      );
      await pumpDonationDetail(tester, repo);
      expect(find.byKey(const Key('reconciliation-link')), findsNothing);
      expect(find.text('View Reconciliation'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a resolved donor case stays reviewable from Donation Details', (
      tester,
    ) async {
      final repo = ClaimCoordinationRepository(
        identity: () => 'donor',
        rpc: (name, params) async => {
          'donation_id': 'donation-d',
          'contexts': [caseRow(caseStatus: 'RESOLVED_RELEASED', canSubmit: false)],
        },
      );
      await pumpDonationDetail(tester, repo);
      expect(find.text(GeoLockStatusText.resolvedReleased), findsOneWidget);
      expect(find.byKey(const Key('open-reconciliation')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'donor My Donations opens the response interface with independent statements',
      (tester) async {
        final reads = <Map<String, dynamic>>[];
        final repo = ClaimCoordinationRepository(
          identity: () => 'donor',
          rpc: (name, params) async {
            expect(name, 'get_my_claim_coordination');
            reads.add(params);
            return caseRow(
              claim: 'claim-a',
              statements: const [
                {'round': 1, 'participant': 'NGO', 'handover_confirmed': true},
              ],
            );
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DonorMyDonationsPage(
                donationsLoader: () async => [
                  {
                    'donation_id': 'donation-a',
                    'title': 'Rice donation',
                    'donation_status': 'PICKUP_IN_PROGRESS',
                    'collection_path': 'DIRECT_PICKUP',
                    'total_weight_kg': 20,
                    'item_count': 1,
                  },
                ],
                reconciliationCasesLoader: () async => [
                  {
                    'case_id': 'case-a',
                    'claim_id': 'claim-a',
                    'donation_id': 'donation-a',
                    'source_type': 'DIRECT_DONATION',
                    'case_status': 'OPEN',
                  },
                ],
                coordinationRepository: repo,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Reconciliation'));
        await tester.pumpAndSettle();
        final view = find.byKey(
          const ValueKey('donation-view-reconciliation-donation-a'),
        );
        await tester.ensureVisible(view);
        await tester.pump();
        await tester.tap(view);
        await tester.pumpAndSettle();
        expect(reads, [
          {'p_claim': 'claim-a'},
        ]);
        expect(find.text('Your statement (this round): Not yet submitted'), findsOneWidget);
        expect(
          find.text('Statement from the NGO (this round): Submitted'),
          findsOneWidget,
        );
        expect(find.widgetWithText(FilledButton, 'Handover'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('NGO My Claims View reconciliation opens the existing v2 panel', (
      tester,
    ) async {
      final repo = ClaimCoordinationRepository(
        identity: () => 'ngo',
        rpc: (name, params) async {
          expect(name, 'get_my_claim_coordination');
          expect(params, {'p_claim': 'claim-r'});
          return caseRow(claim: 'claim-r');
        },
      );
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
                'source_type': 'HUB_BATCH',
                'title': 'Batch pickup',
              },
            ],
            coordinationRepository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('claims-tab-reconciliation')));
      await tester.pumpAndSettle();
      final open = find.byKey(const ValueKey('claim-reconciliation-claim-r'));
      await tester.ensureVisible(open);
      await tester.pump();
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.byType(ClaimCoordinationPanel), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Handover'), findsOneWidget);
      // HUB_BATCH: the counterpart stays the hub administrator.
      expect(
        find.text('Statement from the hub administrator (this round): Not yet submitted'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('reconciliation-route-notice')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
