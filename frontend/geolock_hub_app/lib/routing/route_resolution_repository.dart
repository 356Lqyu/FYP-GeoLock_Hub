import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../supabase_config.dart';
import 'ngo_routing_repository.dart' show RpcCall, routingObject, routingRows;

String resolutionError(Object error) {
  if (error is ResolutionVersionConflict) {
    return 'Version conflict. Refresh to review newer evidence. No replacement statement was sent.';
  }
  if (error is PostgrestException) {
    if (error.message.contains('CASE_VERSION_STALE')) {
      return 'Version conflict. Refresh to review newer evidence. The saved request is retained; no retry was sent.';
    }
    if (['PGRST202', '42883', '42P01'].contains(error.code)) {
      return 'Reconciliation backend unavailable. Existing holds remain protected.';
    }
    if (error.code == '42501' || error.message.contains('PARTICIPANT')) {
      return 'You are not authorized to submit or view this evidence.';
    }
    final message = error.message.trim();
    if (message.isNotEmpty) {
      final code = error.code == null ? '' : ' (${error.code})';
      return 'Request failed$code: $message';
    }
  }
  if (error is TimeoutException) {
    return 'The server response timed out. The saved request is being checked by its protected receipt; do not submit a replacement.';
  }
  if (error is StateError) {
    return error.message;
  }
  if (error is FormatException) {
    return error.message;
  }
  return error.toString();
}

class ResolutionVersionConflict implements Exception {}

String custodyLabel(Object? assertion) => switch (assertion) {
  'NO_HANDOVER_SOURCE_RETAINS_GOODS' => 'Not Collected',
  'HANDOVER_TO_NGO_CONFIRMED' => 'Collected',
  'UNKNOWN_CUSTODY' => 'Custody uncertain',
  _ => 'Not provided',
};

Map<String, dynamic>? actionableDonorContext(Map<String, dynamic> value) {
  if (value['enabled'] != true ||
      value['history_truncated'] != false ||
      value['association_conflict'] != false) {
    return null;
  }
  final rows = routingRows(value['contexts'] ?? []);
  final active = rows.where((r) => r['can_submit_evidence'] == true).toList();
  if (active.length != 1) return null;
  final row = active.single;
  if (![
        'claim_id',
        'task_id',
        'route_id',
        'case_id',
      ].every((k) => row[k] is String) ||
      row['case_version'] is! int ||
      ![
        'AWAITING_EVIDENCE',
        'MANUAL_REVIEW',
      ].contains(row['resolution_status'])) {
    return null;
  }
  return row;
}

Map<String, dynamic>? actionableDonorClaimContext(Map<String, dynamic> value) {
  if (value['contract'] != 'geolock.donor-claim-reconciliation.v1' ||
      value['history_truncated'] != false ||
      value['association_conflict'] != false) {
    return null;
  }
  final active = routingRows(
    value['contexts'] ?? [],
  ).where((row) => row['can_submit_evidence'] == true).toList();
  if (active.length != 1) return null;
  final row = active.single;
  if (![
        'donation_id',
        'claim_id',
        'task_id',
        'case_id',
      ].every((key) => row[key] is String) ||
      row['source_type'] != 'DIRECT_DONATION' ||
      row['case_status'] != 'OPEN' ||
      !(row['allowed_assertions'] is List &&
          (row['allowed_assertions'] as List).contains('COLLECTED') &&
          (row['allowed_assertions'] as List).contains('NOT_COLLECTED'))) {
    return null;
  }
  return row;
}

