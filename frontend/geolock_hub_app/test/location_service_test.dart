import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/location/location_result.dart';
import 'package:geolock_hub_app/location/location_service.dart';

class _FakeLocationGateway implements LocationGateway {
  bool enabled = true;
  LocationPermissionState permission = LocationPermissionState.allowed;
  LocationPermissionState requestedPermission = LocationPermissionState.allowed;
  DeviceLocation fix = const DeviceLocation(3.139, 101.6869, 8);
  DeviceLocation? addressFix = const DeviceLocation(3.14, 101.69, 0);
  String? reverseAddress = 'Kuala Lumpur, Malaysia';
  Completer<DeviceLocation>? pendingFix;
  int permissionRequests = 0;

  @override
  Future<bool> servicesEnabled() async => enabled;
  @override
  Future<LocationPermissionState> checkPermission() async => permission;
  @override
  Future<LocationPermissionState> requestPermission() async {
    permissionRequests++;
    return requestedPermission;
  }

  @override
  Future<DeviceLocation> currentPosition() =>
      pendingFix?.future ?? Future.value(fix);
  @override
  Future<DeviceLocation?> geocodeAddress(String address) async => addressFix;
  @override
  Future<String?> reverseGeocode(double latitude, double longitude) async =>
      reverseAddress;
}

void main() {
  test(
    'does not request permission if location services are disabled',
    () async {
      final gateway = _FakeLocationGateway()..enabled = false;
      final service = LocationService(gateway: gateway);
      await expectLater(
        service.currentLocation(),
        throwsA(
          isA<LocationServiceException>().having(
            (error) => error.message,
            'message',
            contains('turned off'),
          ),
        ),
      );
      expect(gateway.permissionRequests, 0);
    },
  );

  test(
    'requests foreground permission only when current location is chosen',
    () async {
      final gateway = _FakeLocationGateway()
        ..permission = LocationPermissionState.denied
        ..requestedPermission = LocationPermissionState.allowed;
      final result = await LocationService(gateway: gateway).currentLocation();
      expect(gateway.permissionRequests, 1);
      expect(result.method, LocationSelectionMethod.currentLocation);
      expect(result.accuracyMeters, 8);
    },
  );

  test('handles denied and permanently denied foreground permission', () async {
    final denied = _FakeLocationGateway()
      ..permission = LocationPermissionState.denied
      ..requestedPermission = LocationPermissionState.denied;
    await expectLater(
      LocationService(gateway: denied).currentLocation(),
      throwsA(
        isA<LocationServiceException>().having(
          (error) => error.message,
          'message',
          contains('permission was denied'),
        ),
      ),
    );

    final forever = _FakeLocationGateway()
      ..permission = LocationPermissionState.deniedForever;
    await expectLater(
      LocationService(gateway: forever).currentLocation(),
      throwsA(
        isA<LocationServiceException>().having(
          (error) => error.message,
          'message',
          contains('permanently denied'),
        ),
      ),
    );
    expect(forever.permissionRequests, 0);
  });

  test('rejects inaccurate GPS and reports timeout', () async {
    final inaccurate = _FakeLocationGateway()
      ..fix = const DeviceLocation(3.139, 101.6869, 151);
    await expectLater(
      LocationService(gateway: inaccurate).currentLocation(),
      throwsA(
        isA<LocationServiceException>().having(
          (error) => error.message,
          'message',
          contains('too inaccurate'),
        ),
      ),
    );

    final timedOut = _FakeLocationGateway()
      ..pendingFix = Completer<DeviceLocation>();
    await expectLater(
      LocationService(
        gateway: timedOut,
        gpsTimeout: const Duration(milliseconds: 1),
      ).currentLocation(),
      throwsA(
        isA<LocationServiceException>().having(
          (error) => error.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });

  test('geocodes an address and reverse-geocodes a map pin', () async {
    final gateway = _FakeLocationGateway();
    final service = LocationService(gateway: gateway);
    final address = await service.geocodeAddress(
      'Central Market, Kuala Lumpur',
    );
    expect(address.latitude, 3.14);
    expect(address.method, LocationSelectionMethod.addressSearch);

    final pin = await service.mapPinLocation(3.15, 101.7);
    expect(pin.address, 'Kuala Lumpur, Malaysia');
    expect(pin.latitude, 3.15);
    expect(pin.method, LocationSelectionMethod.mapPin);
  });

  test(
    'map pin remains usable when reverse geocoding has no address',
    () async {
      final service = LocationService(
        gateway: _FakeLocationGateway()..reverseAddress = null,
      );
      final pin = await service.mapPinLocation(3.15, 101.7);
      expect(pin.address, contains('3.15000'));
      expect(pin.longitude, 101.7);
    },
  );
}
