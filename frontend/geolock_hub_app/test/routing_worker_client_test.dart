// Synthetic HTTP responses only; these tests never connect to Supabase.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:geolock_hub_app/routing/routing_worker_client.dart';

void main() {
  test(
    'capability rejection retains safe server code and HTTP status',
    () async {
      final worker = RoutingWorkerClient(
        baseUrl: 'http://127.0.0.1:8787',
        accessToken: () => 'synthetic-token',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': 'DATABASE_REJECTED_REQUEST'},
            }),
            409,
          ),
        ),
      );
      await expectLater(
        worker.authorizationCapabilities({'request_id': 'synthetic-request'}),
        throwsA(
          isA<RoutingRequestFailure>()
              .having((e) => e.code, 'code', 'DATABASE_REJECTED_REQUEST')
              .having((e) => e.httpStatus, 'status', 409)
              .having(
                (e) => e.phase,
                'phase',
                'authorization_capabilities_read',
              )
              .having((e) => e.outcomeUnknown, 'unknown', false),
        ),
      );
    },
  );
  test('arbitrary upstream text is never retained as an error code', () async {
    final worker = RoutingWorkerClient(
      baseUrl: 'http://127.0.0.1:8787',
      accessToken: () => 'synthetic-token',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'secret arbitrary text'},
          }),
          409,
        ),
      ),
    );
    await expectLater(
      worker.authorizationCapabilities({'request_id': 'synthetic-request'}),
      throwsA(
        isA<RoutingRequestFailure>().having(
          (e) => e.code,
          'code',
          'PLANNER_HTTP_REJECTED',
        ),
      ),
    );
  });
  test('planner build configuration is explicit and fails closed', () {
    expect(
      RoutingWorkerClient.configurationErrorCode('', environment: 'dev'),
      'PLANNER_URL_MISSING',
    );
    expect(
      RoutingWorkerClient.configurationErrorCode('   ', environment: 'dev'),
      'PLANNER_URL_MISSING',
    );
    expect(
      RoutingWorkerClient.configurationErrorCode(
        ' http://127.0.0.1:8787 ',
        environment: 'dev',
        debug: true,
      ),
      isNull,
    );
    expect(
      RoutingWorkerClient.configurationErrorCode(
        'http://127.0.0.1:8787',
        environment: 'dev',
        debug: false,
      ),
      'PLANNER_URL_REJECTED',
    );
    expect(
      RoutingWorkerClient.configurationErrorCode(
        'http://127.0.0.1:8787',
        environment: 'shared',
        debug: true,
      ),
      'PLANNER_DEV_BUILD_REQUIRED',
    );
    expect(
      RoutingWorkerClient.configurationErrorCode(
        'http://user:password@127.0.0.1:8787',
        environment: 'dev',
        debug: true,
      ),
      'PLANNER_URL_REJECTED',
    );
  });
  test(
    'combined request requires explicit intent and does not retry after timeout',
    () async {
      var calls = 0;
      final client = RoutingWorkerClient(
        baseUrl: 'http://127.0.0.1:8787',
        accessToken: () => 'SYNTHETIC_TOKEN',
        timeout: const Duration(milliseconds: 1),
        client: MockClient((request) async {
          calls++;
          expect(request.url.path, '/v1/plan-and-authorize');
          expect(jsonDecode(request.body)['authorize_on_success'], true);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        client.planAndAuthorize({
          'request_id': 'request',
          'snapshot_id': 'snapshot',
          'authorize_on_success': true,
        }),
        throwsA(
          isA<RoutingRequestFailure>()
              .having((e) => e.phase, 'phase', 'combined_route')
              .having((e) => e.outcomeUnknown, 'uncertain', true),
        ),
      );
      expect(calls, 1);
    },
  );
  test(
    'authorization read failures are not described as planning writes',
    () async {
      final client = RoutingWorkerClient(
        baseUrl: 'http://127.0.0.1:8787',
        accessToken: () => 'SYNTHETIC_TOKEN',
        client: MockClient((request) async => http.Response('{}', 503)),
      );
      await expectLater(
        client.authorizationResult({
          'request_id': 'request',
          'snapshot_id': 'snapshot',
        }),
        throwsA(
          isA<RoutingRequestFailure>()
              .having((e) => e.phase, 'phase', 'authorization_receipt_read')
              .having((e) => e.outcomeUnknown, 'read-only', false),
        ),
      );
    },
  );
  test('saved result endpoint never falls back to planning', () async {
    var calls = 0;
    final client = RoutingWorkerClient(
      baseUrl: 'http://127.0.0.1:8787',
      accessToken: () => 'SYNTHETIC_TOKEN',
      client: MockClient((request) async {
        calls++;
        expect(request.url.path, '/v1/planning-result');
        expect(jsonDecode(request.body), {
          'request_id': 'request',
          'snapshot_id': 'snapshot',
        });
        return http.Response(
          jsonEncode({
            'error': {'code': 'NOT_FOUND'},
          }),
          404,
        );
      }),
    );
    await expectLater(
      client.savedResult({'request_id': 'request', 'snapshot_id': 'snapshot'}),
      throwsA(
        isA<RoutingRequestFailure>()
            .having((e) => e.phase, 'phase', 'saved_result_read')
            .having((e) => e.outcomeUnknown, 'read-only outcome', false),
      ),
    );
    expect(calls, 1);
  });
  test('transport reason is allowlisted rather than raw socket/JWT text', () {
    for (final item in {
      'Connection refused SYNTHETIC_SECRET': 'CONNECTION_REFUSED',
      'Cleartext HTTP traffic not permitted SYNTHETIC_SECRET':
          'CLEARTEXT_BLOCKED',
      'Failed host lookup SYNTHETIC_SECRET': 'DNS_LOOKUP_FAILED',
      'Operation not permitted SYNTHETIC_SECRET': 'NETWORK_PERMISSION_DENIED',
      'SYNTHETIC_SECRET': 'CLIENT_IO_ERROR',
    }.entries) {
      expect(
        RoutingWorkerClient.transportReason(http.ClientException(item.key)),
        item.value,
      );
    }
  });
  test(
    'read-only preflight checks the real health endpoint without JWT or plan',
    () async {
      final client = RoutingWorkerClient(
        baseUrl: 'http://127.0.0.1:8787',
        accessToken: () => 'SYNTHETIC_TOKEN',
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/health');
          expect(request.headers.containsKey('Authorization'), isFalse);
          expect(request.body, isEmpty);
          return http.Response(
            jsonEncode({
              'status': 'ACTIVE',
              'project_ref': 'rcgyuwiidqvrgbxswhqj',
            }),
            200,
          );
        }),
      );
      await client.checkReady();
    },
  );
  test(
    'wrong project and disconnected health checks fail without a planning request',
    () async {
      for (final mode in ['wrong-project', 'disabled', 'socket']) {
        var calls = 0;
        final client = RoutingWorkerClient(
          baseUrl: 'http://127.0.0.1:8787',
          accessToken: () => 'SYNTHETIC_TOKEN',
          client: MockClient((request) async {
            calls++;
            expect(request.method, 'GET');
            if (mode == 'socket') {
              throw http.ClientException('SYNTHETIC_SECRET');
            }
            return http.Response(
              jsonEncode({
                'status': mode == 'disabled' ? 'DISABLED' : 'ACTIVE',
                'project_ref': mode == 'wrong-project'
                    ? 'other'
                    : 'rcgyuwiidqvrgbxswhqj',
              }),
              200,
            );
          }),
        );
        await expectLater(
          client.checkReady(),
          throwsA(
            isA<RoutingRequestFailure>().having(
              (e) => e.phase,
              'phase',
              'planner_health',
            ),
          ),
        );
        expect(calls, 1);
      }
    },
  );
  test(
    'socket failure keeps IDs and never leaks raw transport text or retries',
    () async {
      var calls = 0;
      final client = RoutingWorkerClient(
        baseUrl: 'http://127.0.0.1:8787',
        accessToken: () => 'SYNTHETIC_TOKEN',
        client: MockClient((_) async {
          calls++;
          throw http.ClientException('SYNTHETIC_SECRET');
        }),
      );
      try {
        await client.plan({
          'request_id': 'saved-request',
          'snapshot_id': 'saved-snapshot',
        });
        fail('Expected failure');
      } on RoutingRequestFailure catch (e) {
        expect(e.code, 'PLANNER_CONNECTION_FAILED');
        expect(e.outcomeUnknown, isTrue);
        expect(e.requestId, 'saved-request');
        expect(e.snapshotId, 'saved-snapshot');
        expect(e.toString(), isNot(contains('SYNTHETIC_SECRET')));
        expect(e.toString(), contains('ADB reverse'));
      }
      expect(calls, 1);
    },
  );
  test(
    'timeout is a pending outcome rather than an infeasible or successful route',
    () async {
      final client = RoutingWorkerClient(
        baseUrl: 'https://synthetic-worker.example',
        accessToken: () => 'SYNTHETIC_TOKEN',
        timeout: const Duration(milliseconds: 1),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        client.plan({'request_id': 'r', 'snapshot_id': 's'}),
        throwsA(
          isA<RoutingRequestFailure>()
              .having((e) => e.code, 'code', 'PLANNER_TIMEOUT')
              .having((e) => e.outcomeUnknown, 'pending', isTrue),
        ),
      );
    },
  );
  test(
    'HTTP rejection retains status and malformed success cannot leak its body',
    () async {
      for (final status in [401, 409, 503, 200]) {
        final client = RoutingWorkerClient(
          baseUrl: 'https://synthetic-worker.example',
          accessToken: () => 'SYNTHETIC_TOKEN',
          client: MockClient(
            (_) async => http.Response(
              status == 200
                  ? 'SYNTHETIC_SECRET_INVALID_JSON'
                  : jsonEncode({
                      'error': {'code': 'SNAPSHOT_STALE'},
                    }),
              status,
            ),
          ),
        );
        try {
          await client.plan({'request_id': 'r', 'snapshot_id': 's'});
          fail('Expected failure');
        } on RoutingRequestFailure catch (e) {
          expect(e.toString(), isNot(contains('SYNTHETIC_SECRET')));
          if (status != 200) expect(e.httpStatus, status);
        }
      }
    },
  );
  test(
    'worker receives only snapshot IDs with JWT in header, never URL',
    () async {
      final client = RoutingWorkerClient(
        baseUrl: 'https://synthetic-worker.example',
        accessToken: () => 'SYNTHETIC_TOKEN',
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://synthetic-worker.example/v1/plan',
          );
          expect(request.headers['Authorization'], 'Bearer SYNTHETIC_TOKEN');
          expect(request.followRedirects, isFalse);
          expect(jsonDecode(request.body), {
            'snapshot_id': 'synthetic-snapshot',
            'request_id': 'synthetic-request',
          });
          return http.Response(
            jsonEncode({
              'kind': 'ADVISORY_CANDIDATE',
              'dispatch_authority_issued': false,
            }),
            200,
          );
        }),
      );
      final result = await client.plan({
        'snapshot_id': 'synthetic-snapshot',
        'request_id': 'synthetic-request',
      });
      expect((result as Map)['dispatch_authority_issued'], isFalse);
    },
  );
  test('untrusted cleartext and shared-project endpoints are rejected', () {
    expect(RoutingWorkerClient.allowedUrl('http://192.168.1.4:8787'), isFalse);
    expect(
      RoutingWorkerClient.allowedUrl('https://other.supabase.co'),
      isFalse,
    );
    expect(
      RoutingWorkerClient.allowedUrl('https://user:secret@worker.example'),
      isFalse,
    );
    expect(
      RoutingWorkerClient.allowedUrl('http://10.0.2.2:8787', debug: false),
      isFalse,
    );
    expect(
      RoutingWorkerClient.allowedUrl('http://10.0.2.2:8787', debug: true),
      isTrue,
    );
  });
  test('disabled service and stale snapshot are real failures', () async {
    for (final code in ['WORKER_NOT_ACTIVATED', 'SNAPSHOT_STALE']) {
      final client = RoutingWorkerClient(
        baseUrl: 'https://synthetic-worker.example',
        accessToken: () => 'SYNTHETIC_TOKEN',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': code},
            }),
            409,
          ),
        ),
      );
      await expectLater(
        client.plan({'snapshot_id': 's', 'request_id': 'r'}),
        throwsStateError,
      );
    }
  });
  test('unauthenticated call never makes an HTTP request', () async {
    final client = RoutingWorkerClient(
      baseUrl: 'https://synthetic-worker.example',
      accessToken: () => null,
      client: MockClient((_) async {
        fail('Unexpected HTTP call');
      }),
    );
    await expectLater(client.plan({}), throwsStateError);
  });
  test(
    'redirect is rejected without treating it as a planning result',
    () async {
      final client = RoutingWorkerClient(
        baseUrl: 'https://synthetic-worker.example',
        accessToken: () => 'SYNTHETIC_TOKEN',
        client: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          return http.Response(
            '',
            302,
            headers: {'location': 'https://untrusted.example'},
          );
        }),
      );
      await expectLater(client.plan({}), throwsStateError);
    },
  );
}