String resolutionStatusLabel(Map<String, dynamic>? state) {
  if (state == null) return 'Backend unavailable';
  if (state['status'] == 'DISABLED') {
    return 'Backend unavailable — reporting not activated';
  }
  if (state['status'] == 'RESOLVED') return 'Resolved — confirmed by backend';
  if (state['status'] == 'MANUAL_REVIEW') return 'Manual review required';
  if (state['status'] == 'NOT_REPORTED') return 'Interruption not yet reported';
  final items = routingRows(state['items'] ?? []);
  if (items.isNotEmpty &&
      items.every(
        (i) =>
            i['ngo_assertion'] == 'NO_HANDOVER_SOURCE_RETAINS_GOODS' &&
            i['source_assertion'] == 'NO_HANDOVER_SOURCE_RETAINS_GOODS',
      ) &&
      state['vehicle_confirmed'] == true) {
    return 'Statements provided — awaiting authorized review';
  }
  return 'Awaiting participant statements or authorized review';
}

/// LOCAL prototype. No mutation on reads; no automatic write retries.
class RouteResolutionRepository {
  RouteResolutionRepository({
    required this._rpc,
    required this._identity,
    this.enabled = false,
  });
  factory RouteResolutionRepository.live() {
    final client = Supabase.instance.client;
    return RouteResolutionRepository(
      enabled:
          const bool.fromEnvironment('GEOLOCK_ROUTE_RESOLUTION_ENABLED') &&
          SupabaseConfig.environment == 'dev',
      identity: () => client.auth.currentUser?.id,
      rpc: (name, params) async {
        if (SupabaseConfig.environment != 'dev') {
          throw StateError('Route resolution is DEV only.');
        }
        return client.rpc(name, params: params);
      },
    );
  }
  final RpcCall _rpc;
  final String? Function() _identity;
  final bool enabled;
  String? get identity => _identity();
  static final Set<String> _flights = {};
  String _key(String owner, String route) => 'route_resolution_${owner}_$route';
  String _owner() {
    final owner = _identity();
    if (owner == null) throw StateError('Sign in before reviewing resolution.');
    return owner;
  }

  Future<Map<String, dynamic>> pending(String route) async {
    final owner = _owner();
    final prefs = await SharedPreferences.getInstance();
    if (_identity() != owner) throw StateError('Account changed.');
    final raw = prefs.getString(_key(owner, route));
    return raw == null ? {} : routingObject(jsonDecode(raw));
  }

  Future<Map<String, dynamic>> read(String route) async {
    if (!enabled) return {'status': 'DISABLED', 'enabled': false};
    final owner = _owner();
    final value = routingObject(
      await _rpc('get_my_route_resolution', {'p_route': route}),
    );
    if (_identity() != owner ||
        value['route_id'] != route ||
        value['contract'] != 'geolock.route-resolution.v1') {
      throw StateError('Resolution ownership or contract changed.');
    }
    return value;
  }

  Future<List<Map<String, dynamic>>> listCases() async {
    if (!enabled) return [];
    final owner = _owner();
    final value = routingObject(
      await _rpc('list_my_route_resolution_cases', {}),
    );
    if (_identity() != owner ||
        value['contract'] != 'geolock.route-resolution.v1') {
      throw StateError('Resolution ownership or contract changed.');
    }
    return routingRows(value['cases'] ?? []);
  }

  Future<Map<String, dynamic>> donorContext(String donation) async {
    if (!enabled) {
      return {'status': 'DISABLED', 'enabled': false, 'contexts': <dynamic>[]};
    }
    final owner = _owner();
    final value = routingObject(
      await _rpc('get_my_donation_route_resolution', {'p_donation': donation}),
    );
    if (_identity() != owner ||
        value['donation_id'] != donation ||
        value['contract'] != 'geolock.donor-route-resolution.v1') {
      throw StateError('Donation ownership or contract changed.');
    }
    routingRows(value['contexts']);
    return value;
  }

