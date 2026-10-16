import 'package:supabase_flutter/supabase_flutter.dart';

class AuthController {
  AuthController._();
  static final instance = AuthController._();
  SupabaseClient get client => Supabase.instance.client;

  static String message(Object error) {
    if (error is StateError) return error.message.toString();
    if (error is AuthException) return error.message;
    if (error is PostgrestException) {
      final m = error.message;
      if (m.contains('ROLE_ALREADY_REGISTERED')) {
        return 'This account already has a registered role. Sign in again to continue.';
      }
      if (m.contains('ROLE_NOT_SELF_SERVICE')) {
        return 'Community Hub Admin accounts are provisioned by the GeoLock Hub administrator.';
      }
      if (m.contains('NGO_LOCATION_REQUIRED')) {
        return 'Enter an NGO name and confirm its operating location on the map.';
      }
      return m;
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  Future<Map<String, dynamic>?> profile({String? expectedUserId}) async {
    _requireCurrentUser(expectedUserId);
    final response = await client.rpc('get_my_profile');
    _requireCurrentUser(expectedUserId);
    if (response == null) return null;
    if (response is! Map) {
      throw const FormatException('Profile RPC returned an invalid response.');
    }
    return Map<String, dynamic>.from(response);
  }

  Future<AuthResponse> signIn(String email, String password) =>
      client.auth.signInWithPassword(email: email.trim(), password: password);

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required Map<String, dynamic> pendingProfile,
  }) => client.auth.signUp(
    email: email.trim(),
    password: password,
    data: {'geolock_pending_profile': pendingProfile},
  );

  Future<String?> completePendingRegistration({String? expectedUserId}) async {
    final user = client.auth.currentUser;
    if (user == null) {
      _requireCurrentUser(expectedUserId);
      return null;
    }
    final userId = user.id;
    _requireCurrentUser(expectedUserId ?? userId);
    final pending = user.userMetadata?['geolock_pending_profile'];
    if (pending is! Map || !_isValidPendingProfile(pending)) return null;
    final role = pending['role']?.toString();
    final existingProfile = await profile(expectedUserId: userId);
    _requireCurrentUser(userId);
    if (existingProfile != null) {
      if (existingProfile['role'] != role) {
        throw StateError(
          'The saved onboarding role does not match this account profile.',
        );
      }
      await client.auth.updateUser(
        UserAttributes(data: {'geolock_pending_profile': null}),
      );
      _requireCurrentUser(userId);
      return role;
    }
    if (role == 'NGO') {
      final capabilities = await client.rpc('geolock_app_capabilities');
      _requireCurrentUser(userId);
      if (capabilities is! Map ||
          capabilities['ngo_location_registration'] != 'UNVERIFIED') {
        throw StateError(
          'NGO registration is waiting for the reviewed backend migration that keeps self-selected locations unverified. Your account and pending registration are saved; retry after the migration is installed.',
        );
      }
    }
    await client.rpc(
      'register_role_profile',
      params: {
        'p_full_name': pending['full_name'],
        'p_role': role,
        'p_phone': pending['phone'],
        'p_ngo_name': role == 'NGO' ? pending['ngo_name'] : null,
        'p_registration_number': role == 'NGO'
            ? pending['registration_number']
            : null,
        'p_operating_address': role == 'NGO'
            ? pending['operating_address']
            : null,
        'p_latitude': role == 'NGO'
            ? double.tryParse('${pending['latitude']}')
            : null,
        'p_longitude': role == 'NGO'
            ? double.tryParse('${pending['longitude']}')
            : null,
        'p_road_node_id': null,
      },
    );
    _requireCurrentUser(userId);
    await client.auth.updateUser(
      UserAttributes(data: {'geolock_pending_profile': null}),
    );
    _requireCurrentUser(userId);
    return role;
  }

  bool _isValidPendingProfile(Map pending) {
    final role = pending['role']?.toString();
    final hasName =
        pending['full_name'] is String &&
        (pending['full_name'] as String).trim().isNotEmpty;
    if (!hasName) return false;
    if (role == 'DONOR') return true;
    if (role != 'NGO') return false;
    final ngoName = pending['ngo_name'];
    final address = pending['operating_address'];
    final latitude = double.tryParse('${pending['latitude']}');
    final longitude = double.tryParse('${pending['longitude']}');
    return ngoName is String &&
        ngoName.trim().isNotEmpty &&
        address is String &&
        address.trim().isNotEmpty &&
        latitude != null &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude != null &&
        longitude >= -180 &&
        longitude <= 180;
  }

  void _requireCurrentUser(String? expectedUserId) {
    if (expectedUserId != null &&
        client.auth.currentUser?.id != expectedUserId) {
      throw StateError('ACCOUNT_CHANGED');
    }
  }

  Future<void> sendReset(String email, {required String redirectTo}) =>
      client.auth.resetPasswordForEmail(email.trim(), redirectTo: redirectTo);

  Future<void> resendVerification(String email, {required String redirectTo}) =>
      client.auth.resend(
        type: OtpType.signup,
        email: email.trim(),
        emailRedirectTo: redirectTo,
      );

  Future<void> updatePassword(String password) async {
    final session = client.auth.currentSession;
    if (session == null) {
      throw const AuthException(
        'The password recovery link is invalid or has expired. Request a new link.',
      );
    }
    await client.auth.updateUser(UserAttributes(password: password));
  }
}
