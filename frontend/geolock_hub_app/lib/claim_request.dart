/// Send only after the retry UUID is stored and can be read back unchanged.
/// RPC exceptions intentionally leave that UUID available for a later retry.
Future<T> sendPersistedClaim<T>({
  required String? Function() readRequest,
  required Future<bool> Function(String) writeRequest,
  required String Function() newRequest,
  required Future<T> Function(String) send,
}) async {
  final request = readRequest() ?? newRequest();
  if (!await writeRequest(request) || readRequest() != request) {
    throw StateError('Could not save the claim retry ID. No claim was sent.');
  }
  return send(request);
}

enum ClaimResponseKind {
  success,
  alreadyClaimed,
  ineligible,
  rejected,
  confirmedRollback,
  unknown,
}

ClaimResponseKind claimResponseKind(Map<String, dynamic> result) {
  final outcome = result['outcome'];
  final reason = result['reason_code'];
  if (outcome == 'SUCCESS' &&
      result['claim_id'] is String &&
      (result['claim_id'] as String).isNotEmpty) {
    return ClaimResponseKind.success;
  }
  if (isConfirmedClaimFailure(result)) {
    return ClaimResponseKind.confirmedRollback;
  }
  if (outcome == 'CONFLICT' && reason == 'ALREADY_CLAIMED') {
    return ClaimResponseKind.alreadyClaimed;
  }
  if (outcome == 'INELIGIBLE' ||
      const {
        'OUTSIDE_GEOFENCE',
        'ROUTE_UNAVAILABLE',
        'ELIGIBILITY_UNDETERMINED',
      }.contains(reason)) {
    return ClaimResponseKind.ineligible;
  }
  if (outcome == 'CONFLICT' && reason is String && reason.isNotEmpty) {
    return ClaimResponseKind.rejected;
  }
  return ClaimResponseKind.unknown;
}

String claimRejectionMessage(Map<String, dynamic> result) {
  return switch (claimResponseKind(result)) {
    ClaimResponseKind.alreadyClaimed =>
      'This donation has already been claimed by another NGO.',
    ClaimResponseKind.ineligible =>
      'This claim is not eligible: ${result['reason_code'] ?? 'unknown reason'}.',
    ClaimResponseKind.rejected =>
      'This donation is not currently available to claim (${result['reason_code']}).',
    _ => 'The server did not confirm a claim rejection.',
  };
}

bool isConfirmedClaimFailure(Map<String, dynamic> result) =>
    result['outcome'] == 'ERROR' &&
    result['claim_id'] == null &&
    (result['reason_code'] == 'CLAIM_TRANSACTION_ROLLED_BACK' ||
        result['reason_code'] ==
            'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD') &&
    result['rollback_confirmed'] == true &&
    result['failure_audit_id'] is String &&
    (result['failure_audit_id'] as String).isNotEmpty;

String confirmedClaimFailureMessage(Map<String, dynamic> result) =>
    result['reason_code'] == 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
    ? 'This request ID belongs to a different claim attempt. No new claim was created.'
    : 'The database rolled back this claim attempt. No claim was created. '
          'Retrying will reuse the saved request ID.';
