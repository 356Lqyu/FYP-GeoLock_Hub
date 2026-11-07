// Synthetic offline UI tests. No live planning, maps service or database access.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/routing/proposed_route_view.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';

Map<String, dynamic> stop(int n) => {
  'task_id': 't$n',
  'road_node_id': '${100 + n}',
  'location_id': 'location$n',
  'cumulative_load_kg': n == 1 ? 50 : 20,
};
Map<String, dynamic> candidate({
  String status = 'ATTESTED',
  String outcome = 'CANDIDATE_READY',
}) => {
  'kind': 'ADVISORY_CANDIDATE',
  'ngo_id': 'ngo',
  'snapshot_id': 'snapshot',
  'candidate_id': 'candidate',
  'dispatch_authority_issued': false,
  'validation_status': status,
  'outcome': outcome,
  'methods': [
    for (final method in [
      'fcfs',
      'nearest_neighbour',
      'distance_only',
      'proposed',
    ])
      {
        'method': method,
        'validation': {
          'valid': true,
          'metrics': {
            'total_travel_km': 12,
            'total_route_minutes': 45,
            'served_pickup_task_count': 2,
          },
        },
        'plan': {
          'method': method,
          'status': 'PARTIAL',
          'optimization_status': 'FEASIBLE_UNPROVEN',
          'dispatch_authority_issued': false,
          'unserved_tasks': ['t3'],
          'unserved_reasons': [
            ['t3', 'CAPACITY_LIMIT'],
          ],
          'routes': [
            for (var n = 1; n <= 2; n++)
              {
                'vehicle_id': 'v$n',
                'start_node_id': '100',
                'end_node_id': '100',
                'departure_us': 0,
                'return_us': n == 1 ? 1500000000 : 1200000000,
                'stops': [stop(n)],
              },
          ],
        },
      },
  ],
  'presentation': {
    'version': 'geolock.proposed-display.v1',
    'snapshot_id': 'snapshot',
    'geometry_status': 'UNAVAILABLE',
    'routes': [
      for (var n = 1; n <= 2; n++)
        {
          'vehicle_id': 'v$n',
          'vehicle_label': 'Pilot vehicle $n',
          'total_distance_km': n == 1 ? 7 : 5,
          'total_load_kg': n == 1 ? 50 : 20,
          'pickup_location_count': 1,
          'depot': {'road_node_id': '100', 'latitude': 3.0, 'longitude': 101.0},
          'stops': [
            {
              ...stop(n),
              'latitude': 3.0 + n / 100,
              'longitude': 101.0 + n / 100,
            },
          ],
        },
    ],
  },
};
List<Map<String, dynamic>> tasks() => [
  for (var n = 1; n <= 3; n++) {'task_id': 't$n', 'title': 'Donation $n'},
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'only Proposed cards show exact summaries and selectable numbered marker maps',
    (tester) async {
      Set<Marker> observed = {};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProposedRouteView(
                candidate: candidate(),
                fleet: const [],
                tasks: tasks(),
                descriptions: {
                  't1': {'pickup_address': 'Address 1'},
                  't2': {'pickup_address': 'Address 2'},
                },
                mapBuilder: (markers) {
                  observed = markers;
                  return const SizedBox(
                    height: 40,
                    child: Text('Offline marker map'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Proposed route'), findsOneWidget);
      for (final label in ['fcfs', 'nearest_neighbour', 'distance_only']) {
        expect(find.textContaining(label), findsNothing);
      }
      expect(find.text('Pilot vehicle 1'), findsOneWidget);
      expect(find.text('Distance: 7.00 km'), findsOneWidget);
      expect(
        find.textContaining('Estimated duration: 25.00 min'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Assigned load: 50.00 kg · 1 pickup tasks · 1 pickup locations',
        ),
        findsOneWidget,
      );
      expect(find.text('Donation 1'), findsOneWidget);
      expect(find.textContaining('Address 1'), findsOneWidget);
      expect(
        find.text('Route checks passed. This proposal is not yet authorized.'),
        findsOneWidget,
      );
      expect(find.textContaining('ATTESTED'), findsNothing);
      expect(find.text('Optimization: FEASIBLE_UNPROVEN'), findsOneWidget);
      expect(find.text('Served pickup tasks: 2'), findsOneWidget);
      expect(find.text('Donation 3: CAPACITY_LIMIT'), findsOneWidget);
      expect(observed.map((m) => m.markerId.value).toSet(), {
        'depot',
        'pickup-1',
      });
      expect(
        observed.singleWhere((m) => m.markerId.value == 'pickup-1').position,
        const LatLng(3.01, 101.01),
      );
      expect(
        observed
            .singleWhere((m) => m.markerId.value == 'pickup-1')
            .infoWindow
            .title,
        '1. Donation 1',
      );
      expect(
        find.textContaining('Road geometry unavailable'),
        findsNWidgets(2),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('select-route-map-1')),
      );
      await tester.tap(find.byKey(const ValueKey('select-route-map-1')));
      await tester.pumpAndSettle();
      expect(
        observed.singleWhere((m) => m.markerId.value == 'pickup-1').position,
        const LatLng(3.02, 101.02),
      );
      expect(find.byType(ProposedRouteMap), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('mismatched display snapshot cannot provide map coordinates', (
    tester,
  ) async {
    final result = candidate();
    (result['presentation'] as Map)['snapshot_id'] = 'other-snapshot';
    var maps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProposedRouteView(
              candidate: result,
              fleet: const [],
              tasks: tasks(),
              mapBuilder: (_) {
                maps++;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(maps, 0);
    expect(
      find.text('Map coordinates unavailable for this saved response.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'invalid coordinates are omitted, never replaced with zero or lines',
    () {
      expect(routingPoint({'latitude': double.nan, 'longitude': 101}), isNull);
      expect(routingPoint({'latitude': 91, 'longitude': 101}), isNull);
      expect(
        proposedMarkers({
          'depot': {},
          'stops': [
            {'latitude': null, 'longitude': null},
          ],
        }, {}),
        isEmpty,
      );
    },
  );

  test(
    'saved result display preserves IDs and never calls planning or database writes',
    () async {
      final saved = {
        'request_id': 'original-request',
        'snapshot_id': 'snapshot',
        'status': 'candidate_ready',
        'vehicle_ids': ['v1'],
        'policy_id': 'policy',
      };
      SharedPreferences.setMockInitialValues({
        'ngo_planning_request_ngo': jsonEncode(saved),
      });
      var reads = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (_, _) async => throw StateError('No database operation expected'),
        planner: (_) async => throw StateError('No planning expected'),
        savedPlanner: (body) async {
          reads++;
          expect(body, {
            'request_id': 'original-request',
            'snapshot_id': 'snapshot',
          });
          return {...candidate(), 'saved_result_display_only': true};
        },
      );
      final result = await repo.readSavedPlanning();
      expect(result['candidate_id'], 'candidate');
      expect(reads, 1);
      expect(await repo.pendingPlanning(), saved);
    },
  );

  test(
    'uncertain request is never turned into a new or saved-result request',
    () async {
      SharedPreferences.setMockInitialValues({
        'ngo_planning_request_ngo': jsonEncode({
          'request_id': 'original-request',
          'snapshot_id': 'snapshot',
          'status': 'pending',
        }),
      });
      var calls = 0;
      final repo = NgoRoutingRepository(
        identity: () => 'ngo',
        rpc: (_, _) async {
          calls++;
          return {};
        },
        savedPlanner: (_) async {
          calls++;
          return {};
        },
        planner: (_) async {
          calls++;
          return {};
        },
      );
      await expectLater(repo.readSavedPlanning(), throwsStateError);
      expect(calls, 0);
    },
  );
}
