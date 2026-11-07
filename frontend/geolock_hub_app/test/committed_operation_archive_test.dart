import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/routing_policy_display.dart';
import 'automatic_route_operation_test.dart' as f;

Map<String, dynamic> operation() => {
  'request_id': 'request',
  'snapshot_id': 'snapshot',
  'status': 'authorized',
  'intent': 'GENERATE_AND_AUTHORIZE',
  'authorization_request_id': 'authorization-request',
  'authorization': f.receipt()['authorization'],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final state in ['AUTHORISED', 'IN_PROGRESS', 'COMPLETED']) {
    test(
      'archive confirmed $state route retains receipt, old history and execution journal',
      () async {
        final original = operation();
        (original['authorization'] as Map)['audit_reference'] =
            'preserved-audit-ref';
        SharedPreferences.setMockInitialValues({
          'ngo_route_operation_ngo': jsonEncode(original),
          'ngo_route_execution_ngo_route': 'unchanged-execution-journal',
          'ngo_route_operation_history_ngo_older': 'unchanged-old-history',
        });
        final reads = <String>[];
        final repo = NgoRoutingRepository(
          identity: () => 'ngo',
          rpc: (name, _) async {
            reads.add(name);
            if (name != 'get_my_authorized_route') {
              throw StateError('No writes');
            }
            return {...f.detail(), 'route_status': state};
          },
          authorizationReader: (_) async => f.receipt(),
        );
        await repo.finishRouteOperation();
        final prefs = await SharedPreferences.getInstance();
        expect(await repo.routeOperation(), isEmpty);
        expect(
          jsonDecode(
            prefs.getString('ngo_route_operation_history_ngo_request')!,
          ),
          original,
        );
        expect(
          prefs.getString('ngo_route_execution_ngo_route'),
          'unchanged-execution-journal',
        );
        expect(
          prefs.getString('ngo_route_operation_history_ngo_older'),
          'unchanged-old-history',
        );
        expect(reads, ['get_my_authorized_route']);
      },
    );
  }

  for (final failure in [
    'missing-receipt',
    'transport',
    'foreign-owner',
    'wrong-binding',
    'changed-receipt',
    'history-conflict',
  ]) {
    test('$failure keeps original request blocked without writes', () async {
      final original = operation();
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': jsonEncode(original),
        if (failure == 'history-conflict')
          'ngo_route_operation_history_ngo_request': 'earlier-evidence',
      });
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          expect(name, 'get_my_authorized_route');
          return {
            ...f.detail(),
            if (failure == 'wrong-binding') 'candidate_id': 'different',
          };
        },
        authorizationReader: (_) async {
          if (failure == 'transport') {
            throw TimeoutException('offline');
          }
          if (failure == 'missing-receipt') {
            return {
              'ngo_id': 'ngo',
              'kind': 'AUTHORIZATION_UNCONFIRMED',
              'request_id': 'request',
              'snapshot_id': 'snapshot',
            };
          }
          return {
            ...f.receipt(),
            if (failure == 'foreign-owner') 'ngo_id': 'other',
            if (failure == 'changed-receipt')
              'authorization_request_id': 'different',
          };
        },
      );
      await expectLater(repo.finishRouteOperation(), throwsA(anything));
      expect((await repo.routeOperation())['request_id'], 'request');
      expect(
        (await repo.routeOperation())['authorization'],
        original['authorization'],
      );
      if (failure == 'history-conflict') {
        expect(
          (await SharedPreferences.getInstance()).getString(
            'ngo_route_operation_history_ngo_request',
          ),
          'earlier-evidence',
        );
      }
    });
  }

  test(
    'archival blocks concurrent archive and new generation until verification finishes',
    () async {
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': jsonEncode(operation()),
      });
      final receiptRead = Completer<Object?>();
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (_, _) async => f.detail(),
        authorizationReader: (_) => receiptRead.future,
      );
      final archiving = repo.finishRouteOperation();
      await expectLater(repo.finishRouteOperation(), throwsStateError);
      await expectLater(
        repo.generateAndAuthorize(['v3'], 'new', 'policy'),
        throwsStateError,
      );
      receiptRead.complete(f.receipt());
      await archiving;
      expect(await repo.routeOperation(), isEmpty);
    },
  );

  test(
    'confirmed archival permits one distinct new operation while preserving old receipt',
    () async {
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': jsonEncode(operation()),
      });
      var snapshots = 0, plans = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, params) async {
          if (name == 'get_my_authorized_route') return f.detail();
          if (name == 'begin_my_routing_snapshot') {
            snapshots++;
            expect(params['p_vehicle_ids'], ['v3']);
            return {'ngo_id': 'ngo', 'snapshot_id': 'new-snapshot'};
          }
          throw StateError('No pickup or release permitted');
        },
        authorizationReader: (_) async => f.receipt(),
        authorizationCapabilities: (_) async => {
          'ngo_id': 'ngo',
          'contract': 'geolock.routing-auto-now.v1',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        combinedPlanner: (body) async {
          plans++;
          expect(body['request_id'], 'new-request');
          return {
            'kind': 'ADVISORY_CANDIDATE',
            'ngo_id': 'ngo',
            'request_id': 'new-request',
            'snapshot_id': 'new-snapshot',
            'outcome': 'INFEASIBLE',
            'dispatch_authority_issued': false,
          };
        },
      );
      await repo.finishRouteOperation();
      final prefs = await SharedPreferences.getInstance();
      final history = prefs.getString(
        'ngo_route_operation_history_ngo_request',
      );
      await repo.generateAndAuthorize(
        ['v3'],
        'new-request',
        reviewedPilotPolicyId,
      );
      expect(snapshots, 1);
      expect(plans, 1);
      expect((await repo.routeOperation())['request_id'], 'new-request');
      expect(
        prefs.getString('ngo_route_operation_history_ngo_request'),
        history,
      );
    },
  );

  test(
    'confirmed authorization auto archives planning and allows another vehicle while preserving both routes',
    () async {
      final rpcCalls = <String>[];
      var snapshotNumber = 0;
      var currentReceipt = <String, dynamic>{};
      final routes = <String, Map<String, dynamic>>{};
      Map<String, dynamic> makeReceipt(String request, int n) => {
        'kind': 'DATABASE_AUTHORIZATION_RECEIPT',
        'ngo_id': 'ngo',
        'request_id': request,
        'snapshot_id': 'snapshot-$n',
        'authorization_request_id': 'authorization-request-$n',
        'authorization': {
          'snapshot_id': 'snapshot-$n',
          'candidate_id': 'candidate-$n',
          'departure_mode': 'AUTO_NOW',
          'route_ids': ['route-$n'],
        },
      };
      Map<String, dynamic> makeDetail(int n) => {
        ...f.detail(),
        'route_id': 'route-$n',
        'snapshot_id': 'snapshot-$n',
        'candidate_id': 'candidate-$n',
        'vehicle_id': n == 1 ? 'vehicle-a' : 'vehicle-b',
        'route_status': n == 1 ? 'IN_PROGRESS' : 'AUTHORISED',
        'authorization_confirmed': true,
      };
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, params) async {
          rpcCalls.add(name);
          if (name == 'begin_my_routing_snapshot') {
            snapshotNumber++;
            expect(params['p_vehicle_ids'], [
              snapshotNumber == 1 ? 'vehicle-a' : 'vehicle-b',
            ]);
            return {'ngo_id': 'ngo', 'snapshot_id': 'snapshot-$snapshotNumber'};
          }
          if (name == 'get_my_authorized_route') {
            final id = params['p_route'];
            final route = routes[id];
            if (route != null) return route;
            return makeDetail(snapshotNumber);
          }
          throw StateError(
            'No close, cancel or vehicle-release RPC is allowed',
          );
        },
        authorizationCapabilities: (_) async => {
          'ngo_id': 'ngo',
          'contract': 'geolock.routing-auto-now.v1',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        combinedPlanner: (body) async {
          final n = body['request_id'] == 'request-a' ? 1 : 2;
          currentReceipt = makeReceipt(body['request_id'] as String, n);
          routes['route-$n'] = makeDetail(n);
          return currentReceipt;
        },
        authorizationReader: (_) async => currentReceipt,
      );

      final first = await repo.generateAndAuthorize(
        ['vehicle-a'],
        'request-a',
        'policy',
      );
      expect(first['kind'], 'DATABASE_AUTHORIZATION_RECEIPT');
      expect(await repo.routeOperation(), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_history_ngo_request-a',
        ),
        isNotNull,
      );

      final second = await repo.generateAndAuthorize(
        ['vehicle-b'],
        'request-b',
        'policy',
      );
      expect(second['kind'], 'DATABASE_AUTHORIZATION_RECEIPT');
      expect(await repo.routeOperation(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('ngo_route_operation_history_ngo_request-a'),
        isNotNull,
      );
      expect(
        prefs.getString('ngo_route_operation_history_ngo_request-b'),
        isNotNull,
      );
      expect(routes['route-1']!['route_status'], 'IN_PROGRESS');
      expect(routes['route-1']!['vehicle_id'], 'vehicle-a');
      expect(routes['route-2']!['vehicle_id'], 'vehicle-b');
      expect(
        rpcCalls.where((name) => name != 'begin_my_routing_snapshot'),
        everyElement('get_my_authorized_route'),
      );
    },
  );

  test(
    'receipt timeout leaves confirmed operation for restart recovery without another authorization',
    () async {
      var plannerCalls = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'begin_my_routing_snapshot') {
            return {'ngo_id': 'ngo', 'snapshot_id': 'snapshot'};
          }
          if (name == 'get_my_authorized_route') return f.detail();
          throw StateError('Unexpected state-changing RPC: $name');
        },
        authorizationCapabilities: (_) async => {
          'ngo_id': 'ngo',
          'contract': 'geolock.routing-auto-now.v1',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        combinedPlanner: (_) async {
          plannerCalls++;
          return f.receipt();
        },
        authorizationReader: (_) async => throw TimeoutException('offline'),
      );
      final confirmed = await repo.generateAndAuthorize(
        ['vehicle'],
        'request',
        'policy',
      );
      expect(confirmed['kind'], 'DATABASE_AUTHORIZATION_RECEIPT');
      expect((await repo.routeOperation())['status'], 'authorized');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_history_ngo_request',
        ),
        isNull,
      );

      final reopened = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          expect(name, 'get_my_authorized_route');
          return f.detail();
        },
        combinedPlanner: (_) async => throw StateError('Must not reauthorize'),
        authorizationCapabilities: (_) async =>
            throw StateError('Must not restart planning'),
        authorizationReader: (_) async => f.receipt(),
      );
      expect(await reopened.restoreRouteOperation(), isEmpty);
      expect(plannerCalls, 1);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_history_ngo_request',
        ),
        isNotNull,
      );
    },
  );

  test(
    'failed and uncertain authorization outcomes are not auto archived',
    () async {
      SharedPreferences.setMockInitialValues({});
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async => name == 'begin_my_routing_snapshot'
            ? {'ngo_id': 'ngo', 'snapshot_id': 'snapshot'}
            : throw StateError('No route should be fetched for failure'),
        authorizationCapabilities: (_) async => {
          'ngo_id': 'ngo',
          'contract': 'geolock.routing-auto-now.v1',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        combinedPlanner: (_) async => {
          'kind': 'ADVISORY_CANDIDATE',
          'ngo_id': 'ngo',
          'request_id': 'request',
          'snapshot_id': 'snapshot',
          'outcome': 'INFEASIBLE',
          'dispatch_authority_issued': false,
        },
        authorizationReader: (_) async =>
            throw StateError('No receipt expected'),
      );
      await repo.generateAndAuthorize(['vehicle'], 'request', 'policy');
      expect((await repo.routeOperation())['status'], 'infeasible');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_history_ngo_request',
        ),
        isNull,
      );
    },
  );

  test('in-flight combined operation cannot be archived', () async {
    final pending = Completer<Object?>();
    final repo = NgoRoutingRepository(
      identity: () => 'ngo',
      rpc: (name, _) async => name == 'begin_my_routing_snapshot'
          ? {'ngo_id': 'ngo', 'snapshot_id': 'snapshot'}
          : f.detail(),
      authorizationReader: (_) async => f.receipt(),
      authorizationCapabilities: (_) async => {
        'ngo_id': 'ngo',
        'contract': 'geolock.routing-auto-now.v1',
        'automatic_departure': true,
        'combined_generation_enabled': true,
      },
      combinedPlanner: (_) => pending.future,
    );
    final running = repo.generateAndAuthorize(
      ['v3'],
      'request',
      reviewedPilotPolicyId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await expectLater(repo.finishRouteOperation(), throwsStateError);
    expect((await repo.routeOperation())['request_id'], 'request');
    pending.complete(f.receipt());
    await running;
    expect(await repo.routeOperation(), isEmpty);
  });

  test(
    'V3 260 exceeds reviewed policy; 240 allowed; unknown policy not invented',
    () {
      expect(
        vehicleHorizonWarning({
          'vehicle_label': 'V3',
          'max_route_duration_min': 260,
        }, reviewedPilotPolicyId),
        contains('240'),
      );
      expect(
        vehicleHorizonWarning({
          'vehicle_label': 'V3',
          'max_route_duration_min': '240.000',
        }, reviewedPilotPolicyId),
        isNull,
      );
      expect(reviewedPolicyHorizon('unrecognized-policy'), isNull);
    },
  );

  for (final duration in [240, 260]) {
    testWidgets(
      'manual archive fallback unlocks planning after receipt-read timeout for V3 ($duration)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'ngo_route_operation_ngo': jsonEncode(operation()),
        });
        final calls = <String>[];
        var receiptReads = 0;
        final repo = NgoRoutingRepository(
          identity: () => 'ngo',
          rpc: (name, _) async {
            calls.add(name);
            switch (name) {
              case 'list_my_vehicles':
                return {
                  'vehicles': [
                    {
                      'vehicle_id': 'v3',
                      'ngo_user_id': 'ngo',
                      'vehicle_label': 'V3',
                      'payload_capacity_kg': 600,
                      'max_route_duration_min': duration,
                      'eligible_for_planning': true,
                    },
                  ],
                };
              case 'get_my_routing_overview':
                return {
                  'contract': 'geolock.ngo-routing.v1',
                  'ngo_id': 'ngo',
                  'policy_id': reviewedPilotPolicyId,
                  'authorization_enforced': true,
                  'eligible_tasks': [
                    {
                      'claim_id': 'fresh',
                      'task_id': 'fresh-task',
                      'title': 'Fresh',
                      'load_kg': 190,
                    },
                  ],
                  'routes': [],
                };
              case 'get_my_claim_cards_v2':
                return [];
              case 'get_my_authorized_route':
                return {...f.detail(), 'route_status': 'IN_PROGRESS'};
              default:
                throw StateError('Unexpected write: $name');
            }
          },
          authorizationReader: (_) async {
            // Simulate an automatic archive read interruption on app reopen;
            // the explicit fallback succeeds on retry.
            if (receiptReads++ == 0) throw TimeoutException('offline');
            return f.receipt();
          },
          authorizationCapabilities: (_) async => {},
          combinedPlanner: (_) async =>
              throw StateError('No planning allowed in this UI test'),
        );
        await tester.pumpWidget(
          MaterialApp(home: NgoRoutesPage(repository: repo)),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Previously authorized route retained'),
          findsOneWidget,
        );
        final checkbox = tester.widget<CheckboxListTile>(
          find.byType(CheckboxListTile),
        );
        expect(checkbox.onChanged != null, duration == 240);
        if (duration == 240) {
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pumpAndSettle();
        } else {
          expect(
            find.textContaining('exceeds the approved policy horizon'),
            findsOneWidget,
          );
        }
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('generate-route')))
              .onPressed,
          isNull,
        );
        await tester.ensureVisible(
          find.byKey(const Key('archive-authorization')),
        );
        await tester.tap(find.byKey(const Key('archive-authorization')));
        await tester.pumpAndSettle();
        // Confirmation has not archived anything yet.
        expect((await repo.routeOperation()).isNotEmpty, true);
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(await repo.routeOperation(), isEmpty);
        expect(
          tester
                  .widget<FilledButton>(find.byKey(const Key('generate-route')))
                  .onPressed !=
              null,
          duration == 240,
        );
        expect(
          calls.every(
            (n) => {
              'list_my_vehicles',
              'get_my_routing_overview',
              'get_my_claim_cards_v2',
              'get_my_authorized_route',
            }.contains(n),
          ),
          true,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
