import 'package:flutter/material.dart';
import 'ngo_routing_repository.dart';
import 'route_display_formatters.dart';
import 'routing_page_support.dart' show routeNumber;

/// Only explicit protected states qualify; expiry alone proves no custody fact.
bool routeNeedsReconciliation(
  Map<String, dynamic>? detail,
  List<Map<String, dynamic>> claims,
) {
  if (detail == null) return false;
  final ids = routingRows(
    detail['stops'] ?? [],
  ).map((s) => s['claim_id']).whereType<String>().toSet();
  return claims.any(
    (c) =>
        ids.contains(c['claim_id']) &&
        (c['claim_status'] == 'RECONCILIATION_REQUIRED' ||
            c['lease_status'] == 'RECONCILIATION_REQUIRED'),
  );
}

/// Display reads only. At most three RPCs are in flight; failed reads grant nothing.
Future<Map<String, Map<String, dynamic>>> loadRouteCardDetails(
  List<Map<String, dynamic>> routes,
  Future<Map<String, dynamic>> Function(String) read,
) async {
  final ids = routes
      .map((r) => r['route_id'])
      .whereType<String>()
      .toSet()
      .toList();
  final results = <String, Map<String, dynamic>>{};
  var next = 0;
  Future<void> worker() async {
    while (next < ids.length) {
      final id = ids[next++];
      try {
        results[id] = await read(id);
      } catch (_) {
        // Leave absent; the overview remains visible with an unavailable label.
      }
    }
  }

  await Future.wait(List.generate(ids.length.clamp(0, 3), (_) => worker()));
  return results;
}

/// Wording requires explicit server evidence, never timestamps or can_close alone.
String? routeNoCollectionSummary(Map<String, dynamic>? detail) {
  if (detail?['route_status'] == 'ABANDONED' &&
      detail?['closure_kind'] == 'NO_COLLECTION') {
    return 'Route closed — no goods collected';
  }
  if (detail?['route_status'] == 'CANCELLED' &&
      detail?['cancellation_outcome'] == 'NO_COLLECTION') {
    return 'Route cancelled — no pickups completed';
  }
  if (detail?['no_collection_cancellation_eligible'] == true) {
    return 'No active pickups remain';
  }
  return null;
}

String routeCardReadiness(Map<String, dynamic>? detail, {required bool fresh}) {
  if (detail == null) {
    return 'Pickup readiness unavailable. Open or refresh the route.';
  }
  if (!fresh) return 'Refresh to confirm pickup readiness.';
  final noCollection = routeNoCollectionSummary(detail);
  if (noCollection != null) return noCollection;
  final status = detail['route_status'];
  if (status == 'COMPLETED') return 'Route completed';
  if (status == 'CANCELLED') return 'Route cancelled';
  if (status == 'ABANDONED') {
    return 'Route abandoned; custody and reservations reconciled.';
  }
  if (detail['authorization_confirmed'] != true) {
    return 'Route authority not confirmed. Open route details.';
  }
  final stops = routingRows(detail['stops'] ?? []);
  if (stops.any((s) => s['can_start'] == true)) return 'Ready to start pickup';
  if (stops.any((s) => s['can_complete'] == true)) return 'Pickup in progress';
  if (detail['can_close'] == true) {
    if (detail['closure_kind'] == 'NO_COLLECTION') {
      return 'No goods collected — confirm vehicle return and close route';
    }
    return detail['closure_outcome'] == 'ABANDONED'
        ? 'Pickups resolved. Confirm return to depot.'
        : 'Ready for route closure. Confirm return to depot.';
  }
  return routingDispatchMessage(detail['dispatch_block_reason']);
}

class PickupRouteCard extends StatelessWidget {
  const PickupRouteCard({
    super.key,
    required this.overview,
    this.detail,
    required this.fresh,
    required this.onTap,
    this.reconciliationRequired = false,
    this.reconciliationVerified = true,
  });
  final Map<String, dynamic> overview;
  final Map<String, dynamic>? detail;
  final bool fresh;
  final VoidCallback onTap;
  final bool reconciliationRequired;
  final bool reconciliationVerified;
  @override
  Widget build(BuildContext context) {
    final row = detail ?? overview;
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text(
              '${detail?['vehicle_label'] ?? 'Assigned vehicle'} · ${row['route_status'] ?? 'Status unavailable'}',
            ),
            subtitle: Text(
              [
                '${detail?['pickup_count'] ?? '—'} pickups · ${routeLoadText(detail?['total_load_kg'])} kg · ${routeNumber(row['total_distance_km'])} km · ${routeNumber(row['total_duration_min'])} min',
                detail == null
                    ? 'Route details unavailable; refresh to verify pickup start.'
                    : !detail!.containsKey('actual_started_at')
                    ? 'Actual pickup start: unavailable'
                    : 'Actual pickup start: ${routeMytTime(detail!['actual_started_at'], missing: detail!['actual_started_at'] == null ? 'Not started' : 'Time unavailable')}',
                reconciliationRequired
                    ? 'Action required · Reconciliation required'
                    : routeCardReadiness(detail, fresh: fresh),
                if (!reconciliationVerified)
                  'Reconciliation status unavailable; refresh to verify.',
              ].join('\n'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: onTap,
          ),
        ],
      ),
    );
  }
}
