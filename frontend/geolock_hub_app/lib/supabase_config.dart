/// Supabase environments supported by the GeoLock Hub mobile client.
///
/// DEV is the safe default for normal Flutter and Android Studio launches.
/// Selecting the teammate-shared project requires an explicit environment
/// define and separately supplied URL/key; it is never selected by fallback.
abstract final class SupabaseConfig {
  static const environment = String.fromEnvironment(
    'GEOLOCK_SUPABASE_ENV',
    defaultValue: 'dev',
  );

  static const _devProjectUrl = 'https://rcgyuwiidqvrgbxswhqj.supabase.co';
  static const _sharedProjectUrl = 'https://mffccmlimmbrgasgfnnq.supabase.co';

  // Supabase publishable client key from the tracked DEV config. This is
  // intentionally public client configuration, never a service/secret key.
  static const _devPublishableKey =
      'sb_publishable_6nGhMdwaC79KbE-JiX4yPA_f3jFNbvd';

  // The shared environment has no checked-in credentials. It requires both an
  // explicit environment selection and matching per-run configuration.
  static const _requestedUrl = String.fromEnvironment('GEOLOCK_SUPABASE_URL');
  static const _requestedKey = String.fromEnvironment(
    'GEOLOCK_SUPABASE_PUBLISHABLE_KEY',
  );

  static String get projectUrl {
    if (environment == 'dev') return _devProjectUrl;
    if (environment == 'shared') return _sharedProjectUrl;
    return '';
  }

  static String get publishableKey {
    if (environment == 'dev') return _devPublishableKey;
    if (environment == 'shared') return _requestedKey;
    return '';
  }

  static bool get isConfigured {
    if (environment == 'dev') {
      return projectUrl == _devProjectUrl &&
          publishableKey.startsWith('sb_publishable_');
    }
    if (environment == 'shared') {
      return _requestedUrl == _sharedProjectUrl &&
          projectUrl == _sharedProjectUrl &&
          publishableKey.startsWith('sb_publishable_');
    }
    return false;
  }
}
