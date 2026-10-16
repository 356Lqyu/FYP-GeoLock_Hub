enum LocationSelectionMethod { currentLocation, addressSearch, mapPin }

class LocationResult {
  final String address;
  final double latitude;
  final double longitude;
  final LocationSelectionMethod method;
  final double? accuracyMeters;

  const LocationResult({
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.method,
    this.accuracyMeters,
  });
}
