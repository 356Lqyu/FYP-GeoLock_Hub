import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts backend photo failures into actions a donor can understand without
/// exposing raw PostgREST/Storage exception text in the submission screen.
String donationPhotoFailureMessage(Object error) {
  if (error is StorageException) {
    return donationPhotoFailureForStatusCode(
      int.tryParse(error.statusCode ?? ''),
    );
  }
  if (error is PostgrestException) {
    return 'Supabase could not save the donation. Check that the required '
        'donation-photo RPC migration is installed, then retry. Your donation '
        'was not confirmed.';
  }
  return 'The donation could not be confirmed. Check your connection and '
      'retry using the same form. Your photos and request are preserved.';
}

String donationPhotoFailureForStatusCode(int? statusCode) => switch (
  statusCode
) {
  403 => 'Supabase denied the photo upload. The GeoLock Storage permission '
      'migration may be missing or the signed-in account may not have a '
      'Donor profile. Your donation was not submitted; tap Retry after '
      'the issue is corrected.',
  404 => 'Donation photo storage is not configured in Supabase. Contact '
      'the project administrator. Your donation was not submitted.',
  413 => 'A photo exceeds the 5 MB upload limit. Choose smaller photos '
      'and try again.',
  _ => 'A photo could not be uploaded. Check your connection and try '
      'again. Your donation was not submitted.',
};
