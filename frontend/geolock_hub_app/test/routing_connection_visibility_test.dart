// Offline widget regression: no live Supabase or planner calls.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/routing_diagnostics_page.dart';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';
import 'package:geolock_hub_app/ui/geolock_role_style.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'planner warning owns the support action and refresh stays separate',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var overviewReads = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'synthetic-ngo',
        rpc: (name, _) async {
          if (name == 'get_my_routing_overview') {
            overviewReads++;
            return {
              'contract': 'geolock.ngo-routing.v1',
              'ngo_id': 'synthetic-ngo',
              'policy_id': 'policy',
              'authorization_enforced': true,
              'eligible_tasks': [],
              'routes': [],
            };
          }
          if (name == 'list_my_vehicles') return {'vehicles': []};
          if (name == 'get_my_claim_cards_v2') return [];
          fail('Unexpected RPC: $name');
        },
        planner: (_) async => fail('No planning expected'),
        plannerReady: () async => throw RoutingRequestFailure(
          'Synthetic timeout',
          code: 'PLANNER_HEALTH_TIMEOUT',
          phase: 'planner_health',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.2)),
            child: child!,
          ),
          home: NgoRoutesPage(repository: repo),
        ),
      );
      await tester.pumpAndSettle();
      final warning = find.byKey(const Key('planner-connection-warning'));
      final refresh = find.byKey(const Key('routes-refresh-notice'));
      final support = find.byKey(const Key('planning-route-support'));
      expect(tester.widget<GeoNoticeCard>(warning).tone, GeoTone.warning);
      expect(find.descendant(of: warning, matching: support), findsOneWidget);
      expect(support, findsOneWidget);
      expect(refresh, findsNothing);

      await tester.pump(const Duration(seconds: 31));
      expect(tester.widget<GeoNoticeCard>(refresh).tone, GeoTone.info);
      final refreshButton = find.descendant(
        of: refresh,
        matching: find.text('Refresh routes'),
      );
      await tester.ensureVisible(refreshButton);
      await tester.pumpAndSettle();
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();
      expect(overviewReads, 2);
      expect(refresh, findsNothing);
      await tester.ensureVisible(support);
      await tester.tap(support);
      await tester.pumpAndSettle();
      expect(find.text('Route support'), findsOneWidget);
      expect(find.text('Check connection'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('support shows a failed check only after a read-only attempt', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var checks = 0;
    final repo = NgoRoutingRepository(
      identity: () => 'synthetic-ngo',
      rpc: (_, _) async => throw StateError('Unexpected RPC'),
      planner: (_) async => throw StateError('Unexpected planning'),
      plannerReady: () async {
        checks++;
        throw RoutingRequestFailure(
          'Synthetic connection failure',
          code: 'PLANNER_HEALTH_TIMEOUT',
          phase: 'planner_health',
        );
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
        home: RoutingDiagnosticsPage(
          repository: repo,
          operation: const {},
          planning: const {},
        ),
      ),
    );
    final result = find.byKey(const Key('planner-connection-result'));
    expect(result, findsNothing);
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(checks, 1);
    expect(result, findsOneWidget);
    expect(find.textContaining('Connection check failed'), findsOneWidget);
    expect(
      find.text('The planner connection check timed out.'),
      findsOneWidget,
    );
    final diagnostics = find.text('Connection diagnostics');
    await tester.ensureVisible(diagnostics);
    await tester.pumpAndSettle();
    await tester.tap(diagnostics);
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data == 'Code: PLANNER_HEALTH_TIMEOUT',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

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
    final button = find.text('Check connection');
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
        'Planner connection confirmed. No snapshot or route was created.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final configured in [false, true]) {
    testWidgets(
      'planner button visibility follows configuration: $configured',
      (tester) async {
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
        final button = find.text('Check connection');
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
              'Planner connection confirmed. No snapshot or route was created.',
            ),
            findsOneWidget,
          );
        }
        expect(writes, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
