import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/donation_photo_errors.dart';

void main() {
  test('403 explains Storage permission/profile setup without raw exception', () {
    final message = donationPhotoFailureForStatusCode(403);
    expect(message, contains('Storage permission'));
    expect(message, contains('Donor profile'));
    expect(message, isNot(contains('permission denied for table donations')));
  });

  test('missing bucket and size failures give actionable messages', () {
    expect(donationPhotoFailureForStatusCode(404), contains('not configured'));
    expect(donationPhotoFailureForStatusCode(413), contains('5 MB'));
  });

  test('unknown upload errors do not expose backend exception details', () {
    expect(donationPhotoFailureForStatusCode(500), contains('Check your connection'));
    expect(donationPhotoFailureForStatusCode(null), isNot(contains('StorageException')));
  });
}
