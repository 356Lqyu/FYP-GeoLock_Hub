import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/routing_feedback.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';

void main() {
  test(
    'lease display uses server time and distinguishes completed custody',
    () {
      final c = <String, dynamic>{
        'claim_status': 'ACTIVE',
        'lease_status': 'ACTIVE',
        'server_now': '2026-10-28T00:00:00Z',
        'lease_expires_at': '2026-10-28T05:30:10Z',
      };
      expect(claimLeaseMessage(c, eligible: true), contains('330 min 10 sec'));
      expect(claimLeaseMessage(c, eligible: false), contains('Not eligible'));
      expect(
        claimLeaseMessage({
          ...c,
          'lease_is_expired': true,
          'lease_recovery_pending': true,
        }, eligible: false),
        contains('recovery pending'),
      );
      expect(
        claimLeaseMessage({
          ...c,
          'claim_status': 'COMPLETED',
          'lease_is_expired': true,
        }, eligible: false),
        startsWith('Claim completed'),
      );
      expect(
        claimLeaseMessage({
          ...c,
          'claim_status': 'RECONCILIATION_REQUIRED',
        }, eligible: false),
        contains('Reconciliation required'),
      );
      expect(
        claimLeaseMessage({}, eligible: false),
        contains('Lease time unavailable'),
      );
    },
  );

  test('typed errors are friendly without exposing operation IDs', () {
    for (final code in [
      'LEASE_TOO_SHORT',
      'CAPACITY_VIOLATION',
      'NO_FEASIBLE_PLAN',
      'PLAN_STALE_TASK',
      'RECONCILIATION_REQUIRED',
    ]) {
      expect(routingFailureMessage(code), isNotNull);
    }
    expect(
      routingError(
        RoutingRequestFailure(
          'raw request secret',
          code: 'UNRECOGNIZED',
          phase: 'combined',
          requestId: 'private-request-id',
          outcomeUnknown: true,
        ),
      ),
      isNot(contains('private-request-id')),
    );
    expect(
      routeOperationMessage({'status': 'blocked', 'phase': 'preflight'}),
      contains('initial checks'),
    );
  });

  testWidgets(
    'normal flow hides evidence IDs and retains uncertain operation',
    (tester) async {
      final operation = jsonEncode({
        'request_id': 'preserved-request',
        'status': 'blocked',
        'phase': 'preflight',
        'intent': 'GENERATE_AND_AUTHORIZE',
      });
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': operation,
      });
      final writes = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async {
          if (name == 'list_my_vehicles') return {'vehicles': []};
          if (name == 'get_my_claim_cards_v2') {
            return [
              {
                'claim_id': 'claim',
                'title': 'Test donation',
                'claim_status': 'ACTIVE',
                'lease_status': 'ACTIVE',
                'task_status': 'CONFIRMED',
                'listing_weight_kg': 12,
                'server_now': '2026-10-28T00:00:00Z',
                'lease_expires_at': '2026-10-28T05:00:00Z',
              },
            ];
          }
          if (name == 'get_my_routing_overview') {
            return {
              'contract': 'geolock.ngo-routing.v1',
              'ngo_id': 'ngo',
              'policy_id': 'policy',
              'authorization_enforced': true,
              'eligible_tasks': [
                {
                  'claim_id': 'claim',
                  'task_id': 'task',
                  'title': 'Test donation',
                  'load_kg': 12,
                },
              ],
              'routes': [],
            };
          }
          writes.add(name);
          throw StateError('No write permitted');
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Test donation'), findsOneWidget);
      expect(find.textContaining('300 min'), findsOneWidget);
      expect(find.textContaining('preserved-request'), findsNothing);
      expect(find.text('Resume same operation'), findsNothing);
      final generate = tester.widget<FilledButton>(
        find.byKey(const Key('generate-route')),
      );
      expect(generate.onPressed, isNull);
      await tester.ensureVisible(find.byTooltip('Route support'));
      await tester.tap(find.byTooltip('Route support'));
      await tester.pumpAndSettle();
      expect(find.textContaining('preserved-request'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_ngo',
        ),
        operation,
      );
      expect(writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'archiving finished advisory context preserves its original evidence',
    () async {
      final text = jsonEncode({
        'request_id': 'original',
        'status': 'candidate_ready',
        'snapshot_id': 'historical',
      });
      SharedPreferences.setMockInitialValues({
        'ngo_planning_request_ngo': text,
      });
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (_, _) async => throw StateError('No RPC'),
      );
      await repo.clearFinishedPlanning();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ngo_planning_history_ngo_original'), text);
      expect(prefs.getString('ngo_planning_request_ngo'), isNull);
    },
  );
}
