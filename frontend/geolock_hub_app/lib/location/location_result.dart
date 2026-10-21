import 'road_routing.dart';

enum LocationSelectionMethod { currentLocation, addressSearch, mapPin }

class LocationResult {
  final String address;
  final double latitude;
  final double longitude;
  final LocationSelectionMethod method;
  final double? accuracyMeters;

  /// Road-access preview for this exact point, when the picker checked it.
  final RoadAccessResult? roadAccess;

  const LocationResult({
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.method,
    this.accuracyMeters,
    this.roadAccess,
  });

  LocationResult withRoadAccess(RoadAccessResult? value) => LocationResult(
    address: address,
    latitude: latitude,
    longitude: longitude,
    method: method,
    accuracyMeters: accuracyMeters,
    roadAccess: value,
  );
}
