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
    'A pickup on this route can no longer be collected before its claim deadline or pickup window. Remove it from the route, then continue.',
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
  'CANDIDATE_DEADLINE_PASSED' =>
    'A claim in this route no longer has enough time left for its pickup. Nothing was reserved; generate a new route.',
  'STOP_LEASE_INSUFFICIENT' =>
    'A pickup in this route would finish too close to its claim deadline. Nothing was reserved; generate a new route.',
  'STOP_STILL_FEASIBLE' =>
    'This pickup can still be collected in time, so it was not removed. Refresh the route.',
  'STOP_ALREADY_STARTED' =>
    'This pickup has already started, so it cannot be removed from the route.',
  'STOP_ALREADY_RELEASED' =>
    'This pickup is no longer on the route. Refresh to see its current state.',
  'STOP_CUSTODY_UNCERTAIN' || 'STOP_UNDER_RECONCILIATION' =>
    'This pickup needs reconciliation, so it cannot be removed here. Open its claim details.',
  'LEASE_EXPIRED_RECOVERY_REQUIRED' =>
    'This claim has expired. It will be released automatically by recovery; refresh shortly.',
  'DETACH_REQUIRES_PER_TASK_POLICY' =>
    'This older route cannot remove individual pickups. Follow the route or contact the coordinator.',
  'ROUTE_NOT_ACTIVE' || 'STOP_NOT_ON_ROUTE' =>
    'This route or pickup is no longer active. Refresh your routes.',
  'STOP_DETACH_OUTCOME_UNKNOWN' =>
    'Removing the pickup was not confirmed. Press Remove from route again: the same saved request is checked and nothing is removed twice.',
  'CANDIDATE_EXPIRED' =>
    'This generated route expired before it was started. Nothing was reserved; generate a new route.',
  'ONE_VEHICLE_ROUTE_REQUIRED' =>
    'Start Route supports one vehicle route. Select one vehicle and generate again.',
  'CANDIDATE_NOT_FOUND' || 'NOT_SNAPSHOT_OWNER' =>
    'This generated route is unavailable for your NGO. Generate a new route.',
  'ROUTE_START_NOT_CONFIRMED' =>
    'The route could not be started. Nothing was reserved or dispatched; refresh and try again.',
  'ROUTE_START_OUTCOME_UNKNOWN' =>
    'The route start was not confirmed. Press Start Route again: the same saved request is checked and never starts a second route.',
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

/// Phase 2: why a generated route must be started by its deadline.
String? deadlineReasonLabel(Object? reason) => switch (reason) {
  'LEASE' => 'Limited by a claim deadline in this route.',
  'SERVICE_WINDOW' => 'Limited by a donor pickup window in this route.',
  'HORIZON' => 'Limited by the 240-minute route limit.',
  _ => null,
};

String deadlineExpiredMessage(Object? reason) => switch (reason) {
  'LEASE' =>
    'A claim in this route no longer has enough time left. Generate a new route.',
  'SERVICE_WINDOW' =>
    'A donor pickup window in this route has closed. Generate a new route.',
  'HORIZON' =>
    'This route would no longer finish within the route limit. Generate a new route.',
  _ => 'This generated route expired. Generate a new route to continue.',
};

String stopInfeasibleMessage(Object? reason) => switch (reason) {
  'LEASE' =>
    'This pickup can no longer finish before its claim deadline (with the 15-minute margin). Remove it from the route to continue.',
  'SERVICE_WINDOW' =>
    "This pickup can no longer finish inside the donor's pickup window. Remove it from the route to continue.",
  'SOURCE_STALE' =>
    'This donation or claim changed after planning. Remove it from the route to continue.',
  _ => 'This pickup can no longer be collected as planned.',
};
