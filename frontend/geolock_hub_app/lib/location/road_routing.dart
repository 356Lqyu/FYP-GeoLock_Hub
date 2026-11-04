import 'package:supabase_flutter/supabase_flutter.dart';

/// Whether a picked location must be reachable from the road network.
///
/// The app only previews road access; the database snaps the stored location
/// to a road node itself and never accepts a node chosen by the client.
enum RoadAccessRequirement { none, required }

class RoadAccessResult {
  final bool routable;
  final double? snapDistanceM;
  final int maxSnapDistanceM;
  final String? reasonCode;

  const RoadAccessResult({
    required this.routable,
    this.snapDistanceM,
    this.maxSnapDistanceM = 500,
    this.reasonCode,
  });

  factory RoadAccessResult.fromJson(Map<String, dynamic> json) =>
      RoadAccessResult(
        routable: json['routable'] == true,
        snapDistanceM: (json['snap_distance_m'] as num?)?.toDouble(),
        maxSnapDistanceM: (json['max_snap_distance_m'] as num?)?.toInt() ?? 500,
        reasonCode: json['reason_code']?.toString(),
      );

  /// Short donor-facing summary, e.g. "35 m from a drivable road".
  String get summary => routable
      ? '${(snapDistanceM ?? 0).round()} m from a drivable road'
      : 'No drivable road within $maxSnapDistanceM m'
            '${reasonCode == null ? '' : ' ($reasonCode)'}';
}

typedef RoadAccessCheck =
    Future<RoadAccessResult> Function(double latitude, double longitude);

/// Default [RoadAccessCheck] backed by the preview_location_routing RPC.
Future<RoadAccessResult> previewLocationRouting(
  double latitude,
  double longitude,
) async {
  final response = await Supabase.instance.client.rpc(
    'preview_location_routing',
    params: {'p_latitude': latitude, 'p_longitude': longitude},
  );
  if (response is! Map) {
    throw const FormatException('Invalid road access response.');
  }
  return RoadAccessResult.fromJson(Map<String, dynamic>.from(response));
}

/// Explains listing_routing_status / road_node_status values from the server.
String routingStatusExplanation(String? status) => switch (status) {
  'READY' =>
    'Road route ready: verified NGOs within 20 km by road can claim it.',
  'NOT_ROUTABLE' =>
    'No drivable road was found within 500 m of the pickup point, so NGOs '
        'cannot claim this listing. Cancel it and choose a spot next to a road.',
  'PENDING_NODE' =>
    'The road network is not loaded on the server yet. The listing becomes '
        'claimable once the database assigns a road node.',
  null => 'No direct-pickup listing, so no road route is needed.',
  _ => 'Road status: $status',
};

/// Routing line for a listing; unlike [routingStatusExplanation], a missing
/// status here means the server did not report one.
String roadStatusLine(Object? status) => status == null
    ? 'Road status unknown'
    : routingStatusExplanation(status.toString());

/// Readable text for claim_listing / hub reservation reason codes. The raw
/// code stays in brackets for debugging.
String roadOutcomeMessage(String? code) {
  final text = switch (code) {
    'OUTSIDE_GEOFENCE' => 'More than 20 km from your NGO by road',
    'ROUTE_UNAVAILABLE' => 'No drivable road route connects these locations',
    'ELIGIBILITY_UNDETERMINED' =>
      'Road eligibility has not been calculated yet; try again shortly',
    'CLAIM_CONFLICT' => 'This listing is no longer available to claim',
    'LISTING_EXPIRED' => 'This listing has expired',
    'LISTING_NOT_FOUND' => 'This listing no longer exists or is not visible',
    'DONATION_NOT_READY' => 'The donation is not ready for pickup',
    'BATCH_NOT_PUBLISHED' => 'The hub batch has not been published yet',
    null => 'The server gave no reason',
    _ => 'Unexpected server reason',
  };
  return code == null ? text : '$text ($code)';
}
