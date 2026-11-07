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
