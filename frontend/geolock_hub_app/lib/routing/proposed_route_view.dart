import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'ngo_routing_repository.dart';
import 'route_display_formatters.dart';

typedef RoutingMapBuilder = Widget Function(Set<Marker> markers);

LatLng? routingPoint(Map<String, dynamic> value) {
  final lat = value['latitude'], lon = value['longitude'];
  if (lat is! num ||
      lon is! num ||
      !lat.isFinite ||
      !lon.isFinite ||
      lat.abs() > 90 ||
      lon.abs() > 180) {
    return null;
  }
  return LatLng(lat.toDouble(), lon.toDouble());
}

Set<Marker> proposedMarkers(
  Map<String, dynamic> route,
  Map<int, BitmapDescriptor> icons,
) {
  final result = <Marker>{};
  final depot = routingPoint(routingObject(route['depot'] ?? {}));
  if (depot != null) {
    result.add(
      Marker(
        markerId: const MarkerId('depot'),
        position: depot,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: const InfoWindow(title: 'NGO depot — start and return'),
      ),
    );
  }
  for (final (i, stop) in routingRows(route['stops'] ?? []).indexed) {
    final point = routingPoint(stop);
    if (point == null) continue;
    result.add(
      Marker(
        markerId: MarkerId('pickup-${i + 1}'),
        position: point,
        icon: icons[i + 1] ?? BitmapDescriptor.defaultMarker,
        infoWindow: InfoWindow(
          title: '${i + 1}. ${stop['display_name'] ?? stop['task_id']}',
          snippet: routeDisplayAddress(stop['display_address']),
        ),
      ),
    );
  }
  return result;
}

/// Markers only. No Directions request, route polyline or substituted costs.
class ProposedRouteMap extends StatefulWidget {
  const ProposedRouteMap({super.key, required this.route, this.mapBuilder});
  final Map<String, dynamic> route;
  final RoutingMapBuilder? mapBuilder;
  @override
  State<ProposedRouteMap> createState() => _ProposedRouteMapState();
}

class _ProposedRouteMapState extends State<ProposedRouteMap> {
  final Map<int, BitmapDescriptor> _icons = {};
  @override
  void initState() {
    super.initState();
    if (widget.mapBuilder == null &&
        proposedMarkers(widget.route, {}).isNotEmpty) {
      _numberIcons();
    }
  }

