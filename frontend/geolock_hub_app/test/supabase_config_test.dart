import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/supabase_config.dart';

void main() {
  test('normal launches use the isolated DEV project', () {
    expect(SupabaseConfig.environment, 'dev');
    expect(
      SupabaseConfig.projectUrl,
      'https://rcgyuwiidqvrgbxswhqj.supabase.co',
    );
    expect(SupabaseConfig.publishableKey, startsWith('sb_publishable_'));
    expect(SupabaseConfig.isConfigured, isTrue);
  });
}
