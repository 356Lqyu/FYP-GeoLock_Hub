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
        return 'Choose a supported account role.';
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
        // Location is configured after login through a protected RPC.
        'p_operating_address': null,
        'p_latitude': null,
        'p_longitude': null,
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
    if (role == 'DONOR' || role == 'HUB_ADMIN') return true;
    if (role != 'NGO') return false;
    final ngoName = pending['ngo_name'];
    return ngoName is String && ngoName.trim().isNotEmpty;
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
