// Synthetic protected transports only. No hosted Supabase requests.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/routing/route_resolution_repository.dart';
import 'package:geolock_hub_app/routing/route_resolution_page.dart';

const no = 'NO_HANDOVER_SOURCE_RETAINS_GOODS';
Map<String, dynamic> binding() => {
  'claim_id': 'claim-a',
  'task_id': 'task-a',
  'route_id': 'route-a',
  'case_id': 'case-a',
  'case_version': 2,
  'initial_class': 'DISPATCHED',
  'resolution_status': 'AWAITING_EVIDENCE',
  'can_submit_evidence': true,
  'allowed_assertions': [no, 'HANDOVER_TO_NGO_CONFIRMED', 'UNKNOWN_CUSTODY'],
  'donor_evidence': {'assertion': null},
  'ngo_evidence': {'assertion': null},
};
Map<String, dynamic> donor({
  bool enabled = true,
  List<Map<String, dynamic>>? rows,
}) => {
  'contract': 'geolock.donor-route-resolution.v1',
  'donation_id': 'donation-a',
  'title': 'My synthetic goods',
  'enabled': enabled,
  'history_truncated': false,
  'association_conflict': false,
  'contexts': rows ?? [binding()],
};
Map<String, dynamic> participant() => {
  'contract': 'geolock.route-resolution.v1',
  'route_id': 'route-a',
  'case_id': 'case-a',
  'version': 2,
  'enabled': true,
  'is_owner': false,
  'status': 'AWAITING_EVIDENCE',
  'items': [
    {'task_id': 'task-a', 'claim_id': 'claim-a', 'initial_class': 'DISPATCHED'},
  ],
};

