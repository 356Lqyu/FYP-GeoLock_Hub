import 'dart:convert';

/// A donor-visible claim row grouped by its claim UUID.
///
/// Identical duplicate RPC rows collapse. Different rows for the same claim
/// remain attached to the same entry and are marked for review rather than
/// silently losing evidence.
class DonorClaimHistoryEntry {
  const DonorClaimHistoryEntry({
    required this.claimId,
    required this.contexts,
    required this.occurredAt,
    required this.hasConflictingRows,
  });

  final String claimId;
  final List<Map<String, dynamic>> contexts;
  final DateTime? occurredAt;
  final bool hasConflictingRows;

  Map<String, dynamic> get latestContext => contexts.first;

  String get outcome =>
      (latestContext['case_status'] ??
              latestContext['blocking_reason'] ??
              'NO_OPEN_RECONCILIATION')
          .toString();
}

List<DonorClaimHistoryEntry> donorClaimHistory(Object? value) {
  if (value is! List) return const [];

  final groups = <String, List<Map<String, dynamic>>>{};
  final fingerprints = <String, Set<String>>{};
  var missingIdIndex = 0;
  for (final row in value) {
    if (row is! Map) continue;
    final context = Map<String, dynamic>.from(row);
    final rawId = context['claim_id']?.toString().trim();
    final id = rawId == null || rawId.isEmpty
        ? 'missing-claim-id-${missingIdIndex++}'
        : rawId;
    final canonical = jsonEncode(_canonicalize(context));
    final seen = fingerprints.putIfAbsent(id, () => <String>{});
    if (seen.add(canonical)) {
      groups.putIfAbsent(id, () => <Map<String, dynamic>>[]).add(context);
    }
  }

  final entries = <DonorClaimHistoryEntry>[];
  for (final group in groups.entries) {
    group.value.sort(_compareRows);
    entries.add(
      DonorClaimHistoryEntry(
        claimId: group.key,
        contexts: List.unmodifiable(group.value),
        occurredAt: _authoritativeTime(group.value.first),
        hasConflictingRows: group.value.length > 1,
      ),
    );
  }
  entries.sort((a, b) {
    final byTime = _compareDateDescending(a.occurredAt, b.occurredAt);
    if (byTime != 0) return byTime;
    final byState = _stateRank(b.outcome).compareTo(_stateRank(a.outcome));
    if (byState != 0) return byState;
    return a.claimId.compareTo(b.claimId);
  });
  return List.unmodifiable(entries);
}

DateTime? _authoritativeTime(Map<String, dynamic> row) {
  // These are database timestamps returned by the protected history reader.
  // Prefer the outcome/resolution time, then claim lifecycle timestamps.
  for (final key in const [
    'resolved_at',
    'closed_at',
    'claim_closed_at',
    'opened_at',
    'claimed_at',
    'claim_created_at',
    'created_at',
  ]) {
    final parsed = DateTime.tryParse(row[key]?.toString() ?? '');
    if (parsed != null) return parsed.toUtc();
  }
  return null;
}

int _compareRows(Map<String, dynamic> a, Map<String, dynamic> b) {
  final time = _compareDateDescending(
    _authoritativeTime(a),
    _authoritativeTime(b),
  );
  if (time != 0) return time;
  final byState = _stateRank(_outcome(b)).compareTo(_stateRank(_outcome(a)));
  if (byState != 0) return byState;
  return jsonEncode(_canonicalize(a)).compareTo(jsonEncode(_canonicalize(b)));
}

int _compareDateDescending(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

String _outcome(Map<String, dynamic> row) =>
    (row['case_status'] ?? row['blocking_reason'] ?? 'NO_OPEN_RECONCILIATION')
        .toString();

int _stateRank(String state) => switch (state) {
  'MANUAL_REVIEW' || 'OPEN' || 'WAITING_FOR_EXPIRY_RECOVERY' => 4,
  'RESOLVED_COLLECTED' || 'RESOLVED_RELEASED' => 3,
  'DONOR_EVIDENCE_ALREADY_RECORDED' || 'NGO_EVIDENCE_ALREADY_RECORDED' => 2,
  'NO_OPEN_RECONCILIATION' => 1,
  _ => 0,
};

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonicalize(value[key])};
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}

String donorCustodyEvidenceLabel(Object? handover) => handover == true
    ? 'Collected'
    : handover == false
    ? 'Not Collected'
    : 'No statement recorded';

String donorClaimOutcomeLabel(Object? raw) {
  final value = raw?.toString();
  return switch (value) {
    'NO_OPEN_RECONCILIATION' => 'No reconciliation required or recorded',
    'WAITING_FOR_EXPIRY_RECOVERY' => 'Waiting for protected expiry recovery',
    'RESOLVED_RELEASED' => 'Resolved — released',
    'RESOLVED_COLLECTED' => 'Resolved — collected',
    'MANUAL_REVIEW' => 'Under manual review',
    'OPEN' => 'Reconciliation open',
    null || '' => 'Claim outcome unavailable',
    _ => value,
  };
}
