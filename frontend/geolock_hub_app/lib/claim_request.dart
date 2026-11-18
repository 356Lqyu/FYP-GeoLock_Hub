/// Send only after the retry UUID is stored and can be read back unchanged.
/// RPC exceptions intentionally leave that UUID available for a later retry.
Future<T> sendPersistedClaim<T>({
  required String? Function() readRequest,
  required Future<bool> Function(String) writeRequest,
  required String Function() newRequest,
  required Future<T> Function(String) send,
  String? expectedRequest,
}) async {
  final saved = readRequest();
  if (expectedRequest != null && saved != expectedRequest) {
    throw StateError('This saved claim attempt has changed.');
  }
  final request = saved ?? newRequest();
  if (!await writeRequest(request) || readRequest() != request) {
    throw StateError('Could not save the claim retry ID. No claim was sent.');
  }
  return send(request);
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

String claimRequestPrefix(String ngoId) => 'geolock_claim_request_${ngoId}_';

String claimRejectionMessage(String? reason) => switch (reason) {
  'CLAIM_CONFLICT' => 'This listing is no longer available to claim.',
  'LISTING_EXPIRED' => 'This listing has expired.',
  'LISTING_NOT_FOUND' => 'This listing is no longer available.',
  'ROUTE_UNAVAILABLE' =>
    'No directed road route is available for this listing.',
  'OUTSIDE_GEOFENCE' => 'This listing is outside the 20 km road pickup area.',
  'ELIGIBILITY_UNDETERMINED' =>
    'Road eligibility is still being checked. Refresh and try again.',
  'DONATION_NOT_READY' => 'This donation is no longer ready for pickup.',
  'BATCH_NOT_PUBLISHED' => 'This hub batch is no longer published.',
  'DONATION_SET_NOT_READY' =>
    'The donations in this listing are no longer ready.',
  'UNAUTHENTICATED' => 'Sign in again to claim this listing.',
  'ACTIVE_NGO_ONLY' =>
    'An active NGO account is required to claim this listing.',
  'REQUEST_AND_LISTING_REQUIRED' => 'The claim request is incomplete.',
  _ => 'The database declined this claim. Refresh before trying again.',
};

String confirmedClaimFailureMessage(Map<String, dynamic> result) =>
    result['reason_code'] == 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
    ? 'This request ID belongs to a different claim attempt. No new claim was created.'
    : 'The database rolled back this claim attempt. No claim was created. '
          'Retrying will reuse the saved request ID.';
