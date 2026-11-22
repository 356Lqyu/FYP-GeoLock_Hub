/// Shared, presentation-only status wording for NGO My Claims, Donor My
/// Donations, Route Detail and the claim coordination panel.
///
/// Every label is derived from fields returned by protected Supabase reads
/// (route detail, claim cards and `get_my_claim_coordination` v2). Nothing in
/// this file authorizes, releases, skips or resolves anything: action
/// permission always comes from the backend `can_*` flags.
library;

/// Consistent wording used across screens.
class GeoLockStatusText {
  GeoLockStatusText._();
  static const actionRequired = 'Action required';
  static const awaitingCounterpart = 'Awaiting counterpart';
  static const underReview = 'Under review';
  static const resolvedCollected = 'Resolved — collected';
  static const resolvedReleased = 'Resolved — released';
  static const expiredAwaitingRecovery = 'Expired, awaiting recovery';
  static const expiredReleased = 'Expired — safely released';
  static const reconciliationRequired = 'Reconciliation required';
}

/// Who answers the reconciliation case opposite the signed-in viewer.
///
/// For a `HUB_BATCH` pickup the counterpart is the hub administrator, never an
/// individual donor (the backend scopes those cases to the hub's admin).
String reconciliationCounterpartLabel({String? viewerRole, String? sourceType}) {
  if (viewerRole == 'DONOR' || viewerRole == 'HUB_ADMIN') return 'NGO';
  if (viewerRole == 'NGO') {
    return switch (sourceType) {
      'HUB_BATCH' => 'hub administrator',
      'DIRECT_DONATION' => 'donor',
      _ => 'donor or hub administrator',
    };
  }
  return 'counterpart';
}

/// Display summary of one `geolock.claim-coordination.v2` row.
class ReconciliationSummary {
  const ReconciliationSummary({
    required this.status,
    required this.nextAction,
    required this.counterpart,
    required this.resolved,
    this.viewerResponded,
    this.counterpartResponded,
  });

  /// One of the [GeoLockStatusText] labels.
  final String status;

  /// What the viewer can do now, phrased from the backend `can_*` flags.
  final String nextAction;

  /// "donor", "hub administrator", "NGO" or "counterpart".
  final String counterpart;
  final bool resolved;

  /// Whether a statement from each side exists in the CURRENT evidence round.
  /// `null` when the viewer role is unknown, so no claim is made either way.
  final bool? viewerResponded, counterpartResponded;
}

ReconciliationSummary reconciliationSummary(
  Map<String, dynamic> row, {
  String? viewerRole,
  String? sourceType,
}) {
  final counterpart = reconciliationCounterpartLabel(
    viewerRole: viewerRole,
    sourceType: sourceType,
  );
  final caseStatus = row['case_status'];
  if (caseStatus == 'RESOLVED_COLLECTED') {
    return ReconciliationSummary(
      status: GeoLockStatusText.resolvedCollected,
      nextAction: 'No further action. The handover is recorded as collected.',
      counterpart: counterpart,
      resolved: true,
    );
  }
  if (caseStatus == 'RESOLVED_RELEASED') {
    return ReconciliationSummary(
      status: GeoLockStatusText.resolvedReleased,
      nextAction: 'No further action. The claim was released without handover.',
      counterpart: counterpart,
      resolved: true,
    );
  }
  final round = row['evidence_round'];
  final statements = row['statements'] is List
      ? (row['statements'] as List).whereType<Map>().toList()
      : const <Map>[];
  bool? responded(String? participant) => participant == null
      ? null
      : statements.any(
          (s) => s['round'] == round && s['participant'] == participant,
        );
  // get_my_claim_coordination labels statements 'NGO' or 'Source'
  // (the donor for DIRECT_DONATION, the hub administrator for HUB_BATCH).
  final mine = switch (viewerRole) {
    'NGO' => 'NGO',
    'DONOR' || 'HUB_ADMIN' => 'Source',
    _ => null,
  };
  final theirs = switch (viewerRole) {
    'NGO' => 'Source',
    'DONOR' || 'HUB_ADMIN' => 'NGO',
    _ => null,
  };
  final String status;
  final String next;
  if (row['can_accept_review'] == true) {
    status = GeoLockStatusText.actionRequired;
    next = 'Accept or decline the joint review requested by the $counterpart.';
  } else if (row['can_submit'] == true) {
    status = GeoLockStatusText.actionRequired;
    next = 'Submit your handover statement.';
  } else if (row['can_resolve'] == true) {
    status = GeoLockStatusText.actionRequired;
    next = 'Both statements match. Resolve the matching statements.';
  } else if (row['can_request_review'] == true) {
    status = GeoLockStatusText.actionRequired;
    next = 'The statements conflict. Request a joint review with the $counterpart.';
  } else if (row['review_waiting'] == true) {
    status = GeoLockStatusText.underReview;
    next = 'Waiting for the $counterpart to accept the joint review.';
  } else if (caseStatus == 'MANUAL_REVIEW' ||
      row['blocker'] == 'JOINT_REVIEW_ACCEPTANCE_PENDING') {
    status = GeoLockStatusText.underReview;
    next = 'This case is under review. No action is available to you now.';
  } else if (row['blocker'] == 'AWAITING_COUNTERPART') {
    status = GeoLockStatusText.awaitingCounterpart;
    next = 'Waiting for the $counterpart to submit their statement.';
  } else {
    status = GeoLockStatusText.underReview;
    next = 'No action is available to you now. Refresh later.';
  }
  return ReconciliationSummary(
    status: status,
    nextAction: next,
    counterpart: counterpart,
    resolved: false,
    viewerResponded: responded(mine),
    counterpartResponded: responded(theirs),
  );
}

