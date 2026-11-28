class DonationPhotoRules {
  static const int maxTitleLength = 80;
  static const int maxDescriptionLength = 1000;

  static String? titleError(String value) {
    if (value.trim().isEmpty) return 'Donation title is required';
    if (value.trim().length > maxTitleLength) return 'Maximum 80 characters';
    return null;
  }

  static String? descriptionError(String value) {
    if (value.trim().isEmpty) return 'Donation description is required';
    if (value.length > maxDescriptionLength) return 'Maximum 1000 characters';
    return null;
  }
}

/// Item-level donation photos: each item has at most one optional photo, and
/// at least one item of a donation must have a photo. The database enforces
/// the same rules in `create_donation_with_item_photos`.
class DonationItemPhotoRules {
  static const int maxItems = 30;

  /// [itemHasPhoto] has one entry per item, in form order.
  static bool validItemPhotos(List<bool> itemHasPhoto) =>
      itemHasPhoto.isNotEmpty &&
      itemHasPhoto.length <= maxItems &&
      itemHasPhoto.any((hasPhoto) => hasPhoto);

  /// Parameters for `create_donation_with_item_photos`. Each item gets an
  /// explicit `item_position` (1..n) from its place in [items]; an item's
  /// optional `photo` map is passed through unchanged.
  static Map<String, dynamic> createRpcPayload({
    required String requestId,
    required String title,
    required String description,
    required String pickupAddress,
    required double latitude,
    required double longitude,
    required String? pickupRoadNodeId,
    required List<Map<String, dynamic>> items,
  }) => {
    'p_request': requestId,
    'p_title': title.trim(),
    'p_description': description.trim().isEmpty ? null : description.trim(),
    'p_pickup_address': pickupAddress,
    'p_latitude': latitude,
    'p_longitude': longitude,
    'p_items': [
      for (var index = 0; index < items.length; index++)
        {...items[index], 'item_position': index + 1},
    ],
    'p_pickup_road_node_id': pickupRoadNodeId,
  };

  static String? photoPath(Map row) {
    final path = row['photo_path']?.toString().trim();
    return path == null || path.isEmpty ? null : path;
  }

  /// True when any item row from an item reader has its own photo. Readers
  /// withhold `photo_path` where Storage would refuse the read, but still
  /// return `photo_image_id`.
  static bool hasItemPhotos(Iterable<Map> itemRows) => itemRows.any(
    (row) => row['photo_image_id'] != null || photoPath(row) != null,
  );

  /// Photos for the donation-level gallery, or null when it should be hidden.
  /// Photos already shown beside their item are left out, so an item-photo
  /// donation shows no gallery; legacy donations keep their gallery as before.
  static List<String>? legacyGalleryPaths(
    Iterable<String> paths,
    Iterable<Map> itemRows,
  ) {
    final itemPaths = itemRows.map(photoPath).whereType<String>().toSet();
    final rest = paths
        .where((path) => path.isNotEmpty && !itemPaths.contains(path))
        .toSet()
        .toList();
    if (rest.isEmpty && hasItemPhotos(itemRows)) return null;
    return rest;
  }

  /// Adds each item's photo (from `get_my_donation_items`) to the items of
  /// `get_my_donation_detail`, matched by `item_id`, and orders them by the
  /// stored item position. Items without a stored position (legacy donations)
  /// keep their original order after positioned ones.
  static List<Map<String, dynamic>> attachPhotos(
    Iterable<Map> detailItems,
    Iterable<Map> itemRows,
  ) {
    final byId = {
      for (final row in itemRows)
        if (row['item_id'] != null) row['item_id'].toString(): row,
    };
    final merged = <(int, Map<String, dynamic>)>[];
    var index = 0;
    for (final item in detailItems) {
      final copy = Map<String, dynamic>.from(item);
      final row = byId[copy['item_id']?.toString()];
      if (row != null) {
        copy['item_position'] = row['item_position'];
        copy['photo_image_id'] = row['photo_image_id'];
        copy['photo_path'] = photoPath(row);
      }
      merged.add((index++, copy));
    }
    int? position(Map item) => int.tryParse('${item['item_position']}');
    merged.sort((a, b) {
      final pa = position(a.$2), pb = position(b.$2);
      if (pa != null && pb != null && pa != pb) return pa.compareTo(pb);
      if (pa != null && pb == null) return -1;
      if (pa == null && pb != null) return 1;
      return a.$1.compareTo(b.$1);
    });
    return [for (final entry in merged) entry.$2];
  }
}
