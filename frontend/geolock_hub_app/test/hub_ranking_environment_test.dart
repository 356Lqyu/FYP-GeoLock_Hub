import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/hub_admin/hub_service.dart';
import 'package:geolock_hub_app/supabase_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const unverified = 'https://unverified.example';
  const approved = 'https://ranking-klsel.example';

  test('KLSEL skips ranking discovery without a valid approved origin', () {
    for (final url in [
      '',
      'http://127.0.0.1:8000',
      'https://user@ranking-klsel.example',
      '$approved/ranking',
      '$approved?project=klsel',
      '$approved#rank',
    ]) {
      expect(
        HubService.rankingApiCandidates(
          environment: 'klsel',
          configuredUrl: unverified,
          approvedKlselUrl: url,
        ),
        isEmpty,
        reason: url,
      );
    }
  });

  test('KLSEL uses only the approved HTTPS origin', () {
    expect(
      HubService.rankingApiCandidates(
        environment: 'klsel',
        configuredUrl: unverified,
        approvedKlselUrl: '$approved/',
      ),
      [approved],
    );
  });

  test('DEV and shared retain the teammate ranking discovery order', () {
    for (final environment in ['dev', 'shared']) {
      expect(
        HubService.rankingApiCandidates(
          environment: environment,
          configuredUrl: '$unverified/',
          approvedKlselUrl: approved,
        ),
        [
          unverified,
          hostedRankingApiUrl,
          'http://127.0.0.1:8000',
          'http://10.0.2.2:8000',
        ],
      );
    }
  });

  testWidgets(
    'KLSEL falls back to its Supabase RPC without probing a ranking server',
    (tester) async {
      const donation = '25aaa650-b752-4e49-9bad-c6f26b834bc5';
      final supabaseCalls = <Uri>[];
      var rankingCalls = 0;
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(() async {
        final supabase = await Supabase.initialize(
          url: SupabaseConfig.projectUrl,
          publishableKey: SupabaseConfig.publishableKey,
          authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
          ),
          httpClient: MockClient((request) async {
            supabaseCalls.add(request.url);
            return http.Response(
              '[{"hub_id":"fallback","hub_name":"Nearby hub","feasible":true}]',
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        addTearDown(supabase.dispose);
        final options = await http.runWithClient(
          () => HubService.hubOptions(donation, day: DateTime(2026, 11, 22)),
          () => MockClient((_) async {
            rankingCalls++;
            throw StateError('Unexpected ranking request');
          }),
        );
        expect(rankingCalls, 0);
        expect(supabaseCalls.single.origin, SupabaseConfig.projectUrl);
        expect(supabaseCalls.single.path, '/rest/v1/rpc/get_hub_options');
        expect(options.single.hubId, 'fallback');
        expect(options.single.rankingMode, 'NEAREST');
      });
    },
    skip: SupabaseConfig.environment != 'klsel',
  );
}
