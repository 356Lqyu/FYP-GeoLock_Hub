import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Fixed messages/IDs only: never include headers, JWTs or raw socket responses.
class RoutingRequestFailure extends StateError {
  RoutingRequestFailure(
    super.message, {
    required this.code,
    required this.phase,
    this.requestId,
    this.snapshotId,
    this.httpStatus,
    this.transportReason,
    this.outcomeUnknown = false,
  });
  final String code, phase;
  final String? requestId, snapshotId;
  final int? httpStatus;
  final String? transportReason;
  final bool outcomeUnknown;
  @override
  String toString() =>
      '$message (stage: $phase; code: $code'
      '${httpStatus == null ? '' : '; HTTP: $httpStatus'}'
      '${transportReason == null ? '' : '; transport: $transportReason'}'
      '${requestId == null ? '' : '; request: $requestId'}'
      '${snapshotId == null ? '' : '; snapshot: $snapshotId'}).';
}

/// Direct HTTPS worker transport. The user JWT stays in memory, never in URLs.
class RoutingWorkerClient {
  RoutingWorkerClient({
    required this.baseUrl,
    required this.accessToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 150),
  }) : _client = client ?? http.Client();
  final String baseUrl;
  final String? Function() accessToken;
  final http.Client _client;
  final Duration timeout;

  /// Build configuration only; independent of login, fleet and task eligibility.
  static String? configurationErrorCode(
    String value, {
    required String environment,
    bool debug = kDebugMode,
  }) {
    if (environment != 'dev') return 'PLANNER_DEV_BUILD_REQUIRED';
    if (value.trim().isEmpty) return 'PLANNER_URL_MISSING';
    if (!allowedUrl(value.trim(), debug: debug)) return 'PLANNER_URL_REJECTED';
    return null;
  }

  static String transportReason(http.ClientException error) {
    final message = error.message.toLowerCase();
    if (message.contains('cleartext') || message.contains('insecure http')) {
      return 'CLEARTEXT_BLOCKED';
    }
    if (message.contains('connection refused')) return 'CONNECTION_REFUSED';
    if (message.contains('failed host lookup')) return 'DNS_LOOKUP_FAILED';
    if (message.contains('permission denied') ||
        message.contains('operation not permitted')) {
      return 'NETWORK_PERMISSION_DENIED';
    }
    if (message.contains('connection reset')) return 'CONNECTION_RESET';
    if (message.contains('connection closed')) return 'CONNECTION_CLOSED';
    if (message.contains('network is unreachable')) {
      return 'NETWORK_UNREACHABLE';
    }
    return 'CLIENT_IO_ERROR';
  }

  static bool allowedUrl(String value, {bool debug = kDebugMode}) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !{'', '/'}.contains(uri.path)) {
      return false;
    }
    if (uri.host.endsWith('.supabase.co') &&
        uri.host != 'rcgyuwiidqvrgbxswhqj.supabase.co') {
      return false;
    }
    return uri.scheme == 'https' ||
        (debug &&
            uri.scheme == 'http' &&
            {'localhost', '127.0.0.1', '10.0.2.2', '::1'}.contains(uri.host));
  }

  /// Auth-free connectivity/project check. No snapshot or planning RPC is sent.
  Future<void> checkReady() async {
    if (!allowedUrl(baseUrl)) {
      throw StateError('Configure an approved routing worker URL.');
    }
    try {
      final request = http.Request('GET', Uri.parse(baseUrl).resolve('/health'))
        ..followRedirects = false;
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(const Duration(seconds: 5));
      final value = jsonDecode(response.body);
      if (response.statusCode != 200 ||
          value is! Map ||
          value['status'] != 'ACTIVE' ||
          value['project_ref'] != 'rcgyuwiidqvrgbxswhqj') {
        throw RoutingRequestFailure(
          'Planner is not ACTIVE for the intended DEV project. No new snapshot was requested',
          code: 'PLANNER_HEALTH_REJECTED',
          phase: 'planner_health',
          httpStatus: response.statusCode,
        );
      }
    } on TimeoutException {
      throw RoutingRequestFailure(
        'Planner connection check timed out. Check USB/ADB reverse; no new snapshot was requested',
        code: 'PLANNER_HEALTH_TIMEOUT',
        phase: 'planner_health',
      );
    } on http.ClientException catch (error) {
      throw RoutingRequestFailure(
        'Phone cannot connect to the planner. Check USB/ADB reverse; no new snapshot was requested',
        code: 'PLANNER_HEALTH_CONNECTION_FAILED',
        phase: 'planner_health',
        transportReason: transportReason(error),
      );
    } on FormatException {
      throw RoutingRequestFailure(
        'Planner health response is invalid. No new snapshot was requested',
        code: 'PLANNER_HEALTH_INVALID',
        phase: 'planner_health',
      );
    }
  }

  Future<Object?> plan(Map<String, dynamic> body) => _post('/v1/plan', body);

  Future<Object?> planAndAuthorize(Map<String, dynamic> body) =>
      _post('/v1/plan-and-authorize', body);
  Future<Object?> authorizationResult(Map<String, dynamic> body) =>
      _post('/v1/authorization-result', body);
  Future<Object?> authorizationCapabilities(Map<String, dynamic> body) =>
      _post('/v1/authorization-capabilities', body);

  /// Retrieves an existing owned result; never falls back to route generation.
  Future<Object?> savedResult(Map<String, dynamic> body) =>
      _post('/v1/planning-result', body);

  Future<Object?> _post(String path, Map<String, dynamic> body) async {
    if (!allowedUrl(baseUrl)) {
      throw StateError('Configure an HTTPS routing worker URL.');
    }
    final token = accessToken();
    if (token == null || token.isEmpty) {
      throw StateError('Sign in before planning.');
    }
    final request = http.Request('POST', Uri.parse(baseUrl).resolve(path))
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode(body);
    String? safeId(Object? v) =>
        v is String && RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(v) ? v : null;
    const readPhases = {
      '/v1/planning-result': 'saved_result_read',
      '/v1/authorization-result': 'authorization_receipt_read',
      '/v1/authorization-capabilities': 'authorization_capabilities_read',
    };
    const readMessages = {
      '/v1/planning-result':
          'Saved Proposed result could not be read. No planning request was sent',
      '/v1/authorization-result':
          'Authorization receipt could not be read. Preserve the existing operation; no write was requested',
      '/v1/authorization-capabilities':
          'Combined routing capability check failed. No snapshot was requested',
    };
    RoutingRequestFailure failure(
      String message,
      String code, {
      int? status,
      bool unknown = true,
      String? reason,
    }) => RoutingRequestFailure(
      readMessages[path] ?? message,
      code: code,
      phase:
          readPhases[path] ??
          (path == '/v1/plan-and-authorize'
              ? 'combined_route'
              : 'planner_http'),
      requestId: safeId(body['request_id']),
      snapshotId: safeId(body['snapshot_id']),
      httpStatus: status,
      outcomeUnknown: readPhases.containsKey(path) ? false : unknown,
      transportReason: reason,
    );
    late http.Response response;
    try {
      response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(timeout);
    } on TimeoutException {
      throw failure(
        'Planner response timed out. Its outcome is unknown; retain the saved request for reconciliation',
        'PLANNER_TIMEOUT',
      );
    } on http.ClientException catch (error) {
      throw failure(
        'Planner connection failed. Check USB/ADB reverse; retain the saved request instead of creating another snapshot',
        'PLANNER_CONNECTION_FAILED',
        reason: transportReason(error),
      );
    }
    if (response.bodyBytes.length > 8000000) {
      throw const FormatException('Routing response is too large.');
    }
    if (response.statusCode != 200) {
      String? code;
      try {
        final value = jsonDecode(response.body);
        if (value is Map && value['error'] is Map) {
          code = value['error']['code'] as String?;
        }
      } catch (_) {
        /* Do not display raw upstream pages or headers. */
      }
      final message = switch (code) {
        'WORKER_NOT_ACTIVATED' => 'Routing worker is not activated yet.',
        'SNAPSHOT_STALE' || 'SNAPSHOT_STALE_OR_RESERVATION_CONFLICT' =>
          'Planning inputs changed. Refresh tasks and vehicles, then generate a new plan.',
        'NO_ELIGIBLE_VEHICLES' =>
          'No eligible vehicles. No default vehicle was created.',
        'NO_PICKUP_TASKS' => 'No eligible pickup tasks remain.',
        'ROUTE_UNAVAILABLE' =>
          'A directed road path is unavailable. No route was published.',
        'JOB_IN_PROGRESS_RETRY_SAME_REQUEST' ||
        'WORKER_BUSY_RETRY_SAME_REQUEST' =>
          'Planning is busy. Retry the same request.',
        'RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST' ||
        'UPSTREAM_OUTCOME_UNKNOWN_RETRY' =>
          'Outcome is not confirmed. Retry the same request.',
        'AUTHENTICATION_OR_PERMISSION_DENIED' ||
        'AUTHENTICATION_REQUIRED' => 'Sign in again before planning.',
        _ =>
          'Routing was not confirmed. Refresh or retry; no dispatch authorization is implied.',
      };
      const known = {
        'DATABASE_REJECTED_REQUEST',
        'WORKER_DATABASE_PERMISSION_DENIED',
        'DATABASE_BUSY_RETRY',
        'UPSTREAM_REJECTED_REQUEST',
        'AUTOMATIC_AUTHORIZATION_CONTRACT_UNAVAILABLE',
        'COMBINED_WORKFLOW_DISABLED',
        'VALIDATOR_REJECTED_CANDIDATE',
        'WORKER_REQUEST_FAILED',
        'WORKER_NOT_ACTIVATED',
        'SNAPSHOT_STALE',
        'SNAPSHOT_STALE_OR_RESERVATION_CONFLICT',
        'NO_ELIGIBLE_VEHICLES',
        'NO_PICKUP_TASKS',
        'ROUTE_UNAVAILABLE',
        'JOB_IN_PROGRESS_RETRY_SAME_REQUEST',
        'WORKER_BUSY_RETRY_SAME_REQUEST',
        'RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST',
        'UPSTREAM_OUTCOME_UNKNOWN_RETRY',
        'AUTHENTICATION_OR_PERMISSION_DENIED',
        'AUTHENTICATION_REQUIRED',
      };
      throw failure(
        message,
        known.contains(code) ? code! : 'PLANNER_HTTP_REJECTED',
        status: response.statusCode,
        unknown:
            response.statusCode >= 500 ||
            response.statusCode == 429 ||
            code == 'JOB_IN_PROGRESS_RETRY_SAME_REQUEST',
      );
    }
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw failure(
        'Planner returned an invalid response. Retain the saved request; no authorization is confirmed',
        'PLANNER_RESPONSE_INVALID',
      );
    }
  }
}
