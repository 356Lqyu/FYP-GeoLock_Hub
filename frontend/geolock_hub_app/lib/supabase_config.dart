/// Shared Supabase project configuration for the GeoLock Hub mobile clients.
///
/// This publishable key is intended for client applications. Never put a
/// Supabase secret/service-role key or database password in this file.
abstract final class SupabaseConfig {
  static const _defaultProjectUrl =
      'https://rcgyuwiidqvrgbxswhqj.supabase.co';

  /// Use a local ignored `--dart-define-from-file` for development projects.
  /// These values are public client configuration; never put service secrets
  /// or a database password in Flutter defines.
  static const projectUrl = String.fromEnvironment(
    'GEOLOCK_SUPABASE_URL',
    defaultValue: _defaultProjectUrl,
  );
  static const publishableKey = String.fromEnvironment(
    'GEOLOCK_SUPABASE_PUBLISHABLE_KEY',
    defaultValue: '',
  );

  static bool get isConfigured =>
      projectUrl == _defaultProjectUrl &&
      publishableKey.startsWith('sb_publishable_');
}
