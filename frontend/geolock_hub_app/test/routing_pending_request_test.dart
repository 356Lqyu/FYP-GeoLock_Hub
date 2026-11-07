// Synthetic persistence/RPCs only; no Supabase calls or planning writes.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';

const currentMethods = ['fcfs', 'nearest_neighbour', 'proposed'];
const legacyMethods = [
  'fcfs',
  'nearest_neighbour',
  'distance_only',
  'proposed',
];

Map<String, dynamic> result([List<String?> methods = currentMethods]) => {
  'ngo_id': 'owner',
  'kind': 'ADVISORY_CANDIDATE',
  'dispatch_authority_issued': false,
  'snapshot_id': 'snapshot',
  'outcome': 'INFEASIBLE',
  'validation_status': 'LOCAL_ONLY',
  'methods': [
    for (final name in methods)
      {
        'method': name,
        'plan': {
          'method': name,
          'dispatch_authority_issued': false,
          'routes': [],
        },
        'validation': {'metrics': {}},
      },
  ],
};

void main() {
  test(
    'failed phone health check creates no snapshot and no pending write context',
    () async {
      var rpcCalls = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'owner',
        rpc: (name, p) async {
          rpcCalls++;
          return {};
        },
        planner: (_) async => result(),
        plannerReady: () async => throw RoutingRequestFailure(
          'Synthetic disconnected phone',
          code: 'PLANNER_HEALTH_CONNECTION_FAILED',
          phase: 'planner_health',
        ),
      );
      await expectLater(repo.plan(['v'], 'r', 'policy'), throwsStateError);
      expect(rpcCalls, 0);
      expect(await repo.pendingPlanning(), isEmpty);
    },
  );
  setUp(() => SharedPreferences.setMockInitialValues({}));

  NgoRoutingRepository comparisonRepository(List<String?> methods) =>
      NgoRoutingRepository(
        identity: () => 'owner',
        rpc: (_, _) async => {'ngo_id': 'owner', 'snapshot_id': 'snapshot'},
        planner: (_) async => result(methods),
      );

  for (final methods in [currentMethods, legacyMethods]) {
    test('accepts exact ${methods.length}-method advisory result', () async {
      final repo = comparisonRepository(methods);
      expect(await repo.plan(['v'], 'request', 'policy'), result(methods));
    });
  }

  const invalidMethodSets = <String, List<String?>>{
    'missing proposed': ['fcfs', 'nearest_neighbour'],
    'duplicate': ['fcfs', 'fcfs', 'proposed'],
    'unexpected': ['fcfs', 'nearest_neighbour', 'unexpected'],
    'null': ['fcfs', 'nearest_neighbour', null],
    'legacy duplicate': ['fcfs', 'nearest_neighbour', 'proposed', 'proposed'],
    'legacy with extra method': [...legacyMethods, 'unexpected'],
  };
  for (final entry in invalidMethodSets.entries) {
    test('rejects advisory methods with ${entry.key}', () async {
      final repo = comparisonRepository(entry.value);
      await expectLater(
        repo.plan(['v'], 'request', 'policy'),
        throwsA(isA<FormatException>()),
      );
      expect((await repo.pendingPlanning())['status'], 'pending');
    });
  }
  test(
    'HTTP unknown survives repository recreation and reuses snapshot without another begin RPC',
    () async {
      var begins = 0;
      var attempts = 0;
      final requests = <String>[];
      NgoRoutingRepository repository() => NgoRoutingRepository(
        identity: () => 'owner',
        rpc: (name, params) async {
          expect(name, 'begin_my_routing_snapshot');
          begins++;
          expect(params['p_request'], 'original-request');
          return {'ngo_id': 'owner', 'snapshot_id': 'snapshot'};
        },
        planner: (body) async {
          attempts++;
          requests.add(body['request_id'] as String);
          expect(body['snapshot_id'], 'snapshot');
          if (attempts == 1) {
            throw RoutingRequestFailure(
              'Synthetic timeout',
              code: 'PLANNER_TIMEOUT',
              phase: 'planner_http',
              outcomeUnknown: true,
            );
          }
          return result();
        },
      );
      var repo = repository();
      await expectLater(
        repo.plan(['v'], 'original-request', 'policy'),
        throwsStateError,
      );
      expect((await repo.pendingPlanning())['status'], 'pending');
      await expectLater(repo.clearFinishedPlanning(), throwsStateError);
      repo = repository();
      final response = await repo.plan(
        ['v'],
        'new-ui-request-must-not-be-used',
        'policy',
      );
      expect(response['outcome'], 'INFEASIBLE');
      expect(begins, 1);
      expect(requests, ['original-request', 'original-request']);
      expect((await repo.pendingPlanning())['status'], 'infeasible');
      await repo.clearFinishedPlanning();
      expect(await repo.pendingPlanning(), isEmpty);
    },
  );
  test(
    'unknown snapshot response preserves the original idempotency key',
    () async {
      final ids = <String>[];
      final repo = NgoRoutingRepository(
        identity: () => 'owner',
        rpc: (name, p) async {
          ids.add(p['p_request'] as String);
          if (ids.length == 1) throw TimeoutException('SYNTHETIC');
          return {'ngo_id': 'owner', 'snapshot_id': 'snapshot'};
        },
        planner: (_) async => result(),
      );
      await expectLater(
        repo.plan(['v'], 'first', 'policy'),
        throwsA(
          isA<RoutingRequestFailure>().having(
            (e) => e.phase,
            'phase',
            'begin_my_routing_snapshot',
          ),
        ),
      );
      await repo.plan(['v'], 'second', 'policy');
      expect(ids, ['first', 'first']);
    },
  );
  test(
    'changing policy or vehicles never silently replaces a pending request',
    () async {
      var calls = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'owner',
        rpc: (name, p) async {
          calls++;
          throw TimeoutException('SYNTHETIC');
        },
        planner: (_) async => result(),
      );
      await expectLater(repo.plan(['v'], 'first', 'policy'), throwsStateError);
      await expectLater(
        repo.plan(['other-v'], 'second', 'policy'),
        throwsStateError,
      );
      await expectLater(
        repo.plan(['v'], 'third', 'different-policy'),
        throwsStateError,
      );
      expect(calls, 1);
      expect((await repo.pendingPlanning())['request_id'], 'first');
    },
  );
}
