const double donationDirectMinKgPreview = 10;

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
