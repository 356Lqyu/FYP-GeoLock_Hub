/// User-facing labels for the persisted donation lifecycle states.
///
/// `VALIDATED` is mapped only for backwards-compatible display of legacy rows;
/// the forward migration removes it as a committed state.
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
  if (inventoryStatus == 'STORED' || status == 'AT_HUB') return 'At Hub';
  if (listingStatus == 'CLAIMED') return 'Claimed';
  if (status == 'READY_FOR_PICKUP') return 'Ready for Pickup';
  if (status == 'PICKUP_IN_PROGRESS') return 'Pickup in Progress';
  if (status == 'COLLECTED') return 'Collected';
  if (status == 'CANCELLED') return 'Cancelled';
  return (status ?? 'Unknown').replaceAll('_', ' ');
}
