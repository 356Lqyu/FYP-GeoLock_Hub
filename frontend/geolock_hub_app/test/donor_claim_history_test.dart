import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/donor_claim_history.dart';

Map<String, dynamic> context({
  required String claim,
  required String claimedAt,
  String? status,
  String? blocker,
  Object? donor,
  Object? ngo,
}) => {
  'claim_id': claim,
  'claimed_at': claimedAt,
  'case_status': ?status,
  'blocking_reason': ?blocker,
  'donor_evidence': {'handover_confirmed': donor},
  'ngo_evidence': {'handover_confirmed': ngo},
};

void main() {
  test('latest claim uses authoritative timestamp, not RPC list order', () {
    final entries = donorClaimHistory([
      context(
        claim: 'old',
        claimedAt: '2026-10-01T00:00:00Z',
        blocker: 'NO_OPEN_RECONCILIATION',
      ),
      context(
        claim: 'new',
        claimedAt: '2026-11-03T00:00:00Z',
        status: 'RESOLVED_RELEASED',
      ),
    ]);
    expect(entries.first.claimId, 'new');
    expect(entries.first.outcome, 'RESOLVED_RELEASED');
  });

  test('null, false and true custody evidence labels stay distinct', () {
    expect(donorCustodyEvidenceLabel(null), 'No statement recorded');
    expect(donorCustodyEvidenceLabel(false), 'Not Collected');
    expect(donorCustodyEvidenceLabel(true), 'Collected');
  });

  test('manual review and contradictory statements remain represented', () {
    final entries = donorClaimHistory([
      context(
        claim: 'manual',
        claimedAt: '2026-11-01T00:00:00Z',
        status: 'MANUAL_REVIEW',
        donor: true,
        ngo: false,
      ),
    ]);
    expect(entries.single.outcome, 'MANUAL_REVIEW');
    expect(
      entries.single.latestContext['donor_evidence']['handover_confirmed'],
      isTrue,
    );
    expect(
      entries.single.latestContext['ngo_evidence']['handover_confirmed'],
      isFalse,
    );
  });

  test(
    'duplicate claim UUID collapses exact rows and flags conflicting rows',
    () {
      final exact = context(
        claim: 'same',
        claimedAt: '2026-11-01T00:00:00Z',
        status: 'RESOLVED_RELEASED',
      );
      final entries = donorClaimHistory([
        exact,
        Map<String, dynamic>.from(exact),
        {
          ...exact,
          'donor_evidence': {'handover_confirmed': true},
        },
      ]);
      expect(entries, hasLength(1));
      expect(entries.single.claimId, 'same');
      expect(entries.single.contexts, hasLength(2));
      expect(entries.single.hasConflictingRows, isTrue);
    },
  );

  test('no-open reconciliation code is replaced by clear copy', () {
    expect(
      donorClaimOutcomeLabel('NO_OPEN_RECONCILIATION'),
      'No reconciliation required or recorded',
    );
  });
}
