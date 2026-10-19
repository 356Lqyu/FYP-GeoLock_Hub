class DonationPhotoRules {
  static const int maxPhotos = 3;
  static const int maxTitleLength = 80;
  static const int maxDescriptionLength = 1000;

  static bool validPhotoCount(int count) => count >= 1 && count <= maxPhotos;

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

  static List<T> withCoverFirst<T>(List<T> photos, int coverIndex) {
    if (coverIndex < 0 || coverIndex >= photos.length) return List.of(photos);
    final result = List<T>.of(photos);
    final cover = result.removeAt(coverIndex);
    result.insert(0, cover);
    return result;
  }

  static Map<String, dynamic> createRpcPayload({
    required String requestId,
    required String title,
    required String description,
    required String pickupAddress,
    required double latitude,
    required double longitude,
    required String? pickupRoadNodeId,
    required List<Map<String, dynamic>> items,
    required List<Map<String, dynamic>> images,
  }) => {
    'p_request': requestId,
    'p_title': title.trim(),
    'p_description': description.trim().isEmpty ? null : description.trim(),
    'p_pickup_address': pickupAddress,
    'p_latitude': latitude,
    'p_longitude': longitude,
    'p_pickup_road_node_id': pickupRoadNodeId,
    'p_items': items,
    'p_images': images,
  };
}
