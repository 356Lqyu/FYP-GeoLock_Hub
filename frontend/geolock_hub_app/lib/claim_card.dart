/// Presentation only: no derived state authorizes a database transition.
enum ClaimTab { active, expired, history, all }

enum ClaimDisplayStatus {
  active,
  expiredPending,
  expired,
  reconciliation,
  collected,
  completed,
  cancelled,
  released,
  needsReview,
}

class ClaimCard {
  ClaimCard.fromJson(Map<String, dynamic> json) : raw = Map.unmodifiable(json);

  final Map<String, dynamic> raw;
  String? _text(String key) => raw[key]?.toString();
  DateTime? _date(String key) {
    final value = DateTime.tryParse(_text(key) ?? '');
    return value?.isUtc == true ? value : null;
  }

  String get claimId => _text('claim_id') ?? '';
  String? get listingId => _text('listing_id');
  String? get claimStatus => _text('claim_status');
  DateTime? get claimedAt => _date('claimed_at');
  String? get leaseId => _text('lease_id');
  String? get leaseStatus => _text('lease_status');
  DateTime? get leaseExpiresAt => _date('lease_expires_at');
  String? get taskStatus => _text('task_status');
  String? get sourceType => _text('source_type');
  num? get listingWeightKg => num.tryParse(_text('listing_weight_kg') ?? '');
  String? get title => _text('title');
  String? get primaryImagePath => _text('primary_image_path');
  DateTime? get serverNow => _date('server_now');
  bool? get leaseIsExpired =>
      raw['lease_is_expired'] is bool ? raw['lease_is_expired'] as bool : null;
  bool? get leaseRecoveryPending => raw['lease_recovery_pending'] is bool
      ? raw['lease_recovery_pending'] as bool
      : null;
  String? get releaseReason => _text('close_reason') ?? _text('release_reason');

  ClaimDisplayStatus get displayStatus {
    if (claimStatus == 'RECONCILIATION_REQUIRED' ||
        leaseStatus == 'RECONCILIATION_REQUIRED' ||
        raw['case_status'] == 'MANUAL_REVIEW' ||
        raw['reconciliation_status'] == 'MANUAL_REVIEW') {
      return ClaimDisplayStatus.reconciliation;
    }
    if (taskStatus == 'COLLECTED') return ClaimDisplayStatus.collected;
    if (claimStatus == 'COMPLETED') return ClaimDisplayStatus.completed;
    if (claimStatus == 'CANCELLED') return ClaimDisplayStatus.cancelled;
    if (claimStatus == 'RELEASED') return ClaimDisplayStatus.released;
    if (claimStatus == 'EXPIRED' || leaseStatus == 'EXPIRED') {
      return ClaimDisplayStatus.expired;
    }
    if (claimStatus != 'ACTIVE' ||
        leaseStatus != 'ACTIVE' ||
        claimId.isEmpty ||
        listingId == null ||
        listingId!.isEmpty ||
        leaseId == null ||
        leaseId!.isEmpty ||
        !const {'DIRECT_DONATION', 'HUB_BATCH'}.contains(sourceType) ||
        !const {'CONFIRMED', 'PLANNED', 'DISPATCHED'}.contains(taskStatus) ||
        leaseExpiresAt == null ||
        serverNow == null ||
        leaseIsExpired == null ||
        leaseRecoveryPending == null) {
      return ClaimDisplayStatus.needsReview;
    }
    // Cross-check only server timestamps/flags, never the device wall clock.
    final expired = !leaseExpiresAt!.isAfter(serverNow!);
    if (leaseIsExpired != expired || leaseRecoveryPending != expired) {
      return ClaimDisplayStatus.needsReview;
    }
    return expired
        ? ClaimDisplayStatus.expiredPending
        : ClaimDisplayStatus.active;
  }

  ClaimTab get tab => switch (displayStatus) {
    ClaimDisplayStatus.expiredPending ||
    ClaimDisplayStatus.expired => ClaimTab.expired,
    ClaimDisplayStatus.collected ||
    ClaimDisplayStatus.completed ||
    ClaimDisplayStatus.cancelled ||
    ClaimDisplayStatus.released => ClaimTab.history,
    _ => ClaimTab.active,
  };
  bool get isValidActive => displayStatus == ClaimDisplayStatus.active;
  bool get canStart =>
      isValidActive && const {'CONFIRMED', 'PLANNED'}.contains(taskStatus);
  bool get canCancel => isValidActive && taskStatus == 'CONFIRMED';
  bool get canComplete => isValidActive && taskStatus == 'DISPATCHED';
  String get badge => switch (displayStatus) {
    ClaimDisplayStatus.active => 'Active',
    ClaimDisplayStatus.expiredPending => 'Expired — Recovery Pending',
    ClaimDisplayStatus.expired => 'Expired',
    ClaimDisplayStatus.reconciliation => 'Needs Reconciliation',
    ClaimDisplayStatus.collected => 'Collected',
    ClaimDisplayStatus.completed => 'Completed',
    ClaimDisplayStatus.cancelled => 'Cancelled',
    ClaimDisplayStatus.released => 'Released',
    ClaimDisplayStatus.needsReview => 'Status Needs Review',
  };
}

List<ClaimCard> parseClaimCards(Object? response) {
  if (response is! List) {
    throw const FormatException('Invalid claim history response.');
  }
  return response
      .map((row) {
        if (row is! Map) throw const FormatException('Invalid claim card.');
        return ClaimCard.fromJson(Map<String, dynamic>.from(row));
      })
      .toList(growable: false);
}
