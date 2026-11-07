import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/routing/route_resolution_repository.dart';
import 'package:geolock_hub_app/routing/route_resolution_page.dart';
import 'package:geolock_hub_app/routing/route_card_view.dart';

const route = 'local-route';
const caseId = 'local-case';
Map<String, dynamic> status({bool reported = false, String? myAssertion}) => {
  'contract': 'geolock.route-resolution.v1',
  'route_id': route,
  'enabled': true,
  'is_owner': true,
  'status': reported ? 'AWAITING_EVIDENCE' : 'NOT_REPORTED',
  if (reported) 'case_id': caseId,
  'version': 2,
  'items': <dynamic>[
    if (reported)
      {
        'task_id': 'task',
        'claim_id': 'claim',
        'initial_class': 'DISPATCHED',
        'my_assertion': myAssertion,
      },
  ],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openDetails(
    WidgetTester tester,
    RouteResolutionRepository repo, {
    String? sourceType = 'DIRECT_DONATION',
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RouteResolutionPage(
          routeId: route,
          repository: repo,
          pickupDescriptions: {
            'task': {'title': 'Synthetic pickup', 'source_type': sourceType},
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final source in ['DIRECT_DONATION', 'HUB_BATCH']) {
    for (final collected in [true, false]) {
      testWidgets(
        '$source maps ${collected ? 'Collected' : 'Not Collected'} only after confirmation',
        (tester) async {
          final writes = <Map<String, dynamic>>[];
          final repo = RouteResolutionRepository(
            enabled: true,
            identity: () => 'ngo',
            rpc: (name, args) async {
              if (name == 'get_my_route_resolution') {
                return status(reported: true);
              }
              expect(name, 'submit_route_resolution_evidence');
              writes.add(args);
              return {
                'case_id': caseId,
                'version': 3,
                'status': 'AWAITING_EVIDENCE',
              };
            },
          );
          await openDetails(tester, repo, sourceType: source);
          expect(
            find.text('Has your NGO collected this donation?'),
            findsOneWidget,
          );
          expect(
            find.widgetWithText(OutlinedButton, 'Custody uncertain'),
            findsNothing,
          );
          expect(
            find.textContaining(
              source == 'HUB_BATCH'
                  ? 'goods remain at the community hub'
                  : 'goods remain with the donor',
            ),
            findsOneWidget,
          );
          if (source == 'HUB_BATCH') {
            expect(find.textContaining('complete hub batch'), findsOneWidget);
          }
          expect(writes, isEmpty);
          final label = collected ? 'Collected' : 'Not Collected';
          expect(find.text('Confirm statement'), findsNothing);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(writes, isEmpty);
          expect(find.text('Record $label?'), findsOneWidget);
          await tester.tap(find.text('Back'));
          await tester.pumpAndSettle();
          expect(writes, isEmpty);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Confirm statement'));
          await tester.pumpAndSettle();
          expect(writes, hasLength(1));
          expect(
            writes.single['p_assertion'],
            collected
                ? 'HANDOVER_TO_NGO_CONFIRMED'
                : 'NO_HANDOVER_SOURCE_RETAINS_GOODS',
          );
          expect(writes.single['p_task'], 'task');
          expect(writes.single['p_case'], caseId);
          expect(writes.single['p_version'], 2);
          expect(writes.single['p_request'], isNotEmpty);
        },
      );
    }
  }

  testWidgets(
    'Confirm statement gives success feedback and disables the same recorded assertion',
    (tester) async {
      var recorded = false;
      var writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, args) async {
          if (name == 'get_my_route_resolution') {
            return status(
              reported: true,
              myAssertion: recorded ? 'NO_HANDOVER_SOURCE_RETAINS_GOODS' : null,
            );
          }
          expect(name, 'submit_route_resolution_evidence');
          writes++;
          recorded = true;
          expect(args['p_assertion'], 'NO_HANDOVER_SOURCE_RETAINS_GOODS');
          return {
            'case_id': caseId,
            'version': 3,
            'status': 'AWAITING_EVIDENCE',
          };
        },
      );
      await openDetails(tester, repo);
      await tester.tap(find.text('Not Collected'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm statement'), findsOneWidget);
      await tester.tap(find.text('Confirm statement'));
      await tester.pumpAndSettle();

      expect(writes, 1);
      expect(
        find.textContaining('Statement recorded by the protected service'),
        findsAtLeastNWidgets(1),
      );
      expect(find.text('My statement: Not Collected'), findsOneWidget);
      expect(
        find.textContaining('Your latest statement is recorded'),
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
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'lost response reconciles the saved request receipt and shows confirmed success',
    (tester) async {
      var recorded = false;
      var writes = 0;
      String? submittedRequest;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, args) async {
          if (name == 'get_my_route_resolution') {
            return status(
              reported: true,
              myAssertion: recorded ? 'NO_HANDOVER_SOURCE_RETAINS_GOODS' : null,
            );
          }
          if (name == 'submit_route_resolution_evidence') {
            writes++;
            submittedRequest = args['p_request'] as String;
            recorded = true;
            throw TimeoutException('response lost after commit');
          }
          if (name == 'get_my_route_resolution_receipt') {
            expect(args['p_request'], submittedRequest);
            return {
              'request_id': args['p_request'],
              'outcome': 'FOUND',
              'result': {
                'case_id': caseId,
                'version': 3,
                'status': 'AWAITING_EVIDENCE',
              },
            };
          }
          throw StateError('Unexpected RPC $name');
        },
      );
      await openDetails(tester, repo);
      await tester.tap(find.text('Not Collected'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm statement'));
      await tester.pumpAndSettle();

      expect(writes, 1);
      expect(submittedRequest, isNotNull);
      expect(
        find.textContaining('confirmed by its protected receipt'),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.textContaining('Resolution outcome needs attention'),
        findsNothing,
      );
      expect(await repo.pending(route), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('backend submission errors are visible after confirmation', (
    tester,
  ) async {
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'ngo',
      rpc: (name, args) async {
        if (name == 'get_my_route_resolution') return status(reported: true);
        if (name == 'get_my_route_resolution_receipt') {
          return {'request_id': args['p_request'], 'outcome': 'NOT_FOUND'};
        }
        throw StateError('NO_HANDOVER_AFTER_PICKUP_STARTED_REQUIRES_REVIEW');
      },
    );
    await openDetails(tester, repo);
    await tester.tap(find.text('Not Collected'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm statement'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('NO_HANDOVER_AFTER_PICKUP_STARTED_REQUIRES_REVIEW'),
      findsOneWidget,
    );
    expect(find.textContaining('original request is saved'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'missing source metadata uses neutral wording and preserves historical uncertainty',
    (tester) async {
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, _) async {
          expect(name, 'get_my_route_resolution');
          return {
            ...status(reported: true),
            'status': 'MANUAL_REVIEW',
            'items': [
              {
                'task_id': 'task',
                'initial_class': 'DISPATCHED',
                'my_assertion': 'UNKNOWN_CUSTODY',
              },
            ],
          };
        },
      );
      await openDetails(tester, repo, sourceType: null);
      expect(find.text('My statement: Custody uncertain'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Custody uncertain'),
        findsNothing,
      );
      expect(
        find.textContaining('goods remain with the collection source'),
        findsOneWidget,
      );
      expect(find.textContaining('goods remain with the donor'), findsNothing);
    },
  );

  test(
    'indicator requires protected claim association, never expiry alone',
    () {
      final detail = {
        'stops': [
          {'claim_id': 'claim'},
        ],
      };
      expect(
        routeNeedsReconciliation(detail, [
          {
            'claim_id': 'claim',
            'claim_status': 'ACTIVE',
            'lease_is_expired': true,
          },
        ]),
        isFalse,
      );
      expect(
        routeNeedsReconciliation(detail, [
          {'claim_id': 'another', 'claim_status': 'RECONCILIATION_REQUIRED'},
        ]),
        isFalse,
      );
      expect(
        routeNeedsReconciliation(detail, [
          {'claim_id': 'claim', 'lease_status': 'RECONCILIATION_REQUIRED'},
        ]),
        isTrue,
      );
      expect(
        routeNeedsReconciliation(null, [
          {'claim_id': 'claim', 'claim_status': 'RECONCILIATION_REQUIRED'},
        ]),
        isFalse,
      );
    },
  );

  testWidgets('claim hold notice does not open route-level reconciliation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PickupRouteCard(
            overview: const {'route_status': 'IN_PROGRESS'},
            fresh: true,
            reconciliationRequired: true,
            onTap: () {},
          ),
        ),
      ),
    );
    expect(
      find.textContaining('Action required · Reconciliation required'),
      findsOneWidget,
    );
    expect(find.text('Review Reconciliation'), findsNothing);
  });

  testWidgets('unavailable route evidence never claims no holds or readiness', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PickupRouteCard(
            overview: const {'route_status': 'IN_PROGRESS'},
            fresh: true,
            reconciliationVerified: false,
            onTap: () {},
          ),
        ),
      ),
    );
    expect(
      find.textContaining('Reconciliation status unavailable'),
      findsOneWidget,
    );
    expect(find.text('Review Reconciliation'), findsNothing);
    expect(find.textContaining('Ready to start pickup'), findsNothing);
  });

  testWidgets(
    'donation confirmation is unavailable without protected binding',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DonorPickupOutcomeNotice())),
      );
      expect(find.text('Confirm Pickup Outcome'), findsNothing);
      expect(
        find.textContaining('Lease expiry alone does not establish'),
        findsOneWidget,
      );
      expect(find.textContaining('No answer is preselected'), findsOneWidget);
      expect(find.textContaining('Unsure.'), findsNothing);
    },
  );

  testWidgets(
    'owner sees names and separate pending participant evidence, no automatic submit',
    (tester) async {
      final calls = <String>[];
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, _) async {
          calls.add(name);
          return status(reported: true);
        },
      );
      await openDetails(tester, repo);
      expect(find.text('Synthetic pickup'), findsOneWidget);
      expect(find.text('My statement: Not provided'), findsOneWidget);
      expect(find.text('Awaiting donor confirmation'), findsOneWidget);
      expect(find.text('Not Collected'), findsOneWidget);
      expect(find.text('Collected'), findsOneWidget);
      expect(find.text('Custody uncertain'), findsNothing);
      expect(calls, ['get_my_route_resolution']);
      expect(find.text('Finalize'), findsNothing);
    },
  );

  testWidgets(
    'donor cannot submit unidentified task evidence or vehicle accountability',
    (tester) async {
      final calls = <String>[];
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor',
        rpc: (name, _) async {
          calls.add(name);
          return {...status(reported: true), 'is_owner': false};
        },
      );
      await openDetails(tester, repo);
      expect(
        find.textContaining('Donation-specific confirmation unavailable'),
        findsOneWidget,
      );
      for (final label in ['Not Collected', 'Collected']) {
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, label),
              )
              .onPressed,
          isNull,
        );
      }
      expect(
        find.text('Vehicle and collected goods accounted for at depot'),
        findsNothing,
      );
      expect(calls, ['get_my_route_resolution']);
    },
  );

  test(
    'task outside scoped response and invalid handover fail before any write',
    () async {
      var writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'donor',
        rpc: (name, _) async {
          if (name != 'get_my_route_resolution') {
            writes++;
            return {};
          }
          return {
            ...status(reported: true),
            'is_owner': false,
            'items': [
              {'task_id': 'mine', 'initial_class': 'NEVER_STARTED'},
            ],
          };
        },
      );
      await expectLater(
        repo.submit(route, 'someone-elses-task', 'UNKNOWN_CUSTODY'),
        throwsStateError,
      );
      await expectLater(
        repo.submit(route, null, 'VEHICLE_RETURNED_TO_NGO_CONTROL'),
        throwsStateError,
      );
      await expectLater(
        repo.submit(route, 'mine', 'HANDOVER_TO_NGO_CONFIRMED'),
        throwsStateError,
      );
      expect(writes, 0);
      expect(await repo.pending(route), isEmpty);
    },
  );

  test(
    'changed case version after confirmation cannot silently amend newer evidence',
    () async {
      var writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'get_my_route_resolution') {
            return {...status(reported: true), 'version': 3};
          }
          writes++;
          return {};
        },
      );
      await expectLater(
        repo.submit(route, 'task', 'UNKNOWN_CUSTODY', expectedVersion: 2),
        throwsA(isA<ResolutionVersionConflict>()),
      );
      expect(writes, 0);
      expect(await repo.pending(route), isEmpty);
    },
  );

  testWidgets(
    'evidence confirmation submits one pinned statement and preserves history',
    (tester) async {
      final writes = <Map<String, dynamic>>[];
      var version = 2;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, args) async {
          if (name == 'get_my_route_resolution') {
            return {...status(reported: true), 'version': version};
          }
          expect(name, 'submit_route_resolution_evidence');
          writes.add(args);
          version++;
          return {
            'case_id': caseId,
            'version': version,
            'status': 'AWAITING_EVIDENCE',
          };
        },
      );
      await openDetails(tester, repo);
      await tester.tap(find.text('Not Collected'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      expect(
        find.textContaining(
          'This is not an unverified or unknown-custody answer',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Confirm statement'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(writes.single['p_task'], 'task');
      expect(writes.single['p_assertion'], 'NO_HANDOVER_SOURCE_RETAINS_GOODS');
      expect(writes.single['p_version'], 2);
      expect(await repo.pending(route), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getStringList(
          'route_resolution_ngo_local-route_history',
        ),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'account switch while dialog open cannot submit previous participant statement',
    (tester) async {
      var owner = 'ngo', writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => owner,
        rpc: (name, _) async {
          if (name == 'get_my_route_resolution') return status(reported: true);
          writes++;
          return {};
        },
      );
      await openDetails(tester, repo);
      await tester.tap(find.text('Not Collected'));
      await tester.pumpAndSettle();
      owner = 'another';
      await tester.tap(find.text('Confirm statement'));
      await tester.pumpAndSettle();
      expect(writes, 0);
    },
  );

  test(
    'server version conflict preserves request and sanitizes the error',
    () async {
      var writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'get_my_route_resolution') return status(reported: true);
          writes++;
          throw const PostgrestException(
            message: 'CASE_VERSION_STALE',
            code: 'P0001',
          );
        },
      );
      Object? failure;
      try {
        await repo.submit(route, 'task', 'UNKNOWN_CUSTODY', expectedVersion: 2);
      } catch (error) {
        failure = error;
      }
      expect(resolutionError(failure!), contains('Version conflict'));
      final saved = await repo.pending(route);
      expect(saved, isNotEmpty);
      await expectLater(
        repo.submit(route, 'task', 'UNKNOWN_CUSTODY'),
        throwsStateError,
      );
      expect(writes, 1);
      expect(await repo.pending(route), saved);
    },
  );

  testWidgets(
    'missing backend is explicit and never enables a replacement legacy RPC',
    (tester) async {
      final calls = <String>[];
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, _) async {
          calls.add(name);
          throw const PostgrestException(
            message: 'unavailable',
            code: 'PGRST202',
          );
        },
      );
      await openDetails(tester, repo);
      expect(
        find.text(
          'Reconciliation backend unavailable. Existing holds remain protected.',
        ),
        findsOneWidget,
      );
      expect(calls, ['get_my_route_resolution']);
      expect(find.text('Report cannot continue'), findsNothing);
    },
  );

  testWidgets(
    'unresolved receipt on reopening blocks evidence replacement without resend',
    (tester) async {
      var writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, args) async {
          if (name == 'get_my_route_resolution') return status(reported: true);
          if (name == 'get_my_route_resolution_receipt') {
            return {'request_id': args['p_request'], 'outcome': 'NOT_FOUND'};
          }
          writes++;
          throw TimeoutException('synthetic lost reply');
        },
      );
      await expectLater(
        repo.submit(route, 'task', 'UNKNOWN_CUSTODY'),
        throwsA(isA<TimeoutException>()),
      );
      final request = (await repo.pending(route))['request_id'];
      await openDetails(tester, repo);
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
      expect((await repo.pending(route))['request_id'], request);
      expect(writes, 1);
    },
  );

  testWidgets(
    'resolved status requires backend result and opening it does not finalize',
    (tester) async {
      final calls = <String>[];
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, _) async {
          calls.add(name);
          return {...status(reported: true), 'status': 'RESOLVED'};
        },
      );
      await openDetails(tester, repo);
      expect(find.text('Resolved — confirmed by backend'), findsOneWidget);
      expect(
        find.textContaining(
          'Reopened listings remain subject to normal discovery eligibility.',
        ),
        findsOneWidget,
      );
      expect(find.text('Not Collected'), findsNothing);
      expect(calls, ['get_my_route_resolution']);
    },
  );

  test(
    'status labels distinguish evidence, manual review, disabled and unknown states',
    () {
      expect(resolutionStatusLabel(null), 'Backend unavailable');
      expect(
        resolutionStatusLabel({'status': 'DISABLED'}),
        contains('not activated'),
      );
      expect(
        resolutionStatusLabel({'status': 'MANUAL_REVIEW'}),
        'Manual review required',
      );
      expect(
        resolutionStatusLabel(status(reported: true)),
        contains('Awaiting participant'),
      );
      expect(
        resolutionStatusLabel({
          ...status(reported: true),
          'vehicle_confirmed': true,
          'items': [
            {
              'ngo_assertion': 'NO_HANDOVER_SOURCE_RETAINS_GOODS',
              'source_assertion': 'NO_HANDOVER_SOURCE_RETAINS_GOODS',
            },
          ],
        }),
        'Statements provided — awaiting authorized review',
      );
      expect(
        resolutionError(
          const PostgrestException(
            message: 'private internal text',
            code: '42501',
          ),
        ),
        'You are not authorized to submit or view this evidence.',
      );
    },
  );

  test(
    'ABANDONED is not pickup ready even with contradictory advisory flags',
    () {
      expect(
        routeCardReadiness({
          'route_status': 'ABANDONED',
          'authorization_confirmed': true,
          'stops': [
            {'can_start': true},
          ],
        }, fresh: true),
        'Route abandoned; custody and reservations reconciled.',
      );
    },
  );

  for (final assertion in [
    'NO_HANDOVER_SOURCE_RETAINS_GOODS',
    'HANDOVER_TO_NGO_CONFIRMED',
    'UNKNOWN_CUSTODY',
  ]) {
    test(
      'explicit evidence choice uses protected RPC without finalization: $assertion',
      () async {
        final writes = <String>[];
        final repo = RouteResolutionRepository(
          enabled: true,
          identity: () => 'ngo',
          rpc: (name, args) async {
            if (name == 'get_my_route_resolution') {
              return status(reported: true);
            }
            writes.add(name);
            expect(args['p_assertion'], assertion);
            expect(args['p_version'], 2);
            return {
              'case_id': caseId,
              'version': 3,
              'status': 'AWAITING_EVIDENCE',
            };
          },
        );
        await repo.submit(route, 'task', assertion, expectedVersion: 2);
        expect(writes, ['submit_route_resolution_evidence']);
        expect(await repo.pending(route), isEmpty);
      },
    );
  }

  test(
    'duplicate evidence submissions preserve one in-flight request',
    () async {
      final entered = Completer<void>(),
          reply = Completer<Map<String, dynamic>>();
      var writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'get_my_route_resolution') return status(reported: true);
          writes++;
          entered.complete();
          return reply.future;
        },
      );
      final first = repo.submit(route, 'task', 'UNKNOWN_CUSTODY');
      await entered.future;
      final saved = await repo.pending(route);
      await expectLater(
        repo.submit(route, 'task', 'UNKNOWN_CUSTODY'),
        throwsStateError,
      );
      expect(await repo.pending(route), saved);
      reply.complete({
        'case_id': caseId,
        'status': 'MANUAL_REVIEW',
        'version': 3,
      });
      await first;
      expect(writes, 1);
    },
  );

  testWidgets('never-started tasks offer no handover assertion', (
    tester,
  ) async {
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'ngo',
      rpc: (_, _) async => {
        ...status(reported: true),
        'status': 'MANUAL_REVIEW',
        'items': [
          {
            'task_id': 'task',
            'claim_id': 'claim',
            'initial_class': 'NEVER_STARTED',
          },
        ],
      },
    );
    await openDetails(tester, repo);
    expect(find.text('Manual review required'), findsOneWidget);
    expect(find.text('Collected'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Collected'),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Not Collected'), findsOneWidget);
  });

  testWidgets('participant read denial never exposes a write action', (
    tester,
  ) async {
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'other',
      rpc: (_, _) async {
        throw const PostgrestException(
          message: 'RESOLUTION_PARTICIPANT_ONLY',
          code: 'P0001',
        );
      },
    );
    await openDetails(tester, repo);
    expect(
      find.text('You are not authorized to submit or view this evidence.'),
      findsOneWidget,
    );
    for (final button in tester.widgetList<FilledButton>(
      find.byType(FilledButton),
    )) {
      expect(button.onPressed, isNull);
    }
    expect(find.text('Not Collected'), findsNothing);
  });

  testWidgets('participant inbox only reads and exposes no finalization', (
    tester,
  ) async {
    final calls = <String>[];
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'donor',
      rpc: (name, _) async {
        calls.add(name);
        return {
          'contract': 'geolock.route-resolution.v1',
          'cases': [
            {'route_id': route, 'status': 'AWAITING_EVIDENCE'},
          ],
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: RouteResolutionInboxPage(repository: repo)),
    );
    await tester.pumpAndSettle();
    expect(calls, ['list_my_route_resolution_cases']);
    expect(find.text('Route resolution · AWAITING_EVIDENCE'), findsOneWidget);
    expect(find.text('Finalize'), findsNothing);
  });

  test('case list rejects an account switch during read', () async {
    var owner = 'donor';
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => owner,
      rpc: (_, _) async {
        owner = 'other';
        return {'contract': 'geolock.route-resolution.v1', 'cases': []};
      },
    );
    await expectLater(repo.listCases(), throwsStateError);
  });

  test('terminal concern is an incident, never reopens or finalizes', () async {
    final calls = <String>[];
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'ngo',
      rpc: (name, _) async {
        calls.add(name);
        if (name == 'get_my_route_resolution') {
          return {...status(reported: true), 'status': 'RESOLVED'};
        }
        return {
          'case_id': caseId,
          'route_id': route,
          'status': 'INCIDENT_RECORDED',
        };
      },
    );
    await repo.incident(route, 'local-task');
    expect(calls, [
      'get_my_route_resolution',
      'report_route_resolution_incident',
    ]);
    expect(await repo.pending(route), isEmpty);
  });

  test('default disabled makes no API request', () async {
    var calls = 0;
    final repo = RouteResolutionRepository(
      identity: () => 'ngo',
      rpc: (_, _) async {
        calls++;
        return {};
      },
    );
    expect((await repo.read(route))['status'], 'DISABLED');
    await expectLater(repo.report(route, 'VEHICLE_FAILURE'), throwsStateError);
    expect(calls, 0);
  });

  testWidgets('opening and refreshing is read only; no finalizer in NGO UI', (
    tester,
  ) async {
    final calls = <String>[];
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'ngo',
      rpc: (name, _) async {
        calls.add(name);
        expect(name, 'get_my_route_resolution');
        return status();
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RouteResolutionPage(routeId: route, repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Report cannot continue'), findsNothing);
    expect(
      find.text(
        'No legacy route case exists for this route. Use the individual claim screen for custody statements.',
      ),
      findsOneWidget,
    );
    expect(find.text('Finalize'), findsNothing);
    expect(calls, ['get_my_route_resolution']);
    await tester.tap(find.byTooltip('Refresh resolution'));
    await tester.pumpAndSettle();
    expect(calls, ['get_my_route_resolution', 'get_my_route_resolution']);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'duplicate taps invoke report once and archive only confirmed result',
    () async {
      final started = Completer<void>(),
          reply = Completer<Map<String, dynamic>>();
      var writes = 0;
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'get_my_route_resolution') return status();
          expect(name, 'report_my_route_interruption');
          writes++;
          started.complete();
          return reply.future;
        },
      );
      final first = repo.report(route, 'VEHICLE_FAILURE');
      await started.future;
      final saved = await repo.pending(route);
      expect(saved['request_id'], isA<String>());
      await expectLater(
        repo.report(route, 'VEHICLE_FAILURE'),
        throwsStateError,
      );
      reply.complete({
        'route_id': route,
        'case_id': caseId,
        'version': 1,
        'status': 'AWAITING_EVIDENCE',
      });
      await first;
      expect(writes, 1);
      expect(await repo.pending(route), isEmpty);
      expect(
        (await SharedPreferences.getInstance())
            .getStringList('route_resolution_ngo_local-route_history')!
            .length,
        1,
      );
    },
  );

  test(
    'lost response is reconciled after restart without retrying write',
    () async {
      var writes = 0;
      String? request;
      final calls = <String>[];
      Future<Object?> rpc(String name, Map<String, dynamic> args) async {
        calls.add(name);
        if (name == 'get_my_route_resolution') return status();
        if (name == 'report_my_route_interruption') {
          writes++;
          request = args['p_request'] as String;
          throw TimeoutException('local lost response');
        }
        expect(name, 'get_my_route_resolution_receipt');
        expect(args['p_request'], request);
        return {
          'outcome': 'FOUND',
          'request_id': request,
          'result': {'case_id': caseId, 'route_id': route},
        };
      }

      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: rpc,
      );
      await expectLater(
        repo.report(route, 'VEHICLE_FAILURE'),
        throwsA(isA<TimeoutException>()),
      );
      final saved = await repo.pending(route);
      final reopened = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: rpc,
      );
      expect(
        (await reopened.pending(route))['request_id'],
        saved['request_id'],
      );
      expect((await reopened.reconcile(route))!['case_id'], caseId);
      expect(writes, 1);
      expect(calls.last, 'get_my_route_resolution_receipt');
    },
  );

  test('NOT_FOUND retains original request and blocks replacement', () async {
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'ngo',
      rpc: (name, args) async {
        if (name == 'get_my_route_resolution') return status();
        if (name == 'get_my_route_resolution_receipt') {
          return {'outcome': 'NOT_FOUND', 'request_id': args['p_request']};
        }
        throw TimeoutException('local uncertain');
      },
    );
    await expectLater(
      repo.report(route, 'VEHICLE_FAILURE'),
      throwsA(isA<TimeoutException>()),
    );
    final saved = await repo.pending(route);
    expect(await repo.reconcile(route), isNull);
    await expectLater(repo.report(route, 'VEHICLE_FAILURE'), throwsStateError);
    expect(await repo.pending(route), saved);
  });

  test(
    'retired route interruption error is fail-closed and retains the request',
    () async {
      final calls = <String>[];
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => 'ngo',
        rpc: (name, args) async {
          calls.add(name);
          if (name == 'get_my_route_resolution') return status();
          if (name == 'report_my_route_interruption') {
            expect(args['p_request'], isA<String>());
            throw const PostgrestException(
              message: 'NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED',
              code: 'P0001',
            );
          }
          if (name == 'get_my_route_resolution_receipt') {
            return {'outcome': 'NOT_FOUND', 'request_id': args['p_request']};
          }
          fail('Unexpected RPC: $name');
        },
      );

      Object? failure;
      try {
        await repo.report(route, 'VEHICLE_FAILURE');
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<PostgrestException>());
      expect(
        resolutionError(failure!),
        contains('NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED'),
      );

      final saved = await repo.pending(route);
      expect(saved['method'], 'report_my_route_interruption');
      expect(saved['request_id'], isA<String>());
      expect(await repo.reconcile(route), isNull);
      expect(await repo.pending(route), saved);

      await expectLater(
        repo.report(route, 'VEHICLE_FAILURE'),
        throwsStateError,
      );
      expect(
        calls.where((name) => name == 'report_my_route_interruption'),
        hasLength(1),
      );
    },
  );

  test(
    'account switch leaves original request preserved and inaccessible to new owner',
    () async {
      var owner = 'ngo';
      final repo = RouteResolutionRepository(
        enabled: true,
        identity: () => owner,
        rpc: (name, _) async {
          if (name == 'get_my_route_resolution') return status();
          owner = 'other';
          return {'case_id': caseId, 'route_id': route};
        },
      );
      await expectLater(
        repo.report(route, 'VEHICLE_FAILURE'),
        throwsStateError,
      );
      expect(await repo.pending(route), isEmpty);
      owner = 'ngo';
      expect(await repo.pending(route), isNotEmpty);
    },
  );

  test('wrong receipt case cannot discard evidence request', () async {
    final repo = RouteResolutionRepository(
      enabled: true,
      identity: () => 'ngo',
      rpc: (name, args) async {
        if (name == 'get_my_route_resolution') return status(reported: true);
        if (name == 'get_my_route_resolution_receipt') {
          return {
            'outcome': 'FOUND',
            'request_id': args['p_request'],
            'result': {'case_id': 'wrong'},
          };
        }
        throw TimeoutException('local uncertain');
      },
    );
    await expectLater(
      repo.submit(route, 'task', 'UNKNOWN_CUSTODY'),
      throwsA(isA<TimeoutException>()),
    );
    final saved = await repo.pending(route);
    expect((saved['params'] as Map)['p_version'], 2);
    await expectLater(repo.reconcile(route), throwsStateError);
    expect(await repo.pending(route), saved);
  });

  testWidgets('disabled prototype page offers no enabled business action', (
    tester,
  ) async {
    final repo = RouteResolutionRepository(
      identity: () => 'ngo',
      rpc: (_, _) async => throw StateError('No I/O allowed'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RouteResolutionPage(routeId: route, repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Route resolution is not activated.'), findsOneWidget);
    expect(find.text('Report cannot continue'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
