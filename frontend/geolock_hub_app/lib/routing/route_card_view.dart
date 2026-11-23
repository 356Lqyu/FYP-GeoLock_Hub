import 'package:flutter/material.dart';
import '../ui/geolock_role_style.dart';
import 'ngo_routing_repository.dart';
import 'reconciliation_status.dart';
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
    final status = row['route_status'];
    final statusLabel = switch (status) {
      'DRAFT' => 'Draft',
      'VALIDATED' => 'Validated',
      'STALE' => 'Stale',
      _ => routeStatusLabel(status),
    };
    final needsClosure =
        fresh &&
        detail?['authorization_confirmed'] == true &&
        detail?['can_close'] == true &&
        const {'AUTHORISED', 'IN_PROGRESS'}.contains(status);
    final badge = reconciliationRequired
        ? GeoLockStatusText.reconciliationRequired
        : needsClosure
        ? GeoLockStatusText.actionRequired
        : statusLabel;
    final tone = reconciliationRequired || needsClosure
        ? GeoTone.warning
        : switch (status) {
            'IN_PROGRESS' || 'AUTHORISED' => GeoTone.info,
            'COMPLETED' => GeoTone.success,
            _ => GeoTone.neutral,
          };
    final actualStart = detail?['actual_started_at'];
    final facts = {
      'Pickups': '${detail?['pickup_count'] ?? '—'}',
      'Total weight': '${routeLoadText(detail?['total_load_kg'])} kg',
      'Distance': '${routeNumber(row['total_distance_km'])} km',
      'Estimated duration': '${routeNumber(row['total_duration_min'])} min',
    };
    Widget fact(String title, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelSmall),
        Text(value),
      ],
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${detail?['vehicle_label'] ?? 'Assigned vehicle'}',
                            style: geoTitleStyle(context),
                          ),
                          if (reconciliationRequired || needsClosure)
                            Text(
                              statusLabel,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * .58,
                      ),
                      child: GeoStatusChip(badge, tone: tone),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    for (final entry in facts.entries)
                      SizedBox(
                        width: (constraints.maxWidth - 12) / 2,
                        child: fact(entry.key, entry.value),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                fact(
                  'Actual pickup start',
                  detail?.containsKey('actual_started_at') != true
                      ? 'Unavailable'
                      : routeMytTime(
                          actualStart,
                          missing: actualStart == null
                              ? 'Not started'
                              : 'Time unavailable',
                        ),
                ),
                const Divider(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (detail == null)
                            const Text(
                              'Route details unavailable; refresh to verify pickup start.',
                            ),
                          if (reconciliationRequired)
                            const Text(
                              'Open route details to review the affected pickup.',
                            )
                          else
                            Text(routeCardReadiness(detail, fresh: fresh)),
                          if (!reconciliationVerified)
                            const Text(
                              'Reconciliation status unavailable; refresh to verify.',
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right, color: GeoTone.neutral),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
