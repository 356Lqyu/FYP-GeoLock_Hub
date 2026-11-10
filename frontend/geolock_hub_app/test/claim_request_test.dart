import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/claim_request.dart';

void main() {
  test('false storage result prevents the RPC', () async {
    var sent = false;
    await expectLater(
      sendPersistedClaim(
        readRequest: () => null,
        writeRequest: (_) async => false,
        newRequest: () => 'original-id',
        send: (_) async {
          sent = true;
        },
      ),
      throwsStateError,
    );
    expect(sent, isFalse);
  });

  test('storage exception prevents the RPC', () async {
    var sent = false;
    await expectLater(
      sendPersistedClaim(
        readRequest: () => null,
        writeRequest: (_) async => throw StateError('storage unavailable'),
        newRequest: () => 'original-id',
        send: (_) async {
          sent = true;
        },
      ),
      throwsStateError,
    );
    expect(sent, isFalse);
  });

  test(
    'failed readback prevents the RPC even when write returns true',
    () async {
      var sent = false;
      await expectLater(
        sendPersistedClaim(
          readRequest: () => null,
          writeRequest: (_) async => true,
          newRequest: () => 'original-id',
          send: (_) async {
            sent = true;
          },
        ),
        throwsStateError,
      );
      expect(sent, isFalse);
    },
  );

  test('lost response preserves original UUID for retry', () async {
    String? saved;
    final sent = <String>[];
    Future<bool> store(String value) async {
      saved = value;
      return true;
    }

    await expectLater(
      sendPersistedClaim(
        readRequest: () => saved,
        writeRequest: store,
        newRequest: () => 'original-id',
        send: (id) async {
          sent.add(id);
          throw StateError('response lost');
        },
      ),
      throwsStateError,
    );
    final response = await sendPersistedClaim(
      readRequest: () => saved,
      writeRequest: store,
      newRequest: () => 'must-not-be-used',
      send: (id) async {
        sent.add(id);
        return 'committed result';
      },
    );
    expect(response, 'committed result');
    expect(sent, ['original-id', 'original-id']);
  });

  test('only explicit rollback with audit receipt is confirmed failure', () {
    expect(isConfirmedClaimFailure({'outcome': 'ERROR'}), isFalse);
    expect(
      isConfirmedClaimFailure({'outcome': 'ERROR', 'rollback_confirmed': true}),
      isFalse,
    );
    expect(
      isConfirmedClaimFailure({
        'outcome': 'SUCCESS',
        'rollback_confirmed': true,
        'failure_audit_id': 'id',
      }),
      isFalse,
    );
    expect(
      isConfirmedClaimFailure({
        'outcome': 'ERROR',
        'reason_code': 'CLAIM_TRANSACTION_ROLLED_BACK',
        'rollback_confirmed': true,
        'failure_audit_id': 'id',
      }),
      isTrue,
    );
  });

  test('claim response categories stay distinct', () {
    expect(
      claimResponseKind({'outcome': 'SUCCESS', 'claim_id': 'claim-1'}),
      ClaimResponseKind.success,
    );
    expect(
      claimResponseKind({
        'outcome': 'CONFLICT',
        'reason_code': 'ALREADY_CLAIMED',
      }),
      ClaimResponseKind.alreadyClaimed,
    );
    // Older/current DEV RPC definitions may still return the broader
    // CLAIM_CONFLICT code. Keep it a generic unavailable rejection; only the
    // explicit ALREADY_CLAIMED code may claim another NGO owns the listing.
    expect(
      claimResponseKind({
        'outcome': 'CONFLICT',
        'reason_code': 'CLAIM_CONFLICT',
      }),
      ClaimResponseKind.rejected,
    );
    expect(
      claimResponseKind({
        'outcome': 'INELIGIBLE',
        'reason_code': 'OUTSIDE_GEOFENCE',
      }),
      ClaimResponseKind.ineligible,
    );
    expect(
      claimResponseKind({
        'outcome': 'ERROR',
        'reason_code': 'CLAIM_TRANSACTION_ROLLED_BACK',
        'rollback_confirmed': true,
        'failure_audit_id': 'audit-1',
      }),
      ClaimResponseKind.confirmedRollback,
    );
    expect(
      claimResponseKind({'outcome': 'ERROR', 'reason_code': 'UNKNOWN'}),
      ClaimResponseKind.unknown,
    );
    expect(
      claimRejectionMessage({
        'outcome': 'CONFLICT',
        'reason_code': 'ALREADY_CLAIMED',
      }),
      contains('already been claimed'),
    );
    expect(
      claimRejectionMessage({
        'outcome': 'CONFLICT',
        'reason_code': 'CLAIM_CONFLICT',
      }),
      contains('not currently available'),
    );
  });

  test(
    'key reuse stays distinct and contradictory ERROR stays unconfirmed',
    () {
      final reused = <String, dynamic>{
        'outcome': 'ERROR',
        'rollback_confirmed': true,
        'failure_audit_id': 'id',
        'reason_code': 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD',
      };
      expect(isConfirmedClaimFailure(reused), isTrue);
      expect(
        confirmedClaimFailureMessage(reused),
        contains('different claim attempt'),
      );
      expect(
        isConfirmedClaimFailure({...reused, 'claim_id': 'existing-claim'}),
        isFalse,
      );
      expect(
        isConfirmedClaimFailure({...reused, 'reason_code': 'UNKNOWN'}),
        isFalse,
      );
    },
  );
}
