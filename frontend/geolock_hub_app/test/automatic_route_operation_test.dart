// Offline only: synthetic transports; optional replay of disposable PostgreSQL capture.
import 'dart:async';
import 'dart:convert';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/ngo_routes_page.dart';

Map<String, dynamic> receipt() => {
  'kind': 'DATABASE_AUTHORIZATION_RECEIPT',
  'ngo_id': 'ngo',
  'snapshot_id': 'snapshot',
  'request_id': 'request',
  'authorization_request_id': 'authorization-request',
  'authorization': {
    'snapshot_id': 'snapshot',
    'candidate_id': 'candidate',
    'departure_mode': 'AUTO_NOW',
    'planned_departure_at': '2026-10-27T00:00:00Z',
    'route_ids': ['route'],
  },
};
Map<String, dynamic> detail() => {
  'contract': 'geolock.ngo-routing.v1',
  'ngo_id': 'ngo',
  'route_id': 'route',
  'candidate_id': 'candidate',
  'snapshot_id': 'snapshot',
  'authorization_confirmed': true,
  'route_status': 'AUTHORISED',
  'vehicle_id': 'vehicle',
  'depot_road_node_id': '100',
  'total_distance_km': 3,
  'total_duration_min': 12,
  'departure_at': '2026-10-27T00:00:00Z',
  'actual_started_at': null,
  'can_close': false,
  'can_cancel': true,
  'depot': {'latitude': 3.0, 'longitude': 101.0},
  'stops': [
    {
      'task_id': 'task',
      'claim_id': 'claim',
      'title': 'Pickup',
      'pickup_latitude': 3.01,
      'pickup_longitude': 101.01,
      'pickup_road_node_id': '101',
      'stop_order': 1,
      'task_status': 'PLANNED',
      'load_kg': 20,
      'can_start': true,
      'can_complete': false,
    },
  ],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const capturePath = String.fromEnvironment('GEOLOCK_AUTOMATIC_LOCAL_CAPTURE');
  test(
    'actual disposable SQL receipt and route satisfy the combined Flutter contract',
    () async {
      final capture = routingObject(
        jsonDecode(File(capturePath).readAsStringSync()),
      );
      final actual = routingObject(capture['authorization']);
      final owned = routingObject(capture['ready_detail']);
      final repo = NgoRoutingRepository(
        identity: () => actual['ngo_id'] as String,
        rpc: (name, params) async {
          if (name == 'begin_my_routing_snapshot') {
            return {
              'ngo_id': actual['ngo_id'],
              'snapshot_id': actual['snapshot_id'],
            };
          }
          if (name == 'get_my_authorized_route') return owned;
          throw StateError(
            'Replay does not execute pickup or authorization writes',
          );
        },
        combinedPlanner: (body) async {
          expect(body['authorize_on_success'], true);
          expect(body['request_id'], actual['request_id']);
          return actual;
        },
        authorizationCapabilities: (_) async => {
          'ngo_id': actual['ngo_id'],
          'contract': 'geolock.routing-auto-now.v1',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        authorizationReader: (_) async => actual,
      );
      final result = await repo.generateAndAuthorize(
        [owned['vehicle_id'] as String],
        actual['request_id'] as String,
        'captured-local-policy',
      );
      expect(
        routingRows(result['routes']).single['route_id'],
        owned['route_id'],
      );
      expect(owned['actual_started_at'], isNull);
      expect(owned['authorization_confirmed'], true);
    },
    skip: capturePath.isEmpty ? 'Run with disposable SQL capture path' : false,
  );

  test(
    'unknown operation survives restart and cannot be cleared or replaced',
    () async {
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': jsonEncode({
          'request_id': 'original',
          'snapshot_id': 'snapshot',
          'policy_id': 'policy',
          'vehicle_ids': ['vehicle'],
          'intent': 'GENERATE_AND_AUTHORIZE',
          'status': 'authorization_unknown',
          'phase': 'combined',
        }),
      });
      var writes = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (_, _) async {
          writes++;
          return {};
        },
        combinedPlanner: (_) async {
          writes++;
          return {};
        },
        authorizationCapabilities: (_) async => {},
        authorizationReader: (_) async => {
          'ngo_id': 'ngo',
          'kind': 'AUTHORIZATION_UNCONFIRMED',
          'snapshot_id': 'snapshot',
          'request_id': 'original',
        },
      );
      await expectLater(
        repo.generateAndAuthorize(['vehicle'], 'replacement', 'policy'),
        throwsStateError,
      );
      await expectLater(repo.finishRouteOperation(), throwsStateError);
      expect((await repo.routeOperation())['request_id'], 'original');
      expect(writes, 0);
    },
  );

  test(
    'committed active authorization can archive independently of route closure',
    () async {
      SharedPreferences.setMockInitialValues({
        'ngo_route_operation_ngo': jsonEncode({
          'request_id': 'request',
          'snapshot_id': 'snapshot',
          'intent': 'GENERATE_AND_AUTHORIZE',
          'status': 'authorized',
        }),
      });
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, _) async => {
          ...detail(),
          'route_status': 'AUTHORISED',
          'authorization_confirmed': true,
        },
        authorizationReader: (body) async => {
          ...receipt(),
          'request_id': body['request_id'],
          'snapshot_id': body['snapshot_id'],
        },
      );
      await repo.finishRouteOperation();
      expect(await repo.routeOperation(), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_history_ngo_request',
        ),
        isNotNull,
      );
    },
  );
  test(
    'preflight preserves sanitized rejection status without snapshot write',
    () async {
      SharedPreferences.setMockInitialValues({});
      var writes = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (_, _) async {
          writes++;
          throw StateError('No write permitted');
        },
        authorizationCapabilities: (_) async => throw RoutingRequestFailure(
          'Capability read rejected',
          code: 'DATABASE_REJECTED_REQUEST',
          phase: 'authorization_capabilities_read',
          httpStatus: 409,
          outcomeUnknown: false,
        ),
        combinedPlanner: (_) async => throw StateError('No planning permitted'),
        authorizationReader: (_) async =>
            throw StateError('No receipt lookup required before snapshot'),
      );
      await expectLater(
        repo.generateAndAuthorize(['vehicle'], 'same-request', 'policy'),
        throwsA(isA<RoutingRequestFailure>()),
      );
      final saved = await repo.routeOperation();
      expect(saved['failure_code'], 'DATABASE_REJECTED_REQUEST');
      expect(saved['failure_http_status'], 409);
      expect(saved['phase'], 'preflight');
      expect(saved['request_id'], 'same-request');
      expect(saved['snapshot_id'], isNull);
      expect(writes, 0);
    },
  );
  test(
    'duplicate taps share one operation, one snapshot and one combined request',
    () async {
      var begins = 0, plans = 0;
      var receiptReads = 0;
      final done = Completer<Object?>();
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, params) async {
          if (name == 'begin_my_routing_snapshot') {
            begins++;
            expect(params['p_request'], 'request');
            return {'ngo_id': 'ngo', 'snapshot_id': 'snapshot'};
          }
          if (name == 'get_my_authorized_route') return detail();
          throw StateError('Unexpected write $name');
        },
        authorizationCapabilities: (_) async => {
          'ngo_id': 'ngo',
          'contract': 'geolock.routing-auto-now.v1',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        authorizationReader: (_) async {
          receiptReads++;
          return receipt();
        },
        combinedPlanner: (body) {
          plans++;
          expect(body['authorize_on_success'], true);
          return done.future;
        },
      );
      final first = repo.generateAndAuthorize(['vehicle'], 'request', 'policy');
      final second = repo.generateAndAuthorize(
        ['vehicle'],
        'different-tap-id',
        'policy',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      done.complete(receipt());
      expect((await first)['authorization'], (await second)['authorization']);
      expect(begins, 1);
      expect(plans, 1);
      expect(receiptReads, 1);
      expect(await repo.routeOperation(), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_history_ngo_request',
        ),
        isNotNull,
      );
      expect(plans, 1);
    },
  );

  test(
    'unknown combined response automatically reads the committed receipt without replanning',
    () async {
      var begins = 0, plans = 0, reads = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, params) async {
          if (name == 'begin_my_routing_snapshot') {
            begins++;
            return {'ngo_id': 'ngo', 'snapshot_id': 'snapshot'};
          }
          if (name == 'get_my_authorized_route') return detail();
          throw StateError('Unexpected operation');
        },
        authorizationCapabilities: (_) async => {
          'ngo_id': 'ngo',
          'contract': 'geolock.routing-auto-now.v1',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        combinedPlanner: (_) async {
          plans++;
          throw TimeoutException('synthetic lost response');
        },
        authorizationReader: (body) async {
          reads++;
          expect(body, {'request_id': 'request', 'snapshot_id': 'snapshot'});
          return receipt();
        },
      );
      final recovered = await repo.generateAndAuthorize(
        ['vehicle'],
        'request',
        'policy',
      );
      final saved = await repo.routeOperation();
      expect(saved, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ngo_route_operation_history_ngo_request',
        ),
        isNotNull,
      );
      expect(recovered['kind'], 'DATABASE_AUTHORIZATION_RECEIPT');
      expect(begins, 1);
      expect(plans, 1);
      // One receipt read reconciles the uncertain combined response; a second
      // fresh receipt read authorizes local archival.
      expect(reads, 2);
    },
  );

  test(
    'NOT_FOUND remains uncertain; explicit resume preserves snapshot and request',
    () async {
      var begins = 0, plans = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (name, params) async {
          if (name == 'begin_my_routing_snapshot') {
            begins++;
            return {'ngo_id': 'ngo', 'snapshot_id': 'snapshot'};
          }
          if (name == 'get_my_authorized_route') return detail();
          throw StateError('Unexpected operation');
        },
        authorizationCapabilities: (_) async => {
          'ngo_id': 'ngo',
          'contract': 'geolock.routing-auto-now.v1',
          'automatic_departure': true,
          'combined_generation_enabled': true,
        },
        combinedPlanner: (body) async {
          plans++;
          expect(body['request_id'], 'request');
          expect(body['snapshot_id'], 'snapshot');
          if (plans == 1) throw TimeoutException('synthetic');
          return receipt();
        },
        authorizationReader: (_) async => {
          'kind': 'AUTHORIZATION_UNCONFIRMED',
          'ngo_id': 'ngo',
          'snapshot_id': 'snapshot',
          'request_id': 'request',
        },
      );
      await expectLater(
        repo.generateAndAuthorize(['vehicle'], 'request', 'policy'),
        throwsA(isA<TimeoutException>()),
      );
      await repo.reconcileRouteOperation();
      expect(plans, 1);
      expect((await repo.routeOperation())['status'], 'authorization_unknown');
      await repo.resumeRouteOperation();
      expect(plans, 2);
      expect(begins, 1);
    },
  );

  test('missing database contract stops before snapshot creation', () async {
    var calls = 0;
    final repo = NgoRoutingRepository(
      identity: () => 'ngo',
      rpc: (_, _) async {
        calls++;
        return {};
      },
      authorizationCapabilities: (_) async => {
        'ngo_id': 'ngo',
        'contract': 'old',
        'automatic_departure': false,
      },
      combinedPlanner: (_) async {
        calls++;
        return {};
      },
      authorizationReader: (_) async => {},
    );
    await expectLater(
      repo.generateAndAuthorize(['vehicle'], 'request', 'policy'),
      throwsStateError,
    );
    expect(calls, 0);
  });

  for (final fail in [false, true]) {
    testWidgets(
      'route button loading covers generation and authorization; failure=$fail',
      (tester) async {
        final writes = <String>[];
        final generation = Completer<void>();
        final authorization = Completer<void>();
        var submissions = 0;
        final repo = NgoRoutingRepository(
          identity: () => 'ngo',
          rpc: (name, params) async {
            if (name == 'list_my_vehicles') {
              return {
                'vehicles': [
                  {
                    'vehicle_id': 'vehicle',
                    'ngo_user_id': 'ngo',
                    'vehicle_label': 'V2',
                    'payload_capacity_kg': 500,
                    'eligible_for_planning': true,
                  },
                ],
              };
            }
            if (name == 'get_my_routing_overview') {
              return {
                'ngo_id': 'ngo',
                'contract': 'geolock.ngo-routing.v1',
                'policy_id': 'policy',
                'authorization_enforced': true,
                'eligible_tasks': [
                  {'task_id': 'task', 'title': 'Pickup'},
                ],
                'routes': [],
              };
            }
            if (name == 'begin_my_routing_snapshot') {
              writes.add(name);
              return {'ngo_id': 'ngo', 'snapshot_id': 'snapshot'};
            }
            if (name == 'get_my_authorized_route') {
              await authorization.future;
              return detail();
            }
            throw StateError('No pickup writes allowed');
          },
          authorizationCapabilities: (_) async => {
            'ngo_id': 'ngo',
            'contract': 'geolock.routing-auto-now.v1',
            'automatic_departure': true,
            'combined_generation_enabled': true,
          },
          combinedPlanner: (body) async {
            submissions++;
            await generation.future;
            return {...receipt(), 'request_id': await repoOperationRequest()};
          },
          authorizationReader: (body) async => {
            ...receipt(),
            if (fail) 'kind': 'AUTHORIZATION_UNCONFIRMED',
            'request_id': body['request_id'],
            'snapshot_id': body['snapshot_id'],
          },
        );
        // The response request ID is read from the same persisted synthetic operation.
        await tester.pumpWidget(
          MaterialApp(
            home: NgoRoutesPage(
              repository: repo,
              mapBuilder: (markers) => Text('Map markers: ${markers.length}'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('generate-route')));
        final button = find.byKey(const Key('generate-route'));
        await tester.tap(button);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.descendant(
            of: button,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expect(find.text('Generating route…'), findsOneWidget);
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.tap(button);
        await tester.pump();
        expect(submissions, 1);
        if (fail) {
          generation.completeError(TimeoutException('synthetic failure'));
          await tester.pumpAndSettle();
          expect(find.text('Generating route…'), findsNothing);
          expect(find.text('Generate & Authorize Route'), findsOneWidget);
          expect(find.byKey(const Key('routing-error')), findsOneWidget);
          expect(submissions, 1);
          await tester.pumpWidget(const SizedBox());
          return;
        }
        generation.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Generating route…'), findsOneWidget);
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        authorization.complete();
        await tester.pumpAndSettle();
        expect(find.text('Database authorization confirmed'), findsOneWidget);
        expect(find.text('Map markers: 2'), findsOneWidget);
        expect(find.text('Choose departure time'), findsNothing);
        expect(find.text('Request database authorization'), findsNothing);
        expect(writes, ['begin_my_routing_snapshot']);
        expect(await repo.routeOperation(), isEmpty);
        expect(
          (await SharedPreferences.getInstance()).getKeys().any(
            (key) => key.startsWith('ngo_route_operation_history_ngo_'),
          ),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

Future<String> repoOperationRequest() async {
  final prefs = await SharedPreferences.getInstance();
  return (jsonDecode(prefs.getString('ngo_route_operation_ngo')!)
          as Map)['request_id']
      as String;
}
