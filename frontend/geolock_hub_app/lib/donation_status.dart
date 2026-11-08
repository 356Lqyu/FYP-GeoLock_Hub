/// User-facing labels for the persisted donation lifecycle states.
///
/// `VALIDATED` and `READY_FOR_PICKUP` are display-only compatibility for
/// historical audit events and responses, never new operational states.
String donationStatusLabel({
  required String? status,
  String? collectionPath,
  String? reservationStatus,
  String? inventoryStatus,
  String? listingStatus,
}) {
  if (collectionPath == 'HUB_COLLECTION' &&
      (status == 'SUBMITTED' || status == 'VALIDATED')) {
    return 'Awaiting Hub Selection';
  }
  if (status == 'HUB_ASSIGNED' && reservationStatus == 'EXPIRED') {
    return 'Hub Reservation Expired';
  }
  if (status == 'HUB_ASSIGNED' && reservationStatus == 'ACTIVE') {
    return 'Awaiting Drop-off';
  }
  if (status == 'HUB_ASSIGNED') return 'Hub Assignment Needs Review';
  // Persisted donation state takes precedence over listing/inventory records.
  // A listing stays CLAIMED throughout pickup; inventory stays BATCHED.
  if (status == 'PICKUP_IN_PROGRESS') return 'Pickup in Progress';
  if (status == 'COLLECTED') return 'Collected';
  if (status == 'CANCELLED') return 'Cancelled';
  if (status == 'CLAIMED') return 'Claimed';
  if (status == 'AVAILABLE') return 'Available';
  if (status == 'BATCHED') return 'Included in a Batch';
  if (status == 'AT_HUB') return 'At Hub';
  // Historical audit/replay compatibility only; never an operational state.
  if (status == 'READY_FOR_PICKUP') return 'Ready for Pickup';
  return (status ?? 'Unknown').replaceAll('_', ' ');
}
