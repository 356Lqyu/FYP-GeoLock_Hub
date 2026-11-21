// Runs only in a KL/Selangor test invocation, for example:
//   flutter test test/supabase_config_klsel_test.dart --dart-define-from-file=klsel-config.json
// In a normal (DEV) `flutter test` run every check is skipped.
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';
import 'package:geolock_hub_app/supabase_config.dart';

void main() {
  const selected = SupabaseConfig.environment == 'klsel';
  test(
    'klsel builds target only the NEW project and never DEV',
    () {
      expect(
        SupabaseConfig.projectUrl,
        'https://ppwmdsyoesvhgmqiaoxa.supabase.co',
      );
      expect(SupabaseConfig.projectRef, 'ppwmdsyoesvhgmqiaoxa');
      expect(SupabaseConfig.publishableKey, startsWith('sb_publishable_'));
      expect(SupabaseConfig.isConfigured, isTrue);
      expect(SupabaseConfig.routingEnabled, isTrue);
      expect(
        RoutingWorkerClient.routingProjects[SupabaseConfig.environment],
        SupabaseConfig.projectRef,
      );
    },
    skip: selected ? false : 'Not a klsel test run (GEOLOCK_SUPABASE_ENV is not klsel).',
  );
}
