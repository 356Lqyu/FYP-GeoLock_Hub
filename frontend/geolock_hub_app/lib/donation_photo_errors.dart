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
    if (error.code == '57014') {
      return 'Saving the donation timed out. Your donation was not confirmed. '
          'Retry using the same form; your photos and request are preserved. '
          '(code: 57014)';
    }
    final code = donationServerErrorCode(error);
    final known = code == null ? null : _donationServerMessage(code);
    if (known != null) return '$known (code: $code)';
    return 'Supabase could not save the donation. Check that the required '
        'donation-photo RPC migration is installed, then retry. Your donation '
        'was not confirmed. (code: ${code ?? error.code ?? 'unknown'})';
  }
  return 'The donation could not be confirmed. Check your connection and '
      'retry using the same form. Your photos and request are preserved.';
}

/// The upper-case reason code raised by the donation RPCs, e.g.
/// `INVALID_DONATION_ITEM` or `INVALID_DONATION_IMAGE_2`.
String? donationServerErrorCode(PostgrestException error) =>
    RegExp(r'\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b').firstMatch(error.message)?[0];

// Some codes carry a photo or item position suffix (INVALID_DONATION_IMAGE_2,
// INVALID_ITEM_PHOTO_2).
String _baseCode(String code) => code.replaceFirst(RegExp(r'_\d+$'), '');

String? _donationServerMessage(String code) {
  final base = _baseCode(code);
  final itemTemplate = _itemPhotoErrors[base];
  if (itemTemplate != null) {
    final position = RegExp(r'_(\d+)$').firstMatch(code)?[1];
    return itemTemplate.replaceAll(
      '{item}',
      position == null ? 'an item' : 'item $position',
    );
  }
  return _donationServerErrors[base];
}

// Item-photo errors name the item by its position in the form.
const _itemPhotoErrors = <String, String>{
  'INVALID_ITEM_PHOTO':
      'The photo for {item} has an unsupported type or size. Use JPG, PNG '
      'or WebP up to 5 MB.',
  'DUPLICATE_ITEM_PHOTO':
      'The same photo was chosen twice ({item}). Choose a different photo.',
  'ITEM_PHOTO_ALREADY_ATTACHED':
      'The photo for {item} already belongs to another donation. Choose the '
      'photo again.',
  'STAGED_ITEM_PHOTO_MISSING_OR_MISMATCHED':
      'The photo for {item} was not found on the server. Tap Submit to '
      'upload it again.',
};

const _donationServerErrors = <String, String>{
  'AT_LEAST_ONE_ITEM_REQUIRED': 'Add at least one item to the donation.',
  // The server uses one code for an incomplete item and an inactive category.
  'INVALID_DONATION_ITEM':
      'An item is missing or invalid. Each item needs a name, a quantity and '
      'unit weight above 0, and a category that is still active; reselect '
      'the category if it was recently retired.',
  'INVALID_TOTAL_WEIGHT': 'The total weight must be greater than 0 kg.',
  'ONE_TO_THREE_PHOTOS_REQUIRED': 'Add between 1 and 3 donation photos.',
  'ONE_TO_THIRTY_ITEMS_REQUIRED': 'Add between 1 and 30 items.',
  'AT_LEAST_ONE_ITEM_PHOTO_REQUIRED': 'Add a photo to at least one item.',
  'ONE_PHOTO_PER_ITEM': 'Each item can have only one photo.',
  'INVALID_ITEM_POSITIONS':
      'The item order could not be saved. Tap Submit again.',
  'ITEM_POSITION_MISMATCH':
      'The item order could not be saved. Tap Submit again.',
  'DONATION_REQUIRES_AT_LEAST_ONE_PHOTO': 'Add at least one donation photo.',
  'INVALID_DONATION_IMAGE':
      'A photo has an unsupported type or size. Use JPG, PNG or WebP up to '
      '5 MB.',
  'STAGED_DONATION_IMAGE_MISSING_OR_MISMATCHED':
      'A photo upload was not found on the server. Tap Submit to upload it '
      'again.',
  'INVALID_COORDINATES':
      'The pickup coordinates are invalid. Select the pickup location again.',
  'INVALID_DONATION_LOCATION_OR_TITLE':
      'The title, pickup address or coordinates are missing or invalid. '
      'Check the title and select the pickup location again.',
  'INVALID_DONATION_TITLE': 'Enter a title of up to 80 characters.',
  'DONATION_DESCRIPTION_TOO_LONG':
      'The description must be 1000 characters or fewer.',
  'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD':
      'This submission ID was already used for different donation details. '
      'The form now has a new ID; tap Submit again.',
  'DONOR_ONLY': 'Only a registered donor account can create donations.',
};

String donationPhotoFailureForStatusCode(int? statusCode) =>
    switch (statusCode) {
      403 =>
        'Supabase denied the photo upload. The GeoLock Storage permission '
            'migration may be missing or the signed-in account may not have a '
            'Donor profile. Your donation was not submitted; tap Retry after '
            'the issue is corrected.',
      404 =>
        'Donation photo storage is not configured in Supabase. Contact '
            'the project administrator. Your donation was not submitted.',
      413 =>
        'A photo exceeds the 5 MB upload limit. Choose smaller photos '
            'and try again.',
      _ =>
        'A photo could not be uploaded. Check your connection and try '
            'again. Your donation was not submitted.',
    };