Map<String, dynamic> donorClaim() => {
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
      'case_id': 'claim-case-a',
      'title': 'My synthetic goods',
      'source_type': 'DIRECT_DONATION',
      'case_status': 'OPEN',
      'can_submit_evidence': true,
      'allowed_assertions': ['COLLECTED', 'NOT_COLLECTED'],
    },
  ],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('participant inbox refresh remains a read-only action', (
    tester,
  ) async {
    final calls = <String>[];
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'donor-a',
      rpc: (name, _) async {
        calls.add(name);
        return {
          'contract': 'geolock.route-resolution.v1',
          'cases': <dynamic>[],
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: RouteResolutionInboxPage(repository: repo)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Refresh cases'));
    await tester.pumpAndSettle();
    expect(calls, [
      'list_my_route_resolution_cases',
      'list_my_route_resolution_cases',
    ]);
    expect(tester.takeException(), isNull);
  });
  Future<void> open(WidgetTester tester, RouteResolutionRepository repo) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RouteResolutionPage(
          routeId: 'route-a',
          donorDonationId: 'donation-a',
          repository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('protected donation context enables navigation without a write', (
    tester,
  ) async {
    final calls = <String>[];
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'donor-a',
      rpc: (name, args) async {
        calls.add(name);
        if (name == 'get_my_donation_route_resolution') {
          expect(args, {'p_donation': 'donation-a'});
          return donor();
        }
        if (name == 'get_my_donation_claim_reconciliation') return donorClaim();
        if (name == 'get_my_claim_reconciliation_receipt') {
          return {'found': false, 'request_id': args['p_request']};
        }
        expect(name, 'get_my_route_resolution');
        return participant();
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
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Open legacy route case'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Open legacy route case'));
    await tester.pumpAndSettle();
    expect(find.text('Reconciliation details'), findsOneWidget);
    expect(find.text('My synthetic goods'), findsOneWidget);
    expect(calls.every((n) => n.startsWith('get_')), isTrue);
  });

  testWidgets(
    'donor explicitly submits a donation-scoped Collected statement',
    (tester) async {
      final writes = <Map<String, dynamic>>[];
      var confirmedRefreshes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, args) async {
          if (name == 'get_my_donation_route_resolution') {
            return donor();
          }
          if (name == 'get_my_donation_claim_reconciliation') {
            return donorClaim();
          }
          if (name == 'get_my_claim_reconciliation_receipt') {
            return {'found': false, 'request_id': args['p_request']};
          }
          expect(name, 'submit_claim_reconciliation');
          writes.add(args);
          return {'case_id': 'claim-case-a', 'outcome': 'AWAITING_COUNTERPART'};
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DonorPickupOutcomeNotice(
                donationId: 'donation-a',
                repository: repo,
                onConfirmed: () async {
                  confirmedRefreshes++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Collected — Goods handed over to the NGO'),
        findsOneWidget,
      );
      expect(
        find.text('Not Collected — Goods remain with you'),
        findsOneWidget,
      );
      expect(writes, isEmpty);
      await tester.tap(find.text('Collected — Goods handed over to the NGO'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.tap(find.text('Submit statement'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(writes.single['p_claim'], 'claim-a');
      expect(writes.single['p_handover_confirmed'], true);
      expect(writes.single['p_request'], isNotEmpty);
      expect(confirmedRefreshes, 1);
      expect(
        find.textContaining('Statement recorded:'),
        findsAtLeastNWidgets(1),
      );
    },
  );

  testWidgets(
    'failed donor statement does not signal a confirmed status refresh',
    (tester) async {
      var confirmedRefreshes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, _) async {
          if (name == 'get_my_donation_route_resolution') return donor();
          if (name == 'get_my_donation_claim_reconciliation') {
            return donorClaim();
          }
          if (name == 'get_my_claim_reconciliation_receipt') {
            return {'found': false, 'request_id': 'request-a'};
          }
          throw StateError('network interrupted');
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DonorPickupOutcomeNotice(
                donationId: 'donation-a',
                repository: repo,
                onConfirmed: () async {
                  confirmedRefreshes++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not Collected — Goods remain with you'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit statement'));
      await tester.pumpAndSettle();
      expect(confirmedRefreshes, 0);
      expect(find.textContaining('network interrupted'), findsOneWidget);
    },
  );

  testWidgets(
    'donor already-submitted evidence remains visible without a second submit button',
    (tester) async {
      final baseClaim = donorClaim();
      final baseRow = Map<String, dynamic>.from(
        (baseClaim['contexts'] as List).first as Map,
      );
      final recorded = {
        ...baseClaim,
        'contexts': [
          {
            ...baseRow,
            'can_submit_evidence': false,
            'blocking_reason': 'DONOR_EVIDENCE_ALREADY_RECORDED',
            'donor_evidence': {'handover_confirmed': false},
            'ngo_evidence': {'handover_confirmed': null},
          },
        ],
      };
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, _) async {
          if (name == 'get_my_donation_route_resolution') return donor();
          if (name == 'get_my_donation_claim_reconciliation') return recorded;
          if (name == 'get_my_route_resolution') return participant();
          throw StateError('Unexpected write or RPC: $name');
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
      expect(
        find.textContaining('already recorded for this claim'),
        findsOneWidget,
      );
      expect(find.text('Your statement: Not Collected'), findsOneWidget);
      expect(
        find.text('Collected — Goods handed over to the NGO'),
        findsNothing,
      );
      expect(find.text('Not Collected — Goods remain with you'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'donor chooses an explicit statement for exactly the protected task',
    (tester) async {
      final writes = <Map<String, dynamic>>[];
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, args) async {
          if (name == 'get_my_donation_route_resolution') return donor();
          if (name == 'get_my_route_resolution') return participant();
          expect(name, 'submit_route_resolution_evidence');
          writes.add(args);
          return {
            'case_id': 'case-a',
            'version': 3,
            'status': 'AWAITING_EVIDENCE',
          };
        },
      );
      await open(tester, repo);
      expect(
        find.text('Vehicle and collected goods accounted for at depot'),
        findsNothing,
      );
      expect(writes, isEmpty);
      await tester.tap(find.text('Not Collected'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.tap(find.text('Confirm statement'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(writes.single['p_task'], 'task-a');
      expect(writes.single['p_case'], 'case-a');
      expect(writes.single['p_version'], 2);
      expect(writes.single['p_assertion'], no);
      expect(await repo.pending('route-a'), isEmpty);
    },
  );

  for (final field in [
    'task_id',
    'claim_id',
    'case_id',
    'route_id',
    'case_version',
  ]) {
    test('changed $field stops before evidence writer', () async {
      final calls = <String>[];
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, _) async {
          calls.add(name);
          return donor();
        },
      );
      final expected = {
        ...binding(),
        field: field == 'case_version' ? 1 : 'wrong',
      };
      await expectLater(
        repo.submitDonor('donation-a', expected, no),
        throwsA(isA<ResolutionVersionConflict>()),
      );
      expect(calls, ['get_my_donation_route_resolution']);
      expect(await repo.pending('route-a'), isEmpty);
    });
  }

  test(
    'ambiguous or truncated complete read never becomes actionable',
    () async {
      expect(
        actionableDonorContext({...donor(), 'history_truncated': true}),
        isNull,
      );
      expect(
        actionableDonorContext({...donor(), 'association_conflict': true}),
        isNull,
      );
      expect(
        actionableDonorContext(
          donor(
            rows: [
              binding(),
              {...binding(), 'task_id': 'another'},
            ],
          ),
        ),
        isNull,
      );
      expect(actionableDonorContext(donor(enabled: false)), isNull);
    },
  );

  testWidgets(
    'refresh disables stale confirmation until the protected read finishes',
    (tester) async {
      var reads = 0;
      final response = Completer<Map<String, dynamic>>();
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, _) async {
          if (name == 'get_my_donation_route_resolution') {
            if (++reads == 1) return donor();
            return response.future;
          }
          if (name == 'get_my_donation_claim_reconciliation') {
            return donorClaim();
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
      await tester.ensureVisible(find.text('Refresh pickup outcome'));
      await tester.tap(find.text('Refresh pickup outcome'));
      await tester.pump();
      expect(find.text('Open legacy route case'), findsNothing);
      response.complete(donor(enabled: false));
      await tester.pumpAndSettle();
      expect(find.text('Open legacy route case'), findsNothing);
    },
  );

  test(
    'existing participant reader must still authorize the bound task',
    () async {
      var writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, _) async {
          if (name == 'get_my_donation_route_resolution') return donor();
          if (name == 'get_my_route_resolution') {
            return {...participant(), 'items': <dynamic>[]};
          }
          writes++;
          return {};
        },
      );
      await expectLater(
        repo.submitDonor('donation-a', binding(), no),
        throwsStateError,
      );
      expect(writes, 0);
    },
  );

  test(
    'foreign donation response and late account switch are rejected',
    () async {
      var actor = 'donor-a';
      final foreign = RouteResolutionRepository(
        enabled: true,
        identity: () => actor,
        rpc: (_, _) async => {...donor(), 'donation_id': 'foreign'},
      );
      await expectLater(foreign.donorContext('donation-a'), throwsStateError);
      final switched = RouteResolutionRepository(
        enabled: true,
        identity: () => actor,
        rpc: (_, _) async {
          actor = 'donor-b';
          return donor();
        },
      );
      await expectLater(switched.donorContext('donation-a'), throwsStateError);
    },
  );

  testWidgets(
    'missing reader displays unavailable and cannot fall back to legacy writes',
    (tester) async {
      final calls = <String>[];
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (n, _) async {
          calls.add(n);
          throw const PostgrestException(message: 'missing', code: 'PGRST202');
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
      expect(
        find.text(
          'Reconciliation backend unavailable. Existing holds remain protected.',
        ),
        findsOneWidget,
      );
      expect(find.text('Open legacy route case'), findsNothing);
      expect(calls, ['get_my_donation_route_resolution']);
    },
  );

  testWidgets('frontend or backend disabled keeps confirmation disabled', (
    tester,
  ) async {
    for (final localEnabled in [false, true]) {
      var calls = 0;
      final repo = RouteResolutionRepository(
        enabled: localEnabled,
        identity: () => 'donor-a',
        rpc: (_, _) async {
          calls++;
          return donor(enabled: false);
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DonorPickupOutcomeNotice(
                key: ValueKey(localEnabled),
                donationId: 'donation-a',
                repository: repo,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open legacy route case'), findsNothing);
      expect(calls, localEnabled ? 2 : 0);
    }
  });

  testWidgets(
    'NEVER_STARTED handover remains explicit but disabled, never remapped',
    (tester) async {
      final row = {
        ...binding(),
        'initial_class': 'NEVER_STARTED',
        'allowed_assertions': [no, 'UNKNOWN_CUSTODY'],
      };
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, _) async {
          if (name == 'get_my_donation_route_resolution') {
            return donor(rows: [row]);
          }
          return {
            ...participant(),
            'items': [
              {
                'task_id': 'task-a',
                'claim_id': 'claim-a',
                'initial_class': 'NEVER_STARTED',
              },
            ],
          };
        },
      );
      await open(tester, repo);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Collected'),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.textContaining(
          'do not choose another statement unless it is truthful',
        ),
        findsOneWidget,
      );
      await expectLater(
        repo.submitDonor('donation-a', row, 'HANDOVER_TO_NGO_CONFIRMED'),
        throwsStateError,
      );
    },
  );

  test('duplicate donor submissions preserve one durable request', () async {
    var writes = 0;
    final entered = Completer<void>(),
        reply = Completer<Map<String, dynamic>>();
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'donor-a',
      rpc: (name, _) async {
        if (name == 'get_my_donation_route_resolution') return donor();
        if (name == 'get_my_route_resolution') return participant();
        writes++;
        entered.complete();
        return reply.future;
      },
    );
    final first = repo.submitDonor('donation-a', binding(), no);
    await entered.future;
    final saved = await repo.pending('route-a');
    await expectLater(
      repo.submitDonor('donation-a', binding(), no),
      throwsStateError,
    );
    expect(await repo.pending('route-a'), saved);
    reply.complete({
      'case_id': 'case-a',
      'version': 3,
      'status': 'AWAITING_EVIDENCE',
    });
    await first;
    expect(writes, 1);
  });

  testWidgets(
    'reopening uncertain donor evidence reconciles receipt without write retry',
    (tester) async {
      var writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor-a',
        rpc: (name, args) async {
          if (name == 'get_my_donation_route_resolution') return donor();
          if (name == 'get_my_route_resolution') return participant();
          if (name == 'get_my_route_resolution_receipt') {
            return {'request_id': args['p_request'], 'outcome': 'NOT_FOUND'};
          }
          writes++;
          throw TimeoutException('synthetic lost response');
        },
      );
      await expectLater(
        repo.submitDonor('donation-a', binding(), no),
        throwsA(isA<TimeoutException>()),
      );
      final request = (await repo.pending('route-a'))['request_id'];
      await open(tester, repo);
      expect(
        find.textContaining('Resolution outcome needs attention'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Not Collected'),
            )
            .onPressed,
        isNull,
      );
      expect(writes, 1);
      expect((await repo.pending('route-a'))['request_id'], request);
    },
  );

  testWidgets(
    'account change in donor confirmation dialog prevents submission',
    (tester) async {
      var actor = 'donor-a', writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => actor,
        rpc: (name, _) async {
          if (name == 'get_my_donation_route_resolution') return donor();
          if (name == 'get_my_route_resolution') return participant();
          writes++;
          return {};
        },
      );
      await open(tester, repo);
      await tester.tap(find.text('Not Collected'));
      await tester.pumpAndSettle();
      actor = 'donor-b';
      await tester.tap(find.text('Confirm statement'));
      await tester.pumpAndSettle();
      expect(writes, 0);
    },
  );
}