/// Chip label for one stop on an authorized route. Order matters: the most
/// specific backend evidence wins. [claimStatus] and [leaseIsExpired] come from
/// the NGO's own claim card for that stop, when it was read successfully.
/// [blockedNextTaskId] is the route's `next_executable_task_id` only when the
/// backend reports `PREVIOUS_PICKUP_UNRESOLVED`.
String routeStopLabel(
  Map<String, dynamic> stop, {
  required String? routeStatus,
  required String? currentTaskId,
  String? claimStatus,
  bool? leaseIsExpired,
  String? blockedNextTaskId,
}) {
  if (stop['detached'] == true) return 'Removed from route — claim kept';
  if (stop['lease_expired_pending_recovery'] == true) {
    return GeoLockStatusText.expiredAwaitingRecovery;
  }
  if (stop['deferred_status'] == 'RESOLVED_UNCOLLECTED') {
    // Released only when the claim card independently confirms it.
    return claimStatus == 'RELEASED' && leaseIsExpired == true
        ? GeoLockStatusText.expiredReleased
        : 'Not collected — resolved';
  }
  if (stop['deferred_for_reconciliation'] == true ||
      stop['needs_reconciliation'] == true) {
    return GeoLockStatusText.reconciliationRequired;
  }
  if (stop['task_status'] == 'COLLECTED') return 'Completed pickup';
  if (routeStatus == 'CANCELLED') return 'Not started';
  if (stop['task_id'] == currentTaskId) {
    return stop['task_status'] == 'DISPATCHED'
        ? 'Current pickup'
        : 'Next pickup — not started';
  }
  // The backend's next executable stop while an unresolved earlier pickup
  // blocks dispatch (PREVIOUS_PICKUP_UNRESOLVED from check_remaining).
  if (blockedNextTaskId != null && stop['task_id'] == blockedNextTaskId) {
    return 'Next pickup — blocked';
  }
  return 'Upcoming pickup';
}

/// True when a stop's claim needs (or is in) individual reconciliation and the
/// backend has already opened the case (claim RECONCILIATION_REQUIRED or a
/// deferred stop). Expiry still awaiting recovery is deliberately excluded.
bool stopHasOpenReconciliation(Map<String, dynamic> stop) =>
    stop['detached'] != true &&
    stop['deferred_status'] != 'RESOLVED_UNCOLLECTED' &&
    stop['deferred_status'] != 'RESOLVED_COLLECTED' &&
    stop['lease_expired_pending_recovery'] != true &&
    (stop['needs_reconciliation'] == true ||
        stop['deferred_for_reconciliation'] == true);

/// Notice body for a stop with an opened reconciliation case.
String stopReconciliationMessage(Map<String, dynamic> stop) {
  if (stop['deferred_for_reconciliation'] == true) {
    return 'This pickup was skipped and stays assigned until its reconciliation is resolved.';
  }
  if (stop['task_status'] == 'DISPATCHED') {
    return "This pickup's lease expired after dispatch. The pickup must be resolved before the route can continue.";
  }
  return "This pickup's lease expired and it could not be released safely. It must be resolved through reconciliation.";
}