  Future<Map<String, dynamic>> donorClaimContext(String donation) async {
    if (!enabled) {
      return {
        'status': 'DISABLED',
        'contract': 'geolock.donor-claim-reconciliation.v1',
        'donation_id': donation,
        'contexts': <dynamic>[],
      };
    }
    final owner = _owner();
    final value = routingObject(
      await _rpc('get_my_donation_claim_reconciliation', {
        'p_donation': donation,
      }),
    );
    if (_identity() != owner ||
        value['donation_id'] != donation ||
        value['contract'] != 'geolock.donor-claim-reconciliation.v1') {
      throw StateError('Donation claim association or contract changed.');
    }
    routingRows(value['contexts'] ?? []);
    return value;
  }

  String _donorClaimKey(String owner, String donation) =>
      'donor_claim_reconciliation_${owner}_$donation';

  Future<Map<String, dynamic>?> reconcileDonorClaimRequest(
    String donation,
  ) async {
    if (!enabled) throw StateError('Claim reconciliation is disabled.');
    final owner = _owner();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_donorClaimKey(owner, donation));
    if (_identity() != owner) throw StateError('Account changed.');
    if (raw == null) return null;
    final request = routingObject(jsonDecode(raw));
    if (request['donation_id'] != donation ||
        request['owner'] != owner ||
        request['request_id'] is! String ||
        request['claim_id'] is! String ||
        request['case_id'] is! String ||
        request['handover_confirmed'] is! bool) {
      throw StateError('Saved donor statement needs authorized review.');
    }
    final receipt = routingObject(
      await _rpc('get_my_claim_reconciliation_receipt', {
        'p_request': request['request_id'],
      }),
    );
    if (_identity() != owner ||
        receipt['request_id'] != request['request_id']) {
      throw StateError('Donor statement receipt ownership changed.');
    }
    if (receipt['found'] != true) return {'found': false, 'request': request};
    if (receipt['claim_id'] != request['claim_id'] ||
        receipt['case_id'] != request['case_id'] ||
        receipt['handover_confirmed'] != request['handover_confirmed']) {
      throw StateError(
        'Donor statement receipt does not match the saved request.',
      );
    }
    final result = routingObject(receipt['result']);
    if (result['case_id'] != request['case_id']) {
      throw StateError('Donor statement result needs authorized review.');
    }
    if (_identity() != owner ||
        !await prefs.remove(_donorClaimKey(owner, donation))) {
      throw StateError('Confirmed donor statement was not archived locally.');
    }
    return {'found': true, 'request': request, 'result': result};
  }

  Future<Map<String, dynamic>> submitDonorClaimReconciliation(
    String donation,
    Map<String, dynamic> expected,
    String assertion,
  ) async {
    if (!enabled) throw StateError('Claim reconciliation is disabled.');
    if (!{'COLLECTED', 'NOT_COLLECTED'}.contains(assertion)) {
      throw StateError('Choose Collected or Not Collected explicitly.');
    }
    final owner = _owner();
    final context = await donorClaimContext(donation);
    final current = actionableDonorClaimContext(context);
    if (current == null ||
        ![
          'claim_id',
          'task_id',
          'case_id',
        ].every((key) => current[key] == expected[key]) ||
        !(current['allowed_assertions'] as List).contains(assertion)) {
      throw ResolutionVersionConflict();
    }
    final prefs = await SharedPreferences.getInstance();
    final key = _donorClaimKey(owner, donation);
    final savedRaw = prefs.getString(key);
    Map<String, dynamic> request;
    if (savedRaw != null) {
      request = routingObject(jsonDecode(savedRaw));
      if (request['owner'] != owner ||
          request['donation_id'] != donation ||
          request['claim_id'] != current['claim_id'] ||
          request['case_id'] != current['case_id'] ||
          request['handover_confirmed'] != (assertion == 'COLLECTED')) {
        throw StateError(
          'A different donor statement is still pending. Recover that saved request first.',
        );
      }
      final receipt = await reconcileDonorClaimRequest(donation);
      if (receipt?['found'] == true) {
        return routingObject(receipt!['result']);
      }
      // The protected receipt was checked. Replaying the exact same request id
      // is safe because submit_claim_reconciliation is actor/request idempotent.
    } else {
      request = {
        'owner': owner,
        'donation_id': donation,
        'claim_id': current['claim_id'],
        'task_id': current['task_id'],
        'case_id': current['case_id'],
        'handover_confirmed': assertion == 'COLLECTED',
        'request_id': const Uuid().v4(),
      };
      if (_identity() != owner ||
          !await prefs.setString(key, jsonEncode(request))) {
        throw StateError(
          'Unable to preserve donor request. No statement sent.',
        );
      }
    }
    if (_identity() != owner) throw StateError('Account changed.');
    final result = routingObject(
      await _rpc('submit_claim_reconciliation', {
        'p_claim': request['claim_id'],
        'p_handover_confirmed': request['handover_confirmed'],
        'p_request': request['request_id'],
      }),
    );
    if (_identity() != owner ||
        result['case_id'] != request['case_id'] ||
        result['outcome'] is! String) {
      throw StateError('Donor statement outcome needs receipt reconciliation.');
    }
    if (!await prefs.remove(key)) {
      throw StateError('Confirmed donor statement was not cleared locally.');
    }
    return result;
  }

  Future<Map<String, dynamic>> submitDonor(
    String donation,
    Map<String, dynamic> expected,
    String assertion,
  ) async {
    final current = actionableDonorContext(await donorContext(donation));
    if (current == null ||
        ![
          'claim_id',
          'task_id',
          'route_id',
          'case_id',
          'case_version',
        ].every((k) => expected[k] == current[k])) {
      throw ResolutionVersionConflict();
    }
    if (!(current['allowed_assertions'] is List &&
        (current['allowed_assertions'] as List).contains(assertion))) {
      throw StateError(
        'This assertion is not permitted for the protected pickup state.',
      );
    }
    return submit(
      current['route_id'] as String,
      current['task_id'] as String,
      assertion,
      expectedVersion: current['case_version'] as int,
      expectedCaseId: current['case_id'] as String,
    );
  }

  Future<Map<String, dynamic>> report(String route, String reason) async {
    // Retained for receipt recovery by older clients. The forward migration
    // rejects creation when no legacy case exists; the normal UI no longer
    // exposes a route interruption reporting action.
    final state = await read(route);
    if (state['enabled'] != true || state['status'] != 'NOT_REPORTED') {
      throw StateError('Refresh the existing resolution; no new report sent.');
    }
    return _write(route, 'report_my_route_interruption', {
      'p_route': route,
      'p_reason': reason,
    });
  }

  Future<Map<String, dynamic>> submit(
    String route,
    String? task,
    String assertion, {
    int? expectedVersion,
    String? expectedCaseId,
  }) async {
    final state = await read(route);
    if (state['enabled'] != true ||
        state['case_id'] is! String ||
        state['version'] is! int ||
        state['status'] == 'RESOLVED') {
      throw StateError('Resolution is not accepting evidence.');
    }
    if (expectedVersion != null && expectedVersion != state['version']) {
      throw ResolutionVersionConflict();
    }
    if (expectedCaseId != null && expectedCaseId != state['case_id']) {
      throw ResolutionVersionConflict();
    }
    if (task == null) {
      if (state['is_owner'] != true ||
          assertion != 'VEHICLE_RETURNED_TO_NGO_CONTROL') {
        throw StateError(
          'Only the route owner may confirm vehicle accountability.',
        );
      }
    } else {
      final items = routingRows(
        state['items'] ?? [],
      ).where((item) => item['task_id'] == task).toList();
      if (items.length != 1 ||
          !const {
            'NO_HANDOVER_SOURCE_RETAINS_GOODS',
            'HANDOVER_TO_NGO_CONFIRMED',
            'UNKNOWN_CUSTODY',
          }.contains(assertion) ||
          (items.single['initial_class'] == 'NEVER_STARTED' &&
              assertion == 'HANDOVER_TO_NGO_CONFIRMED')) {
        throw StateError(
          'Refresh the protected pickup association before submitting.',
        );
      }
    }
    return _write(route, 'submit_route_resolution_evidence', {
      'p_case': state['case_id'],
      'p_task': task,
      'p_assertion': assertion,
      'p_version': state['version'],
    });
  }

  Future<Map<String, dynamic>> incident(String route, String task) async {
    final state = await read(route);
    if (state['enabled'] != true || state['status'] != 'RESOLVED') {
      throw StateError('Only resolved cases accept a linked incident.');
    }
    return _write(route, 'report_route_resolution_incident', {
      'p_case': state['case_id'],
      'p_task': task,
      'p_assertion': 'UNKNOWN_CUSTODY',
    });
  }

  Future<Map<String, dynamic>> _write(
    String route,
    String method,
    Map<String, dynamic> params,
  ) async {
    if (!enabled) throw StateError('Route resolution is disabled.');
    final owner = _owner(), key = _key(_owner(), route);
    if (!_flights.add(key)) throw StateError('Resolution operation pending.');
    try {
      if ((await pending(route)).isNotEmpty) {
        throw StateError(
          'Reconcile the saved operation before another action.',
        );
      }
      final request = const Uuid().v4();
      final record = {
        'request_id': request,
        'route_id': route,
        'method': method,
        'params': {...params, 'p_request': request},
      };
      final prefs = await SharedPreferences.getInstance();
      if (_identity() != owner) throw StateError('Account changed.');
      if (!await prefs.setString(key, jsonEncode(record))) {
        throw StateError('Unable to preserve request. No write sent.');
      }
      if (_identity() != owner) throw StateError('Account changed.');
      final result = routingObject(
        await _rpc(method, routingObject(record['params'])),
      );
      await _confirmed(owner, route, record, result);
      return result;
    } finally {
      _flights.remove(key);
    }
  }

  Future<void> _confirmed(
    String owner,
    String route,
    Map<String, dynamic> record,
    Map<String, dynamic> result,
  ) async {
    if (_identity() != owner ||
        result['case_id'] is! String ||
        (record['method'] == 'report_my_route_interruption' &&
            result['route_id'] != route) ||
        (routingObject(record['params'])['p_case'] != null &&
            result['case_id'] != routingObject(record['params'])['p_case'])) {
      throw StateError('Outcome needs reconciliation; request retained.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (_identity() != owner) throw StateError('Account changed.');
    final key = _key(owner, route),
        historyKey = '${_key(owner, route)}_history';
    final history = prefs.getStringList(historyKey) ?? [];
    if (!history.any(
      (raw) =>
          routingObject(jsonDecode(raw))['request_id'] == record['request_id'],
    )) {
      if (!await prefs.setStringList(historyKey, [
        ...history,
        jsonEncode({...record, 'result': result}),
      ])) {
        throw StateError('History not preserved; request retained.');
      }
    }
    if (_identity() != owner) throw StateError('Account changed.');
    await prefs.remove(key); // Only after a verified known result is archived.
  }

  Future<Map<String, dynamic>?> reconcile(String route) async {
    if (!enabled) throw StateError('Route resolution is disabled.');
    final owner = _owner(), record = await pending(route);
    if (record.isEmpty) return null;
    final receipt = routingObject(
      await _rpc('get_my_route_resolution_receipt', {
        'p_request': record['request_id'],
      }),
    );
    if (_identity() != owner || receipt['request_id'] != record['request_id']) {
      throw StateError('Receipt ownership changed.');
    }
    if (receipt['outcome'] == 'NOT_FOUND') {
      return null; // Never proof of rollback.
    }
    if (receipt['outcome'] != 'FOUND') {
      throw StateError('Receipt not confirmed.');
    }
    final result = routingObject(receipt['result']);
    await _confirmed(owner, route, record, result);
    return result;
  }
}
