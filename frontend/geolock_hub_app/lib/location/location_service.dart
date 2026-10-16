import 'dart:async';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import 'location_result.dart';

class LocationServiceException implements Exception {
  final String message;
  const LocationServiceException(this.message);
  @override
  String toString() => message;
}

enum LocationPermissionState { denied, deniedForever, allowed }

class DeviceLocation {
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  const DeviceLocation(this.latitude, this.longitude, this.accuracyMeters);
}

abstract interface class LocationGateway {
  Future<bool> servicesEnabled();
  Future<LocationPermissionState> checkPermission();
  Future<LocationPermissionState> requestPermission();
  Future<DeviceLocation> currentPosition();
  Future<DeviceLocation?> geocodeAddress(String address);
  Future<String?> reverseGeocode(double latitude, double longitude);
}

class PlatformLocationGateway implements LocationGateway {
  final Geocoding _geocoding;
  PlatformLocationGateway({Geocoding? geocoding})
    : _geocoding = geocoding ?? Geocoding();

  LocationPermissionState _permission(LocationPermission permission) =>
      switch (permission) {
        LocationPermission.denied => LocationPermissionState.denied,
        LocationPermission.deniedForever =>
          LocationPermissionState.deniedForever,
        LocationPermission.unableToDetermine => LocationPermissionState.denied,
        _ => LocationPermissionState.allowed,
      };

  @override
  Future<bool> servicesEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermissionState> checkPermission() async =>
      _permission(await Geolocator.checkPermission());

  @override
  Future<LocationPermissionState> requestPermission() async =>
      _permission(await Geolocator.requestPermission());

  @override
  Future<DeviceLocation> currentPosition() async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return DeviceLocation(
      position.latitude,
      position.longitude,
      position.accuracy,
    );
  }

  @override
  Future<DeviceLocation?> geocodeAddress(String address) async {
    final matches = await _geocoding.locationFromAddress(address);
    if (matches.isEmpty) return null;
    return DeviceLocation(matches.first.latitude, matches.first.longitude, 0);
  }

  @override
  Future<String?> reverseGeocode(double latitude, double longitude) async {
    final places = await _geocoding.placemarkFromCoordinates(
      latitude,
      longitude,
    );
    if (places.isEmpty) return null;
    final p = places.first;
    final parts =
        [
              p.name,
              p.street,
              p.subLocality,
              p.locality,
              p.administrativeArea,
              p.postalCode,
              p.country,
            ]
            .whereType<String>()
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toSet();
    return parts.isEmpty ? null : parts.join(', ');
  }
}

class LocationService {
  final LocationGateway gateway;
  final Duration gpsTimeout;
  LocationService({
    LocationGateway? gateway,
    this.gpsTimeout = const Duration(seconds: 16),
  }) : gateway = gateway ?? PlatformLocationGateway();

  Future<LocationResult> currentLocation() async {
    if (!await gateway.servicesEnabled()) {
      throw const LocationServiceException(
        'Location services are turned off. Enable GPS and try again.',
      );
    }
    var permission = await gateway.checkPermission();
    if (permission == LocationPermissionState.denied) {
      permission = await gateway.requestPermission();
    }
    if (permission == LocationPermissionState.denied) {
      throw const LocationServiceException(
        'Location permission was denied. You can enter an address or select it on the map instead.',
      );
    }
    if (permission == LocationPermissionState.deniedForever) {
      throw const LocationServiceException(
        'Location permission is permanently denied. Enable it in app settings, or enter an address/select a map pin.',
      );
    }

    late final DeviceLocation position;
    try {
      position = await gateway.currentPosition().timeout(
        gpsTimeout,
        onTimeout: () => throw const LocationServiceException(
          'GPS timed out before a location fix was available. Try again or select the location on the map.',
        ),
      );
    } on TimeoutException {
      throw const LocationServiceException(
        'GPS timed out before a location fix was available. Try again or select the location on the map.',
      );
    }
    if (!position.latitude.isFinite || !position.longitude.isFinite) {
      throw const LocationServiceException('GPS returned an invalid location.');
    }
    if (position.accuracyMeters > 150) {
      throw LocationServiceException(
        'The GPS fix is too inaccurate (${position.accuracyMeters.round()} m). Move outdoors and try again, or choose a location on the map.',
      );
    }
    final address = await reverseGeocode(position.latitude, position.longitude);
    return LocationResult(
      address: address,
      latitude: position.latitude,
      longitude: position.longitude,
      method: LocationSelectionMethod.currentLocation,
      accuracyMeters: position.accuracyMeters,
    );
  }

  Future<LocationResult> geocodeAddress(String address) async {
    final query = address.trim();
    if (query.length < 4) {
      throw const LocationServiceException('Enter a fuller address to search.');
    }
    try {
      final match = await gateway
          .geocodeAddress(query)
          .timeout(const Duration(seconds: 15));
      if (match == null) {
        throw const LocationServiceException(
          'No matching location was found. Try a more specific address.',
        );
      }
      return LocationResult(
        address: query,
        latitude: match.latitude,
        longitude: match.longitude,
        method: LocationSelectionMethod.addressSearch,
      );
    } on LocationServiceException {
      rethrow;
    } on Exception catch (error) {
      throw LocationServiceException('Address lookup failed: $error');
    }
  }

  Future<String> reverseGeocode(double latitude, double longitude) async {
    try {
      final address = await gateway
          .reverseGeocode(latitude, longitude)
          .timeout(const Duration(seconds: 12));
      return address == null || address.trim().isEmpty
          ? _coordinateLabel(latitude, longitude)
          : address;
    } on Exception {
      return _coordinateLabel(latitude, longitude);
    }
  }

  Future<LocationResult> mapPinLocation(
    double latitude,
    double longitude,
  ) async => LocationResult(
    address: await reverseGeocode(latitude, longitude),
    latitude: latitude,
    longitude: longitude,
    method: LocationSelectionMethod.mapPin,
  );

  String _coordinateLabel(double latitude, double longitude) =>
      'Pinned location (${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)})';
}
