/// Client-side preview of the backend collection-path rule.
///
/// Preview only: the server's `coordination_config.donation_direct_min_kg` is
/// authoritative and create_donation_with_images decides the committed path.
/// Keep this value in step with the DEV configuration.
const double donationDirectMinKgPreview = 10;

// PostgreSQL numeric(12,3) stores up to twelve digits when expressed in grams.
const _maxDonationGrams = 999999999999;
final _decimalWeight = RegExp(
  r'^([+-]?)([0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?)([0-9]+))?$',
);
final _nonZeroDigit = RegExp('[1-9]');

({int? grams, String? error}) parseDonationUnitWeight(String input) {
  final text = input.trim();
  if (text.isEmpty) {
    return (grams: null, error: 'Enter the unit weight in kg.');
  }
  final match = _decimalWeight.firstMatch(text);
  final whole = match?.group(2) ?? '';
  final fraction = match?.group(3) ?? '';
  if (match == null || (whole.isEmpty && fraction.isEmpty)) {
    return (grams: null, error: 'Enter a valid unit weight.');
  }
  final digits = whole + fraction;
  final first = digits.indexOf(_nonZeroDigit);
  if (match.group(1) == '-' || first == -1) {
    return (grams: null, error: 'Unit weight must be greater than 0 kg.');
  }

  // An exponent larger than the input plus the storage precision can only
  // overflow or round to zero. Stop reading it once that outcome is known.
  final exponentLimit = digits.length + 12;
  var exponent = 0;
  for (final digit in (match.group(5) ?? '').codeUnits) {
    exponent = exponent * 10 + digit - 48;
    if (exponent > exponentLimit) break;
  }
  if (match.group(4) == '-') exponent = -exponent;

  final gramDigits = whole.length - first + exponent + 3;
  if (gramDigits < 0) {
    return (grams: null, error: 'Unit weight must be at least 0.001 kg.');
  }
  if (gramDigits > 12) {
    return (grams: null, error: 'Enter a valid unit weight.');
  }
  // Accumulate at most twelve digits and round using the next decimal digit.
  var grams = 0;
  for (var i = 0; i < gramDigits; i++) {
    final index = first + i;
    grams =
        grams * 10 +
        (index < digits.length ? digits.codeUnitAt(index) - 48 : 0);
  }
  final roundingDigit = first + gramDigits;
  if (roundingDigit < digits.length &&
      digits[roundingDigit].compareTo('5') >= 0) {
    grams++;
  }
  if (grams == 0) {
    return (grams: null, error: 'Unit weight must be at least 0.001 kg.');
  }
  if (grams > _maxDonationGrams) {
    return (grams: null, error: 'Enter a valid unit weight.');
  }
  return (grams: grams, error: null);
}

int? parseDonationQuantity(String input) {
  final quantity = int.tryParse(input.trim(), radix: 10);
  return quantity != null && quantity > 0 && quantity <= 2147483647
      ? quantity
      : null;
}

/// Returns no total until every row has a valid quantity and unit weight.
double? donationTotalWeightKg(
  Iterable<({int? quantity, int? unitWeightGrams})> items,
) {
  var grams = 0;
  for (final item in items) {
    final quantity = item.quantity;
    final unit = item.unitWeightGrams;
    if (quantity == null ||
        quantity <= 0 ||
        unit == null ||
        unit <= 0 ||
        quantity > (_maxDonationGrams - grams) ~/ unit) {
      return null;
    }
    grams += quantity * unit;
  }
  return grams == 0 ? null : grams / 1000;
}

String previewCollectionPath(double totalKg) =>
    totalKg >= donationDirectMinKgPreview ? 'DIRECT_PICKUP' : 'HUB_COLLECTION';

/// Prefer the donation path. A listing source is only a fallback for readers
/// that omit the path, such as get_my_claim_cards_v2.
String? collectionPathBadgeLabel(Object? path, {Object? listingSourceType}) {
  if (path != null) {
    return switch (path) {
      'DIRECT_HOUSEHOLD' || 'DIRECT_PICKUP' => 'Direct Pickup',
      'COMMUNITY_HUB' || 'HUB_COLLECTION' => 'Hub Collection',
      _ => null,
    };
  }
  return switch (listingSourceType) {
    'DIRECT_DONATION' => 'Direct Pickup',
    'HUB_BATCH' => 'Hub Collection',
    _ => null,
  };
}

String collectionPathLabel(String? path) =>
    collectionPathBadgeLabel(path) ??
    (path == null ? 'Not decided' : 'Collection path unavailable');

String collectionPathPreviewText(double totalKg) {
  final decimal = totalKg.toStringAsFixed(3);
  final displayedKg = decimal.replaceFirst(RegExp(r'0{1,2}$'), '');
  final total = 'Total $displayedKg kg';
  return previewCollectionPath(totalKg) == 'DIRECT_PICKUP'
      ? '$total → Direct pickup: an NGO will collect from your location'
      : '$total → Community hub: you will drop it at a hub you choose';
}
