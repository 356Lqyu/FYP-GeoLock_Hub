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
