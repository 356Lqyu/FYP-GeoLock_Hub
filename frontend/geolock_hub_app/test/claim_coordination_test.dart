import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/claim_coordination.dart';
import 'package:geolock_hub_app/routing/route_card_view.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'route_details_presentation_test.dart' as sample;

Map<String, dynamic> contextRow() => {
  'contract': 'geolock.claim-coordination.v2',
  'claim_id': 'claim',
  'case_id': 'case',
  'case_status': 'MANUAL_REVIEW',
  'evidence_round': 1,
  'evidence_version': 3,
  'can_submit': false,
  'can_resolve': true,
  'can_request_review': true,
  'can_accept_review': false,
  'statements': [
    {'round': 1, 'participant': 'NGO', 'handover_confirmed': false},
    {'round': 1, 'participant': 'Source', 'handover_confirmed': false},
  ],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('NGO reconciliation separates the round and refreshes at 320 px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 790);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reads = 0;
    final repo = ClaimCoordinationRepository(
      identity: () => 'ngo',
      rpc: (name, args) async {
        expect(name, 'get_my_claim_coordination');
        expect(args, {'p_claim': 'claim'});
        final first = reads++ == 0;
        return {
          ...contextRow(),
          'case_status': 'OPEN',
          'evidence_round': first ? 1 : 2,
          'can_submit': !first,
          'can_resolve': false,
          'can_request_review': false,
          'blocker': 'AWAITING_COUNTERPART',
          'statements': [
            {'round': 1, 'participant': 'NGO', 'handover_confirmed': false},
          ],
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.2)),
          child: child!,
        ),
        home: ClaimReconciliationPage(
          claimId: 'claim',
          viewerRole: 'NGO',
          sourceType: 'DIRECT_DONATION',
          repository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Awaiting counterpart'), findsOneWidget);
    expect(
      find.text('Waiting for the donor to submit their statement.'),
      findsOneWidget,
    );
    expect(find.text('Current round'), findsOneWidget);
    expect(find.text('Your statement'), findsOneWidget);
    expect(find.text('Donor statement'), findsOneWidget);
    expect(find.text('Your latest submission'), findsOneWidget);
    expect(find.text('No handover'), findsOneWidget);
    expect(find.text('Round 1 · NGO: No handover'), findsNothing);
    final refresh = find.widgetWithText(
      OutlinedButton,
      'Refresh reconciliation',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -440));
    await tester.pumpAndSettle();
    expect(refresh.hitTestable(), findsOneWidget);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('Submit your handover statement.'), findsOneWidget);
    expect(find.text('Not submitted'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Handover'), findsOneWidget);
    expect(find.text('No handover'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (handover, fails) in [
    (true, false),
    (false, false),
    (false, true),
  ]) {
    testWidgets(
      'Donor reconciliation at 320 px submits handover=$handover, fails=$fails',
      (tester) async {
        tester.view.physicalSize = const Size(320, 820);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final firstRead = Completer<void>();
        final submission = Completer<void>();
        final writes = <Map<String, dynamic>>[];
        var readCount = 0;
        var round = 2;
        var submitted = false;
        final repo = ClaimCoordinationRepository(
          identity: () => 'donor',
          rpc: (name, params) async {
            switch (name) {
              case 'get_my_claim_coordination':
                expect(params, {'p_claim': 'claim'});
                if (readCount++ == 0) await firstRead.future;
                return {
                  ...contextRow(),
                  'case_status': 'OPEN',
                  'evidence_round': round,
                  'evidence_version': 3,
                  'can_submit': !submitted || round == 3,
                  'can_resolve': submitted && round == 2,
                  'can_request_review': false,
                  'blocker': 'AWAITING_COUNTERPART',
                  'statements': [
                    {
                      'round': 1,
                      'participant': 'Source',
                      'handover_confirmed': false,
                    },
                    {
                      'round': 2,
                      'participant': 'NGO',
                      'handover_confirmed': handover,
                      'submitted_at': '2026-11-23T00:00:00Z',
                    },
                    if (submitted)
                      {
                        'round': 2,
                        'participant': 'Source',
                        'handover_confirmed': handover,
                      },
                  ],
                };
              case 'get_my_coordination_receipt':
                return {'request_id': params['p_request'], 'found': false};
              case 'submit_claim_reconciliation_v2':
                writes.add(params);
                await submission.future;
                if (fails) throw TimeoutException('Fixture response lost');
                submitted = true;
                return {'outcome': 'SUCCESS', 'claim_id': 'claim'};
              default:
                throw StateError('Unexpected request $name');
            }
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.2)),
              child: child!,
            ),
            home: ClaimReconciliationPage(
              claimId: 'claim',
              viewerRole: 'DONOR',
              sourceType: 'DIRECT_DONATION',
              repository: repo,
            ),
          ),
        );
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.text('Handover'), findsNothing);
        firstRead.complete();
        await tester.pumpAndSettle();
        final current = find.ancestor(
          of: find.text('Current round'),
          matching: find.byType(Card),
        );
        final latest = find.ancestor(
          of: find.text('Latest submission'),
          matching: find.byType(Card),
        );
        final previous = find.ancestor(
          of: find.text('Previous submissions'),
          matching: find.byType(Card),
        );
        expect(find.text('Action required'), findsOneWidget);
        expect(
          find.text(
            'The NGO has submitted a statement. Please submit yours to continue.',
          ),
          findsOneWidget,
        );
        for (final label in [
          'Evidence round',
          '2',
          'Your statement',
          'NGO statement',
          'Submitted',
          'Not submitted',
          'Next step',
        ]) {
          expect(
            find.descendant(of: current, matching: find.text(label)),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(of: latest, matching: find.text('NGO')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: latest, matching: find.text('Submitted at')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: previous, matching: find.text('You')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: previous, matching: find.text('Submitted at')),
          findsNothing,
        );
        expect(find.text('Round 2 · NGO: No handover'), findsNothing);

        final yes = find.widgetWithText(OutlinedButton, 'Handover');
        final no = find.widgetWithText(OutlinedButton, 'No Handover');
        final response = find.ancestor(
          of: find.text('Your response'),
          matching: find.byType(Card),
        );
        expect(find.descendant(of: response, matching: yes), findsOneWidget);
        expect(find.descendant(of: response, matching: no), findsOneWidget);
        Future<void> scrollToActions() async {
          final scroll = tester.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          scroll.position.jumpTo(scroll.position.maxScrollExtent);
          await tester.pump();
        }

        await scrollToActions();
        final button = handover ? yes : no;
        expect(button.hitTestable(), findsOneWidget);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('Confirm your handover statement'), findsOneWidget);
        expect(writes, isEmpty);
        await tester.tap(find.text('Confirm'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.bySemanticsLabel('Updating reconciliation'),
          findsOneWidget,
        );
        expect(tester.widget<OutlinedButton>(yes).onPressed, isNull);
        expect(tester.widget<OutlinedButton>(no).onPressed, isNull);
        expect(writes, hasLength(1));
        expect(writes.single, {
          'p_claim': 'claim',
          'p_handover_confirmed': handover,
          'p_expected_round': 2,
          'p_expected_version': 3,
          'p_request': isA<String>(),
        });
        submission.complete();
        await tester.pumpAndSettle();
        expect(find.text('Your response'), findsNothing);
        expect(find.bySemanticsLabel('Updating reconciliation'), findsNothing);
        if (fails) {
          expect(find.textContaining('Fixture response lost'), findsOneWidget);
          expect(find.text('Recover saved request'), findsOneWidget);
          expect(find.text('Discard uncommitted request'), findsOneWidget);
        } else {
          expect(
            find.descendant(of: latest, matching: find.text('You')),
            findsOneWidget,
          );
          expect(
            find.widgetWithText(FilledButton, 'Resolve Matching Statements'),
            findsOneWidget,
          );
          round = 3;
          await scrollToActions();
          final refresh = find.widgetWithText(
            OutlinedButton,
            'Refresh reconciliation',
          );
          expect(refresh.hitTestable(), findsOneWidget);
          await tester.tap(refresh);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: current, matching: find.text('3')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: current, matching: find.text('Not submitted')),
            findsNWidgets(2),
          );
          expect(find.text('Your response'), findsOneWidget);
        }
        expect(writes, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('Donor details retain a custody warning when a response is allowed', (
    tester,
  ) async {
    final repo = ClaimCoordinationRepository(
      identity: () => 'donor',
      rpc: (name, params) async {
        expect(name, 'get_my_claim_coordination');
        return {
          ...contextRow(),
          'blocker': 'UNRESOLVED_CUSTODY_OR_INCIDENT',
          'can_submit': true,
          'can_resolve': false,
          'can_request_review': false,
          'statements': <Map<String, dynamic>>[],
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ClaimReconciliationPage(
          claimId: 'claim',
          viewerRole: 'DONOR',
          repository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('A custody incident remains unresolved. No release or collection can be confirmed.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(OutlinedButton, 'Handover'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Resolve Matching Statements'), findsNothing);
  });

  test(
    'disagreement, awaiting counterpart and terminal messages are distinct',
    () {
      expect(
        claimCoordinationMessage({'blocker': 'PARTY_EVIDENCE_CONFLICT'}),
        contains('Disagreement unresolved'),
      );
      expect(
        claimCoordinationMessage({'blocker': 'AWAITING_COUNTERPART'}),
        'Awaiting Counterpart',
      );
      expect(
        claimCoordinationMessage({'case_status': 'RESOLVED_RELEASED'}),
        contains('Claim released'),
      );
      expect(
        claimCoordinationMessage({'review_waiting': true}),
        contains('acceptance'),
      );
    },
  );

  test(
    'lost response recovers immutable receipt without another write',
    () async {
      var writes = 0;
      var committed = false;
      String? request;
      final repo = ClaimCoordinationRepository(
        identity: () => 'owner',
        rpc: (name, params) async {
          if (name == 'get_my_coordination_receipt') {
            request ??= params['p_request'] as String;
            expect(params['p_request'], request);
            return {
              'request_id': request,
              'found': committed,
              'result': {'outcome': 'SUCCESS', 'claim_id': 'claim'},
            };
          }
          expect(name, 'resolve_my_claim_reconciliation');
          expect(params['p_request'], request);
          writes++;
          committed = true;
          throw TimeoutException('response lost');
        },
      );
      await expectLater(
        repo.send('claim', 'resolve_my_claim_reconciliation', {
          'p_claim': 'claim',
        }),
        throwsA(isA<TimeoutException>()),
      );
      expect(await repo.pending('claim'), isNotNull);
      expect((await repo.recover('claim'))['outcome'], 'SUCCESS');
      expect(writes, 1);
      expect(await repo.pending('claim'), isNull);
    },
  );

  test(
    'round-aware evidence is persisted and payload replacement is denied',
    () async {
      final repo = ClaimCoordinationRepository(
        identity: () => 'owner',
        rpc: (name, params) async {
          if (name == 'get_my_coordination_receipt') {
            return {'request_id': params['p_request'], 'found': false};
          }
          expect(name, 'submit_claim_reconciliation_v2');
          expect(params['p_expected_round'], 2);
          expect(params['p_expected_version'], 9);
          throw StateError('CASE_VERSION_STALE');
        },
      );
      final args = {
        'p_claim': 'claim',
        'p_handover_confirmed': false,
        'p_expected_round': 2,
        'p_expected_version': 9,
      };
      await expectLater(
        repo.send('claim', 'submit_claim_reconciliation_v2', args),
        throwsStateError,
      );
      await expectLater(
        repo.send('claim', 'submit_claim_reconciliation_v2', {
          ...args,
          'p_handover_confirmed': true,
        }),
        throwsStateError,
      );
      await repo.discardUnsent('claim');
      expect(await repo.pending('claim'), isNull);
    },
  );

  test(
    'committed request cannot be discarded and duplicate flight is blocked',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      final repo = ClaimCoordinationRepository(
        identity: () => 'owner',
        rpc: (name, params) async {
          if (name == 'get_my_coordination_receipt') {
            return {'request_id': params['p_request'], 'found': false};
          }
          return gate.future;
        },
      );
      final first = repo.send('claim', 'resolve_my_claim_reconciliation', {
        'p_claim': 'claim',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await expectLater(
        repo.send('claim', 'resolve_my_claim_reconciliation', {
          'p_claim': 'claim',
        }),
        throwsStateError,
      );
      gate.complete({'outcome': 'SUCCESS', 'claim_id': 'claim'});
      await first;
    },
  );

  testWidgets(
    'existing matching case uses explicit protected resolve and refresh',
    (tester) async {
      var row = contextRow();
      var writes = 0, refreshes = 0;
      final repo = ClaimCoordinationRepository(
        identity: () => 'owner',
        rpc: (name, params) async {
          if (name == 'get_my_claim_coordination') return row;
          if (name == 'get_my_coordination_receipt') {
            return {'request_id': params['p_request'], 'found': false};
          }
          expect(name, 'resolve_my_claim_reconciliation');
          expect(params['p_claim'], 'claim');
          writes++;
          row = {
            ...row,
            'case_status': 'RESOLVED_RELEASED',
            'can_resolve': false,
            'can_request_review': false,
          };
          return {'outcome': 'SUCCESS', 'claim_id': 'claim'};
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClaimCoordinationPanel(
              claimId: 'claim',
              repository: repo,
              onChanged: () async {
                refreshes++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.tap(find.text('Resolve Matching Statements'));
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(refreshes, 1);
      expect(find.textContaining('Claim released'), findsOneWidget);
    },
  );

  testWidgets('account switch during confirmation sends no mutation', (
    tester,
  ) async {
    var owner = 'one';
    var writes = 0;
    final repo = ClaimCoordinationRepository(
      identity: () => owner,
      rpc: (name, params) async {
        if (name == 'get_my_claim_coordination') return contextRow();
        writes++;
        throw StateError('Unexpected mutation');
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClaimCoordinationPanel(claimId: 'claim', repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resolve Matching Statements'));
    await tester.pumpAndSettle();
    owner = 'two';
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(writes, 0);
  });

  testWidgets('joint-review UI sends version and preserves prior testimony', (
    tester,
  ) async {
    var row = {
      ...contextRow(),
      'can_resolve': false,
      'blocker': 'PARTY_EVIDENCE_CONFLICT',
    };
    String? action;
    final repo = ClaimCoordinationRepository(
      identity: () => 'owner',
      rpc: (name, params) async {
        if (name == 'get_my_claim_coordination') return row;
        if (name == 'get_my_coordination_receipt') {
          return {'request_id': params['p_request'], 'found': false};
        }
        expect(name, 'review_my_claim_reconciliation');
        expect(params['p_expected_version'], 3);
        action = params['p_action'] as String;
        row = {
          ...row,
          'review_waiting': true,
          'can_request_review': false,
          'evidence_version': 4,
        };
        return {'outcome': 'SUCCESS', 'claim_id': 'claim'};
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClaimCoordinationPanel(claimId: 'claim', repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Disagreement unresolved'), findsOneWidget);
    await tester.tap(find.text('Request joint review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(action, 'REQUEST');
    expect(find.textContaining('acceptance'), findsOneWidget);
    expect(find.text('Round 1 · NGO: No handover'), findsOneWidget);
  });

  testWidgets(
    'checkpoint confirms vehicle without closing route or claiming goods return',
    (tester) async {
      final writes = <String>[];
      var needed = true;
      final repo = ClaimCoordinationRepository(
        identity: () => 'owner',
        rpc: (name, params) async {
          if (name == 'get_my_coordination_receipt') {
            return {'request_id': params['p_request'], 'found': false};
          }
          writes.add(name);
          expect(name, 'confirm_my_route_depot_checkpoint');
          expect(params['p_confirmed'], true);
          return {'outcome': 'SUCCESS', 'route_id': 'route'};
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VehicleDepotCheckpoint(
              routeId: 'route',
              requiredCheckpoint: needed,
              authorized: true,
              repository: repo,
              readRoute: () async => {
                'authorization_confirmed': true,
                'can_confirm_depot_checkpoint': true,
              },
              onChanged: () async {
                needed = false;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm vehicle at registered depot'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('does not confirm goods return'),
        findsOneWidget,
      );
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(writes, ['confirm_my_route_depot_checkpoint']);
    },
  );

  test('started no-collection labels use outcome, not a cancelled status', () {
    final row = {
      'route_status': 'IN_PROGRESS',
      'authorization_confirmed': true,
      'can_close': true,
      'closure_kind': 'NO_COLLECTION',
      'stops': [],
    };
    expect(
      routeCardReadiness(row, fresh: true),
      'No goods collected — confirm vehicle return and close route',
    );
    row['route_status'] = 'ABANDONED';
    expect(
      routeCardReadiness(row, fresh: true),
      'Route closed — no goods collected',
    );
  });

  test(
    'NO_COLLECTION uses resolved closure and recovers its saved receipt',
    () async {
      var writes = 0, committed = false;
      String? request;
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          if (name == 'get_my_authorized_route') {
            return {
              ...sample.fixture(start: false),
              'actual_started_at': '2026-11-04T00:00:00Z',
              'can_close': true,
              'closure_outcome': null,
              'closure_kind': 'NO_COLLECTION',
            };
          }
          if (name == 'get_my_mixed_route_close_receipt') {
            expect(params['p_request'], request);
            return {
              'found': committed,
              'request_id': request,
              'route_id': 'synthetic-route',
              'result': {
                'request_id': request,
                'route_id': 'synthetic-route',
                'route_status': 'ABANDONED',
                'outcome': 'NO_COLLECTION',
              },
            };
          }
          expect(name, 'close_my_resolved_route');
          request = params['p_request'] as String;
          writes++;
          committed = true;
          throw TimeoutException('committed, response lost');
        },
      );
      await expectLater(
        repo.close('synthetic-route'),
        throwsA(isA<TimeoutException>()),
      );
      await repo.close('synthetic-route');
      expect(writes, 1);
      expect(await repo.pendingMixedRouteClosure('synthetic-route'), isNull);
    },
  );

  test('a committed saved coordination request cannot be discarded', () async {
    var committed = false;
    final repo = ClaimCoordinationRepository(
      identity: () => 'owner',
      rpc: (name, params) async {
        if (name == 'get_my_coordination_receipt') {
          return {
            'found': committed,
            'request_id': params['p_request'],
            'result': {'outcome': 'SUCCESS', 'claim_id': 'claim'},
          };
        }
        committed = true;
        throw TimeoutException('response lost');
      },
    );
    await expectLater(
      repo.send('claim', 'resolve_my_claim_reconciliation', {
        'p_claim': 'claim',
      }),
      throwsA(isA<TimeoutException>()),
    );
    await expectLater(repo.discardUnsent('claim'), throwsStateError);
    expect(await repo.pending('claim'), isNotNull);
    await repo.recover('claim');
  });

  test('corrupted saved operation cannot invoke an unrelated RPC', () async {
    SharedPreferences.setMockInitialValues({
      'claim_coordination_owner_claim':
          '{"name":"cancel_my_unstarted_route","params":{"p_claim":"claim","p_request":"request"}}',
    });
    var calls = 0;
    final repo = ClaimCoordinationRepository(
      identity: () => 'owner',
      rpc: (name, params) async {
        calls++;
        return {};
      },
    );
    await expectLater(repo.recover('claim'), throwsStateError);
    expect(calls, 0);
  });

  testWidgets(
    'ready no-collection closure does not also require a resume checkpoint',
    (tester) async {
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          if (name == 'get_my_claim_cards_v2') return [];
          expect(name, 'get_my_authorized_route');
          return {
            ...sample.fixture(start: false),
            'actual_started_at': '2026-11-04T00:00:00Z',
            'can_close': true,
            'closure_outcome': 'ABANDONED',
            'closure_kind': 'NO_COLLECTION',
            'vehicle_checkpoint_required': true,
            'can_confirm_depot_checkpoint': true,
          };
        },
      );
      tester.view.physicalSize = const Size(1200, 2800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: NgoRouteDetailPage(
            routeId: 'synthetic-route',
            repository: repo,
            mapBuilder: (_) => const SizedBox(height: 20),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final close = find.text(
        'No goods collected — confirm vehicle return and close route',
      );
      await tester.ensureVisible(close);
      expect(close, findsOneWidget);
      expect(find.text('Confirm vehicle at registered depot'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
