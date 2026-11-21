/// Supabase environments supported by the GeoLock Hub mobile client.
///
/// DEV is the safe default for normal Flutter and Android Studio launches.
/// Selecting the teammate-shared project or the NEW KL/Selangor project
/// (`klsel`) requires an explicit environment define and a separately supplied
/// URL/key; neither is ever selected by fallback.
abstract final class SupabaseConfig {
  static const environment = String.fromEnvironment(
    'GEOLOCK_SUPABASE_ENV',
    defaultValue: 'dev',
  );

  static const _devProjectUrl = 'https://rcgyuwiidqvrgbxswhqj.supabase.co';
  static const _sharedProjectUrl = 'https://mffccmlimmbrgasgfnnq.supabase.co';
  // NEW GeoLock project: KL/Selangor road network, frozen graph 19c44bd2-....
  static const _klselProjectUrl = 'https://ppwmdsyoesvhgmqiaoxa.supabase.co';

  // Supabase publishable client key from the tracked DEV config. This is
  // intentionally public client configuration, never a service/secret key.
  static const _devPublishableKey =
      'sb_publishable_6nGhMdwaC79KbE-JiX4yPA_f3jFNbvd';

  // The shared and klsel environments have no checked-in credentials. They
  // require both an explicit environment selection and matching per-run
  // configuration (for klsel: klsel-config.json, which is not tracked).
  static const _requestedUrl = String.fromEnvironment('GEOLOCK_SUPABASE_URL');
  static const _requestedKey = String.fromEnvironment(
    'GEOLOCK_SUPABASE_PUBLISHABLE_KEY',
  );

  static String get projectUrl {
    if (environment == 'dev') return _devProjectUrl;
    if (environment == 'shared') return _sharedProjectUrl;
    if (environment == 'klsel') return _klselProjectUrl;
    return '';
  }

  static String get publishableKey {
    if (environment == 'dev') return _devPublishableKey;
    if (environment == 'shared' || environment == 'klsel') return _requestedKey;
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
    if (environment == 'klsel') {
      return _requestedUrl == _klselProjectUrl &&
          projectUrl == _klselProjectUrl &&
          publishableKey.startsWith('sb_publishable_');
    }
    return false;
  }

  /// Supabase project ref of the selected environment, or '' if none.
  static String get projectRef {
    final host = Uri.tryParse(projectUrl)?.host ?? '';
    return host.endsWith('.supabase.co') ? host.split('.').first : '';
  }

  /// Routing workers exist only for DEV and the NEW KL/Selangor project.
  static bool get routingEnabled =>
      environment == 'dev' || environment == 'klsel';
}
