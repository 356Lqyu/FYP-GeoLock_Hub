/// Immutable policy UUID from the reviewed DEV installation evidence. The
/// deployed overview exports its ID, not its body; never assume this for others.
const reviewedPilotPolicyId = '80db858b-93e8-4a0a-94e2-dbe14940f0a1';

int? reviewedPolicyHorizon(Object? policyId) =>
    policyId == reviewedPilotPolicyId ? 240 : null;

String? vehicleHorizonWarning(Map<String, dynamic> vehicle, Object? policyId) {
  final horizon = reviewedPolicyHorizon(policyId);
  final duration = num.tryParse('${vehicle['max_route_duration_min']}');
  if (horizon == null || duration == null || duration <= horizon) return null;
  return '${vehicle['vehicle_label'] ?? 'Vehicle'}: maximum route duration '
      '$duration min exceeds the approved policy horizon of $horizon min. '
      'Update the vehicle before generating a route.';
}