  Future<void> _numberIcons() async {
    final count = routingRows(widget.route['stops'] ?? []).length;
    for (var number = 1; number <= count; number++) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawCircle(
        const Offset(32, 32),
        29,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        const Offset(32, 32),
        25,
        Paint()..color = Colors.deepOrange,
      );
      final text = TextPainter(
        text: TextSpan(
          text: '$number',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 25,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(32 - text.width / 2, 32 - text.height / 2));
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 64);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      if (!mounted) return;
      if (bytes != null) {
        setState(
          () => _icons[number] = BitmapDescriptor.bytes(
            bytes.buffer.asUint8List(),
            width: 40,
            height: 40,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final markers = proposedMarkers(widget.route, _icons);
    if (markers.isEmpty) {
      return const Text('Map coordinates unavailable for this saved response.');
    }
    if (widget.mapBuilder != null) return widget.mapBuilder!(markers);
    return SizedBox(
      height: 280,
      child: GoogleMap(
        initialCameraPosition: CameraPosition(
          target: markers.first.position,
          zoom: 13,
        ),
        markers: markers,
        polylines: const <Polyline>{},
        myLocationEnabled: false,
        myLocationButtonEnabled: false,
        mapToolbarEnabled: false,
        zoomControlsEnabled: true,
        onMapCreated: (controller) {
          final points = markers.map((m) => m.position).toList();
          if (points.length < 2) return;
          final lats = points.map((p) => p.latitude).toList()..sort();
          final lons = points.map((p) => p.longitude).toList()..sort();
          if (lats.first == lats.last && lons.first == lons.last) return;
          controller.animateCamera(
            CameraUpdate.newLatLngBounds(
              LatLngBounds(
                southwest: LatLng(lats.first, lons.first),
                northeast: LatLng(lats.last, lons.last),
              ),
              48,
            ),
          );
        },
      ),
    );
  }
}

class ProposedRouteView extends StatefulWidget {
  const ProposedRouteView({
    super.key,
    required this.candidate,
    required this.fleet,
    required this.tasks,
    this.descriptions = const {},
    this.mapBuilder,
  });
  final Map<String, dynamic> candidate;
  final List<Map<String, dynamic>> fleet, tasks;
  final Map<String, Map<String, dynamic>> descriptions;
  final RoutingMapBuilder? mapBuilder;
  @override
  State<ProposedRouteView> createState() => _ProposedRouteViewState();
}

class _ProposedRouteViewState extends State<ProposedRouteView> {
  int _selectedMap = 0;
  String value(Object? v) => v is num ? v.toStringAsFixed(2) : 'Unavailable';

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    final proposed = routingRows(
      candidate['methods'],
    ).where((m) => m['method'] == 'proposed').firstOrNull;
    if (proposed == null) {
      return const Text(
        'Proposed result unavailable. No authorization permitted.',
      );
    }
    final plan = routingObject(proposed['plan']);
    final metrics = routingObject(
      routingObject(proposed['validation'])['metrics'],
    );
    final routes = routingRows(plan['routes']);
    final names = {for (final t in widget.tasks) t['task_id']: t};
    final presentation = routingObject(candidate['presentation'] ?? {});
    final bound =
        presentation['version'] == 'geolock.proposed-display.v1' &&
        candidate['snapshot_id'] is String &&
        presentation['snapshot_id'] == candidate['snapshot_id'];
    final displayRoutes = bound
        ? routingRows(presentation['routes'] ?? [])
        : <Map<String, dynamic>>[];
    final reasons = {
      for (final pair in (plan['unserved_reasons'] as List? ?? []))
        if (pair is List && pair.length == 2) pair[0]: pair[1],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Proposed route',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const Text('Advisory candidate — NOT database-authorized'),
        if (candidate['saved_result_display_only'] == true)
          const Text(
            'Saved advisory result. Current eligibility and departure must be rechecked by database authorization.',
          ),
        Text(
          'Outcome: ${candidate['outcome'] ?? plan['status']} · ${plan['status'] ?? 'Result received'}',
        ),
        Text('Optimization: ${plan['optimization_status'] ?? 'NOT_REPORTED'}'),
        Text(
          'Served pickup tasks: ${metrics['served_pickup_task_count'] ?? metrics['served_count'] ?? '—'}',
        ),
        Text(
          candidate['validation_status'] == 'ATTESTED'
              ? 'Route checks passed. This proposal is not yet authorized.'
              : 'Route checks are not confirmed. This proposal cannot authorize pickups.',
        ),
        Text(
          'Total distance: ${value(metrics['total_travel_km'])} km · estimated duration: ${value(metrics['total_route_minutes'])} min',
        ),
        const Text(
          'Estimated duration includes driving, service, waiting and return to depot; modeled travel times, not live traffic.',
        ),
        if (plan['timeout'] == true)
          const Text(
            'Solver time limit reached; a validated incumbent is not proof of global optimality.',
          ),
        if (candidate['outcome'] == 'INFEASIBLE')
          const Text('No feasible Proposed route. No route was authorized.'),
        Text(
          'Unserved pickup tasks: ${(plan['unserved_tasks'] as List? ?? []).length}',
        ),
        for (final id in (plan['unserved_tasks'] as List? ?? []))
          Text(
            '${names[id]?['title'] ?? id}: ${reasons[id] ?? 'Reason unavailable'}',
          ),
        for (final (index, route) in routes.indexed)
          Builder(
            builder: (context) {
              final stops = routingRows(route['stops']);
              var display = displayRoutes
                  .where((r) => r['vehicle_id'] == route['vehicle_id'])
                  .firstOrNull;
              // Presentation metadata is useful only for the exact ordered plan stops.
              if (display != null) {
                final ds = routingRows(display['stops']);
                if (ds.length != stops.length ||
                    List.generate(
                      stops.length,
                      (i) =>
                          ds[i]['task_id'] == stops[i]['task_id'] &&
                          ds[i]['road_node_id'].toString() ==
                              stops[i]['road_node_id'].toString(),
                    ).contains(false)) {
                  display = null;
                }
              }
              final vehicle = widget.fleet
                  .where((v) => v['vehicle_id'] == route['vehicle_id'])
                  .firstOrNull;
              final totalLoad =
                  display?['total_load_kg'] ??
                  (stops.isEmpty ? 0 : stops.last['cumulative_load_kg']);
              final minutes =
                  ((route['return_us'] as num) -
                      (route['departure_us'] as num? ?? 0)) /
                  60000000;
              final mapStops = <Map<String, dynamic>>[];
              final displayStops = routingRows(display?['stops'] ?? []);
              for (final (i, stop) in stops.indexed) {
                final details = widget.descriptions[stop['task_id']] ?? {};
                mapStops.add({
                  ...stop,
                  if (i < displayStops.length) ...displayStops[i],
                  'display_name':
                      names[stop['task_id']]?['title'] ??
                      details['title'] ??
                      'Pickup ${stop['task_id']}',
                  'display_address': routeDisplayAddress(
                    details['pickup_address'],
                  ),
                });
              }
              final mapRoute = {...?display, 'stops': mapStops};
              return Card(
                key: ValueKey('proposed-route-$index'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${display?['vehicle_label'] ?? vehicle?['vehicle_label'] ?? route['vehicle_id']}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Distance: ${value(display?['total_distance_km'] ?? (routes.length == 1 ? metrics['total_travel_km'] : null))} km',
                      ),
                      Text(
                        'Estimated duration: ${value(minutes)} min — includes service, waiting and return',
                      ),
                      Text(
                        'Assigned load: ${value(totalLoad)} kg · ${stops.length} pickup tasks · ${display?['pickup_location_count'] ?? stops.map((s) => s['location_id'] ?? s['road_node_id']).toSet().length} pickup locations',
                      ),
                      for (final (i, stop) in mapStops.indexed)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(child: Text('${i + 1}')),
                          title: Text('${stop['display_name']}'),
                          subtitle: Text(
                            '${stop['display_address']}\nRoad node ${stop['road_node_id']}',
                          ),
                        ),
                      Text('Return to NGO depot ${route['end_node_id']}'),
                      const Text(
                        'Road geometry unavailable — markers only. No road route polyline is shown.',
                      ),
                      OutlinedButton(
                        key: ValueKey('select-route-map-$index'),
                        onPressed: () => setState(() => _selectedMap = index),
                        child: Text(
                          _selectedMap == index
                              ? 'Map selected'
                              : 'Show this vehicle’s map',
                        ),
                      ),
                      if (_selectedMap == index)
                        ProposedRouteMap(
                          key: ValueKey(
                            '${candidate['snapshot_id']}-${route['vehicle_id']}',
                          ),
                          route: mapRoute,
                          mapBuilder: widget.mapBuilder,
                        ),
                      if (display == null)
                        const Text(
                          'Detailed snapshot map data is unavailable in this older response. No route geometry was inferred.',
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
