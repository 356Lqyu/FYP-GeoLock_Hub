/// Presentation only. Protected RPC flags remain the source of action authority.
String? routingFailureMessage(String? code) => switch (code) {
  'DATABASE_REJECTED_REQUEST' || 'UPSTREAM_REJECTED_REQUEST' =>
    'The protected routing request was rejected. Preserve it and review its outcome before trying again.',
  'VALIDATOR_REJECTED_CANDIDATE' =>
    'Independent validation rejected this route. It was not automatically authorized.',
  'AUTHENTICATION_REQUIRED' || 'AUTHENTICATION_OR_PERMISSION_DENIED' =>
    'Your NGO session could not authorize this request. Sign in again without discarding the saved request.',
  'STALE_OR_EXPIRED_LEASE' || 'LEASE_EXPIRED' || 'LEASE_EXPIRES' =>
    'This claim has expired. Pickup is blocked; recovery or reconciliation may be required.',
  'LEASE_TOO_SHORT' || 'REMAINING_ROUTE_INFEASIBLE' =>
    'There is not enough claim time for the remaining route and safety margin. Refresh and review the affected claims.',
  'CAPACITY_VIOLATION' || 'CAPACITY' =>
    'The assigned donation load exceeds vehicle capacity. Review the selected vehicle and unserved pickups.',
  'NO_PICKUP_TASKS' || 'NO_FEASIBLE_PLAN' || 'INFEASIBLE' =>
    'No feasible pickup route was found for the eligible claims and selected vehicles.',
  'SNAPSHOT_STALE' ||
  'PLAN_STALE_TASK' ||
  'PLAN_STALE_NGO' ||
  'PLAN_STALE_VEHICLE' ||
  'UNAUTHORIZED_TASK' =>
    'The claim, donation or vehicle changed. Refresh; review the saved request before trying again.',
  'DISPATCH_WINDOW_OR_LEASE_EXPIRED' =>
    'Pickup is blocked because a claim or pickup window has expired. Recovery or reconciliation may be required.',
  'RESERVED_TASK_REQUIRES_RECONCILIATION' ||
  'STARTED_ROUTE_REQUIRES_RECONCILIATION' ||
  'RECONCILIATION_REQUIRED' =>
    'This pickup requires reconciliation. Keep the existing route and contact the coordinator.',
  'VALIDATED_FEASIBLE_PLAN_REQUIRED' ||
  'AUTHORIZATION_RECEIPT_CONFLICT' ||
  'REQUEST_CONFLICT' =>
    'Route authorization was not confirmed. Preserve the saved request and check its outcome.',
  'COMBINED_WORKFLOW_DISABLED' =>
    'Automatic route authorization is not enabled by the coordinator. No new planning request was sent.',
  'AUTOMATIC_AUTHORIZATION_CONTRACT_UNAVAILABLE' =>
    'Automatic route authorization is unavailable. Review the saved request with the coordinator.',
  'PICKUP_NOT_STARTED' ||
  'PREVIOUS_PICKUP_UNRESOLVED' ||
  'STOP_ORDER_REQUIRED' =>
    'Pickup is blocked. Start and complete each stop in the authorized order.',
  _ => null,
};

String claimLeaseMessage(Map<String, dynamic> claim, {required bool eligible}) {
  if (claim['claim_status'] == 'COMPLETED' ||
      claim['lease_status'] == 'COMPLETED') {
    return 'Claim completed. Collected goods are not available for a new pickup.';
  }
  if (claim['claim_status'] == 'RECONCILIATION_REQUIRED' ||
      claim['lease_status'] == 'RECONCILIATION_REQUIRED') {
    return 'Reconciliation required. Contact the coordinator; do not start another route.';
  }
  final serverNow = DateTime.tryParse('${claim['server_now'] ?? ''}');
  final expiry = DateTime.tryParse('${claim['lease_expires_at'] ?? ''}');
  final remaining = serverNow != null && expiry != null
      ? expiry.difference(serverNow)
      : null;
  if (claim['lease_is_expired'] == true ||
      (remaining != null && remaining <= Duration.zero)) {
    return claim['lease_recovery_pending'] == true
        ? 'Claim expired — recovery pending. Pickup is blocked.'
        : 'Claim expired. Review its recovery or reconciliation status.';
  }
  final time = remaining == null
      ? 'Lease time unavailable; refresh to verify.'
      : 'Lease remaining at last refresh: ${remaining.inMinutes} min ${remaining.inSeconds % 60} sec.';
  final status =
      claim['task_status'] == 'DISPATCHED' || claim['task_status'] == 'PLANNED'
      ? 'Already assigned to a route.'
      : eligible
      ? 'Eligible for routing.'
      : 'Not eligible for a new route under current backend checks.';
  return '$status $time';
}

String routeOperationMessage(Map<String, dynamic> operation) {
  if (operation['status'] == 'authorized') {
    return 'A route is already authorized. Open your pickup route below.';
  }
  if (operation['status'] == 'infeasible') {
    return 'No feasible route was found. Review unserved pickups in troubleshooting.';
  }
  if (operation['phase'] == 'preflight' && operation['status'] == 'blocked') {
    return 'Route generation stopped during its initial checks. Review the saved request before trying again.';
  }
  return 'A previous route request needs review. Check its outcome before starting another request.';
}
