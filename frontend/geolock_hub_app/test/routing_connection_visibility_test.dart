// Offline widget regression: no live Supabase or planner calls.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('auth-free health check is available without an NGO session', (
    tester,
  ) async {
    var healthChecks = 0;
    var rpcCalls = 0;
    final repo = NgoRoutingRepository(
      identity: () => null,
      rpc: (_, _) async {
        rpcCalls++;
        throw StateError('No RPC expected');
      },
      planner: (_) async => throw StateError('No planning expected'),
      plannerReady: () async {
        healthChecks++;
      },
    );
    await tester.pumpWidget(MaterialApp(home: NgoRoutesPage(repository: repo)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Route support'));
    await tester.tap(find.byTooltip('Route support'));
    await tester.pumpAndSettle();
    final button = find.text('Check planner connection (read only)');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      healthChecks,
      2,
    ); // one automatic read on opening, one explicit check
    expect(rpcCalls, 0);
    expect(find.byKey(const Key('planner-configuration-error')), findsNothing);
    expect(
      find.text(
        'Planner ACTIVE for DEV. Read-only check; no snapshot or route created.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final configured in [false, true]) {
    testWidgets('planner button visibility follows configuration: $configured', (
      tester,
    ) async {
      var healthChecks = 0;
      final writes = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, params) async {
          if (name == 'list_my_vehicles') return {'vehicles': []};
          if (name == 'get_my_claim_cards_v2') return [];
          if (name == 'get_my_routing_overview') {
            return {
              'contract': 'geolock.ngo-routing.v1',
              'ngo_id': 'synthetic-ngo',
              'policy_id': 'synthetic-policy',
              'authorization_enforced': true,
              'eligible_tasks': [],
              'routes': [],
            };
          }
          writes.add(name);
          throw StateError('Unexpected operation');
        },
        planner: configured
            ? (_) async => throw StateError('No planning')
            : null,
        plannerReady: configured
            ? () async {
                healthChecks++;
              }
            : null,
      );
      await tester.pumpWidget(
        MaterialApp(home: NgoRoutesPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Route support'));
      await tester.tap(find.byTooltip('Route support'));
      await tester.pumpAndSettle();
      final button = find.text('Check planner connection (read only)');
      final warning = find.text(repo.plannerConfigurationMessage);
      expect(button, configured ? findsOneWidget : findsNothing);
      expect(warning, configured ? findsNothing : findsOneWidget);
      if (configured) {
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(healthChecks, 2);
        expect(
          find.text(
            'Planner ACTIVE for DEV. Read-only check; no snapshot or route created.',
          ),
          findsOneWidget,
        );
      }
      expect(writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
