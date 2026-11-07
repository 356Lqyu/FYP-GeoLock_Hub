// Contract replay of payloads captured from REAL local PostgreSQL/HTTP execution.
// The transport here is a replay double; this is not a live Flutter/Supabase test.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';

void main() {
  const capturePath = String.fromEnvironment('GEOLOCK_LOCAL_ROUTING_CAPTURE');
  test(
    'real local backend responses satisfy the Flutter post-claim lifecycle',
    () async {
      SharedPreferences.setMockInitialValues({});
      final capture = routingObject(
        jsonDecode(File(capturePath).readAsStringSync()),
      );
      final owner = capture['ngo_id'] as String;
      final route = capture['route_id'] as String;
      final snapshot = routingObject(capture['snapshot']);
      final planning = routingObject(capture['planning']);
      final claim = routingObject(capture['claim']);
      final vehicle = routingObject(capture['vehicle']);
      var phase = 'ready_detail';
      final writes = <String>[];
      final repository = NgoRoutingRepository(
        identity: () => owner,
        planner: (body) async {
          expect(body, {
            'request_id': snapshot['request_id'],
            'snapshot_id': snapshot['snapshot_id'],
          });
          return planning;
        },
        rpc: (name, params) async {
          switch (name) {
            case 'begin_my_routing_snapshot':
              expect(params['p_policy'], capture['policy_id']);
              expect(params['p_vehicle_ids'], [vehicle['vehicle_id']]);
              return snapshot;
            case 'authorize_my_routing_candidate':
              expect(params['p_candidate'], planning['candidate_id']);
              expect(params['p_request'], isNotEmpty);
              writes.add(name);
              return capture['authorization'];
            case 'get_my_authorized_route':
              expect(params['p_route'], route);
              return capture[phase];
            case 'start_pickup':
              expect(params, {'p_claim': claim['claim_id']});
              writes.add(name);
              phase = 'started_detail';
              return null;
            case 'complete_pickup':
              expect(params, {
                'p_claim': claim['claim_id'],
                'p_handover_confirmed': true,
              });
              writes.add(name);
              phase = 'collected_detail';
              return null;
            case 'close_my_collected_route':
              expect(params, {
                'p_route': route,
                'p_depot_return_confirmed': true,
              });
              writes.add(name);
              phase = 'closed_detail';
              return null;
            default:
              fail('Unexpected repository operation: $name');
          }
        },
      );
      expect(claim['outcome'], 'SUCCESS');
      final candidate = await repository.plan(
        [vehicle['vehicle_id'] as String],
        snapshot['request_id'] as String,
        capture['policy_id'] as String,
      );
      expect(candidate['validation_status'], 'ATTESTED');
      expect(candidate['dispatch_authority_issued'], isFalse);
      final ids = await repository.authorize(
        candidate['candidate_id'] as String,
        DateTime.parse(capture['departure_at'] as String),
      );
      expect(ids, [route]);
      final detail = await repository.detail(route);
      final task = routingRows(detail['stops']).single['task_id'] as String;
      await repository.pickup(route, task, complete: false);
      await repository.pickup(route, task, complete: true);
      await repository.close(route);
      expect((await repository.detail(route))['route_status'], 'COMPLETED');
      expect(writes, [
        'authorize_my_routing_candidate',
        'start_pickup',
        'complete_pickup',
        'close_my_collected_route',
      ]);
      final state = routingObject(capture['final_state']);
      expect(state['task'], 'COLLECTED');
      expect(state['claim'], 'COMPLETED');
      expect(state['lease'], 'COMPLETED');
      expect(state['assignments'], 0);
      expect(state['vehicle_hold'], isFalse);
    },
    skip: capturePath.isEmpty
        ? 'Provide a real successful local capture with --dart-define=GEOLOCK_LOCAL_ROUTING_CAPTURE=...'
        : false,
  );
}
