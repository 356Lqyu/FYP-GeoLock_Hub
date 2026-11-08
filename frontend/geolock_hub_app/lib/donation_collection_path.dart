/// Client-side preview of the backend collection-path rule.
///
/// Preview only: the server's `coordination_config.donation_direct_min_kg` is
/// authoritative and create_donation_with_images decides the committed path.
/// Keep this value in step with the DEV configuration.
const double donationDirectMinKgPreview = 10;

/// Σ quantity × unit weight, rounded to grams like the server's numeric(12,3).
/// Incomplete rows (null or non-positive values) contribute nothing.
double donationTotalWeightKg(
  Iterable<({int? quantity, double? unitWeightKg})> items,
) {
  var grams = 0;
  for (final item in items) {
    final quantity = item.quantity ?? 0;
    final unit = item.unitWeightKg ?? 0;
    if (quantity <= 0 || unit <= 0) continue;
    grams += quantity * (unit * 1000).round();
  }
  return grams / 1000;
}

String previewCollectionPath(double totalKg) =>
    totalKg >= donationDirectMinKgPreview ? 'DIRECT_PICKUP' : 'HUB_COLLECTION';

String collectionPathLabel(String? path) => switch (path) {
  'DIRECT_PICKUP' => 'Direct pickup',
  'HUB_COLLECTION' => 'Community hub',
  _ => path ?? 'Not decided',
};

String collectionPathPreviewText(double totalKg) {
  final total = 'Total ${totalKg.toStringAsFixed(1)} kg';
  return previewCollectionPath(totalKg) == 'DIRECT_PICKUP'
      ? '$total → Direct pickup: an NGO will collect from your location'
      : '$total → Community hub: you will drop it at a hub you choose';
}
