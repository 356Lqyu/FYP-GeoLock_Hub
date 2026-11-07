import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'ngo_routing_repository.dart';

/// Local execution intent only. Every write still uses fresh protected RPCs.
/// Reads/reopening may reconcile a sent operation, but NEVER start a pickup.
class RouteExecutionController {
  RouteExecutionController(this.repository);
  final NgoRoutingRepository repository;
  static final Set<String> _flights = {};

  static bool held(Map<String, dynamic> record) =>
      record['status'] == 'sending' ||
      record['status'] == 'uncertain' ||
      record['status'] == 'retryable_same_request';

  static Map<String, dynamic>? currentStop(Map<String, dynamic> detail) {
    final stops = routingRows(detail['stops']);
    final dispatched = stops.where((s) => s['task_status'] == 'DISPATCHED');
    if (dispatched.isNotEmpty) return dispatched.first;
    final nextId = detail['next_executable_task_id'];
    if (nextId is String) {
      for (final stop in stops) {
        if (stop['task_id'] == nextId) return stop;
      }
    }
    for (final stop in stops) {
      if (stop['can_start'] == true || stop['can_defer'] == true) return stop;
    }
    for (final stop in stops) {
      if (stop['task_status'] != 'COLLECTED' &&
          stop['deferred_for_reconciliation'] != true &&
          stop['deferred_status'] != 'RESOLVED_UNCOLLECTED') {
        return stop;
      }
    }
    return null;
  }

  String _owner() {
    final owner = repository.identity;
    if (owner == null) throw StateError('Sign in before executing a route.');
    return owner;
  }

  String _key(String owner, String route) =>
      'ngo_route_execution_${owner}_$route';

  Future<Map<String, dynamic>> _load(String owner, String route) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(owner, route));
    if (repository.identity != owner) throw StateError('Sign-in changed.');
    if (raw == null) return {};
    final record = routingObject(jsonDecode(raw));
    if (record['version'] != 1 ||
        record['owner'] != owner ||
        record['route_id'] != route) {
      throw StateError('Execution history needs review. No pickup was sent.');
    }
    return record;
  }

  Future<void> _save(Map<String, dynamic> record) async {
    if (repository.identity != record['owner']) {
      throw StateError('Sign-in changed.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      _key(record['owner'], record['route_id']),
      jsonEncode(record),
    )) {
      throw StateError(
        'Cannot preserve execution progress. No further pickup will be sent.',
      );
    }
    if (repository.identity != record['owner']) {
      throw StateError('Sign-in changed.');
    }
  }

  Map<String, dynamic> _outcome(Map<String, dynamic> record, String outcome) {
    final pending = routingObject(record['attempt']);
    final updated = {...pending, 'outcome': outcome};
    return {
      ...record,
      'attempt': updated,
      'history': [
        for (final old in routingRows(record['history']))
          old['id'] == pending['id'] ? updated : old,
      ],
    };
  }

  /// Reconcile positive backend evidence only. An unchanged PLANNED/DISPATCHED
  /// row cannot prove a timed-out transaction rolled back, so remains held.
  Future<Map<String, dynamic>> reconcile(
    String route,
    Map<String, dynamic> detail,
  ) async {
    final owner = _owner();
    var record = await _load(owner, route);
    if (record.isEmpty || _flights.contains(_key(owner, route))) return record;
    if (held(record)) {
      final attempt = routingObject(record['attempt']);
      if (attempt['kind'] == 'defer' && attempt['request_id'] is String) {
        final receipt = await repository.deferredPickupReceipt(
          attempt['request_id'] as String,
        );
        final matches = routingRows(
          detail['stops'],
        ).where((s) => s['task_id'] == attempt['task_id']).toList();
        final stop = matches.length == 1 ? matches.single : null;
        final receiptFound =
            receipt['found'] == true &&
            receipt['route_id'] == route &&
            receipt['task_id'] == attempt['task_id'];
        final routeConfirms =
            stop?['deferred_for_reconciliation'] == true &&
            stop?['deferred_request_id'] == attempt['request_id'];
        if (receiptFound || routeConfirms) {
          record = _outcome(record, 'observed_confirmed');
          record = {
            ...record,
            'status': 'paused',
            'message':
                'The saved skip request is confirmed. Continue the route explicitly when ready.',
          };
        } else if (receipt['found'] == false) {
          record = {
            ...record,
            'status': 'retryable_same_request',
            'message':
                'No receipt exists for the saved skip request. Recover it with the same request ID; no new request will be created.',
          };
        } else {
          throw StateError(
            'Deferral receipt does not match the saved request.',
          );
        }
        await _save(record);
        return record;
      }
      final stops = routingRows(
        detail['stops'],
      ).where((s) => s['task_id'] == attempt['task_id']);
      final stop = stops.length == 1 ? stops.single : null;
      final collected = stop?['task_status'] == 'COLLECTED';
      final started = stop?['task_status'] == 'DISPATCHED';
      final deferred =
          attempt['kind'] == 'defer' &&
          stop?['deferred_for_reconciliation'] == true &&
          stop?['deferred_request_id'] == attempt['request_id'];
      if (deferred) {
        record = _outcome(record, 'observed_confirmed');
        record = {
          ...record,
          'status': 'paused',
          'message':
              'Pickup marked Needs reconciliation. Continue route explicitly to review the next eligible stop.',
        };
      } else if (collected || (attempt['kind'] == 'start' && started)) {
        record = _outcome(record, 'observed_confirmed');
        record = {
          ...record,
          'status': collected ? 'paused' : 'active',
          if (collected) 'last_completed_task_id': attempt['task_id'],
          'message': collected
              ? 'Pickup completion confirmed. Continue route explicitly to review the next stop.'
              : 'Pickup start confirmed. No start was repeated.',
        };
      } else {
        record = {
          ...record,
          'status': 'uncertain',
          'message':
              'Pickup outcome is not confirmed. Refresh to check; no write will be retried. Coordinator review may be needed.',
        };
      }
    }
    if (!held(record) &&
        (detail['route_status'] == 'COMPLETED' ||
            detail['route_status'] == 'ABANDONED')) {
      record = {
        ...record,
        'status': 'completed',
        'message': detail['route_status'] == 'ABANDONED'
            ? 'Route closed as ABANDONED after every pickup received a final outcome and vehicle accountability was confirmed.'
            : 'Route completed.',
      };
    } else if (!held(record) &&
        detail['awaiting_individual_reconciliation'] == true) {
      record = {
        ...record,
        'status': 'awaiting_reconciliation',
        'message':
            'Awaiting individual reconciliation for the skipped pickup. Other eligible pickups are complete.',
      };
    } else if (!held(record) && currentStop(detail) == null) {
      record = {
        ...record,
        'status': 'awaiting_depot',
        'message': detail['has_resolved_uncollected'] == true
            ? 'All pickups have final outcomes. Confirm return to depot to close the route.'
            : 'All pickups collected. Confirm return to depot.',
      };
    }
    await _save(record);
    return record;
  }

  Future<void> _exclusive(
    String route,
    Future<void> Function(String owner) action,
  ) async {
    final owner = _owner();
    final key = _key(owner, route);
    if (!_flights.add(key)) {
      throw StateError(
        'A pickup operation is already running. Refresh its outcome.',
      );
    }
    try {
      await action(owner);
    } finally {
      _flights.remove(key);
    }
  }

  Map<String, dynamic> _base(String owner, String route) => {
    'version': 1,
    'owner': owner,
    'route_id': route,
    'intent_id': null,
    'history': <Map<String, dynamic>>[],
    'status': 'paused',
  };

  bool _allowed(String owner, bool Function()? canContinue) =>
      repository.identity == owner && (canContinue?.call() ?? true);

  Future<Map<String, dynamic>> _send(
    Map<String, dynamic> record,
    String kind,
    String task, {
    bool Function()? canContinue,
  }) async {
    final attempt = {
      'id': const Uuid().v4(),
      'kind': kind,
      'task_id': task,
      'outcome': 'sending',
    };
    record = {
      ...record,
      'status': 'sending',
      'attempt': attempt,
      'history': [...routingRows(record['history']), attempt],
    };
    var sending = false;
    try {
      await repository.pickup(
        record['route_id'],
        task,
        complete: kind == 'complete',
        beforeMutation: () async {
          await _save(
            record,
          ); // Durable after protected checks, BEFORE the write.
          if (!_allowed(record['owner'], canContinue)) {
            throw StateError('Execution paused before sending pickup.');
          }
          sending = true;
        },
      );
    } catch (error) {
      // Explicit PostgreSQL transaction errors are known rejections. Transport,
      // response parsing and account-change errors may hide a committed write.
      final rejected =
          !sending ||
          error is PostgrestException &&
              {
                'P0001',
                '42501',
                '23505',
                '23514',
                '40001',
                '40P01',
                '57014',
                '22023',
                '22P02',
              }.contains(error.code);
      record = _outcome(record, rejected ? 'rejected' : 'unknown');
      record = {
        ...record,
        'status': rejected ? 'paused' : 'uncertain',
        'message':
            '${record['last_completed_task_id'] != null ? 'Previous pickup completed. ' : ''}'
            '${rejected ? 'Pickup rejected: ${routingError(error)}' : 'Pickup outcome is not confirmed. Refresh to reconcile; no automatic retry.'}',
      };
      await _save(record);
      rethrow;
    }
    record = _outcome(record, 'confirmed');
    record = {
      ...record,
      'status': kind == 'start' ? 'active' : 'paused',
      if (kind == 'complete') 'last_completed_task_id': task,
      'message': kind == 'start'
          ? 'Route in progress. Complete the current pickup after collection.'
          : 'Pickup completion confirmed.',
    };
    await _save(record);
    return record;
  }

  Future<void> _startNext(
    Map<String, dynamic> record, {
    bool Function()? canContinue,
  }) async {
    final owner = record['owner'] as String;
    if (!_allowed(owner, canContinue)) {
      await _save({
        ...record,
        'status': 'paused',
        'message': 'Execution paused. Continue route explicitly when ready.',
      });
      return;
    }
    final detail = await repository.detail(record['route_id']);
    if (detail['route_status'] == 'COMPLETED' ||
        detail['route_status'] == 'ABANDONED' ||
        detail['route_status'] == 'CANCELLED' ||
        detail['route_status'] == 'STALE') {
      throw StateError('This route is already closed.');
    }
    final next = currentStop(detail);
    if (!_allowed(owner, canContinue)) {
      await _save({
        ...record,
        'status': 'paused',
        'message': 'Execution paused. No next pickup was sent.',
      });
      return;
    }
    if (next == null) {
      if (detail['awaiting_individual_reconciliation'] == true) {
        await _save({
          ...record,
          'status': 'awaiting_reconciliation',
          'message':
              'Awaiting individual reconciliation for the skipped pickup. Other eligible pickups are complete.',
        });
        return;
      }
      await _save({
        ...record,
        'status': 'awaiting_depot',
        'message': detail['has_resolved_uncollected'] == true
            ? 'All pickups have final outcomes. Confirm return to depot to close the route.'
            : 'All pickups collected. Confirm return to depot.',
      });
    } else if (detail['authorization_confirmed'] == true &&
        next['can_start'] == true &&
        next['task_status'] == 'PLANNED') {
      await _send(
        record,
        'start',
        next['task_id'] as String,
        canContinue: canContinue,
      );
    } else {
      await _save({
        ...record,
        'status': 'paused',
        'message':
            '${record['last_completed_task_id'] != null ? 'Previous pickup completed. ' : ''}'
            'Next pickup not started. ${routingDispatchMessage(detail['dispatch_block_reason'])}',
      });
    }
  }

  /// Explicit Start Route / Continue intent. Never called by page loading.
  Future<void> startRoute(String route, {bool Function()? canContinue}) =>
      _exclusive(route, (owner) async {
        var record = await _load(owner, route);
        if (held(record)) {
          throw StateError('Reconcile the uncertain pickup before continuing.');
        }
        if (record['status'] == 'completed') {
          throw StateError('Route already completed.');
        }
        record = {
          ...(record.isEmpty ? _base(owner, route) : record),
          'intent_id': record['intent_id'] ?? const Uuid().v4(),
        };
        await _save(record);
        await _startNext(record, canContinue: canContinue);
      });

  Future<void> completeCurrent(
    String route,
    String task, {
    bool Function()? canContinue,
  }) => _exclusive(route, (owner) async {
    var record = await _load(owner, route);
    if (held(record)) {
      throw StateError('Reconcile the uncertain pickup before continuing.');
    }
    final detail = await repository.detail(route);
    final current = currentStop(detail);
    if (detail['authorization_confirmed'] != true ||
        current?['task_id'] != task ||
        current?['can_complete'] != true) {
      throw StateError(
        'Current pickup completion is blocked. Refresh its protected permissions.',
      );
    }
    if (!_allowed(owner, canContinue)) {
      throw StateError('Execution paused. No completion was sent.');
    }
    record = await _send(
      record.isEmpty ? _base(owner, route) : record,
      'complete',
      task,
      canContinue: canContinue,
    );
    // Old/manual starts have no original Start Route consent: never infer one.
    if (record['intent_id'] == null) {
      await _save({
        ...record,
        'status': 'paused',
        'message':
            'Pickup completed. Continue route explicitly to review the next stop.',
      });
      return;
    }
    await _startNext(record, canContinue: canContinue);
  });

  /// Defer a never-started pickup only after the protected route read grants it.
  /// The durable request ID doubles as the attempt ID; uncertain writes are
  /// reconciled from a fresh route read and are never blindly repeated.
  Future<void> deferForReconciliation(
    String route,
    String task, {
    bool Function()? canContinue,
  }) => _exclusive(route, (owner) async {
    var record = await _load(owner, route);
    final prior = record.isEmpty
        ? <String, dynamic>{}
        : routingObject(record['attempt']);
    final recovering =
        prior['kind'] == 'defer' &&
        prior['task_id'] == task &&
        prior['request_id'] is String &&
        {
          'uncertain',
          'sending',
          'retryable_same_request',
        }.contains(record['status']);
    if (held(record) && !recovering) {
      throw StateError('Reconcile the saved pickup request before continuing.');
    }
    if (recovering) {
      final receipt = await repository.deferredPickupReceipt(
        prior['request_id'] as String,
      );
      if (receipt['found'] == true) {
        if (receipt['route_id'] != route || receipt['task_id'] != task) {
          throw StateError(
            'Saved deferral receipt does not match this pickup.',
          );
        }
        record = _outcome(record, 'observed_confirmed');
        await _save({
          ...record,
          'status': 'paused',
          'message': 'The saved skip request is confirmed.',
        });
        return;
      }
      if (receipt['found'] != false ||
          receipt['request_id'] != prior['request_id']) {
        throw StateError('Saved deferral receipt is not confirmed.');
      }
    }
    final detail = await repository.detail(route);
    final stops = routingRows(
      detail['stops'],
    ).where((s) => s['task_id'] == task);
    final stop = stops.length == 1 ? stops.single : null;
    if (detail['authorization_confirmed'] != true ||
        stop?['can_defer'] != true ||
        !_allowed(owner, canContinue)) {
      throw StateError('The backend has not authorized deferring this pickup.');
    }
    final request = recovering
        ? prior['request_id'] as String
        : const Uuid().v4();
    final attempt = {
      'id': request,
      'request_id': request,
      'kind': 'defer',
      'task_id': task,
      'outcome': 'sending',
    };
    record = recovering
        ? {
            ...record,
            'status': 'sending',
            'attempt': attempt,
            'history': [
              for (final old in routingRows(record['history']))
                old['id'] == request ? attempt : old,
            ],
          }
        : {
            ...(record.isEmpty ? _base(owner, route) : record),
            'status': 'sending',
            'attempt': attempt,
            'history': [
              ...routingRows(record['history'] ?? const <dynamic>[]),
              attempt,
            ],
          };
    var sending = false;
    try {
      await repository.deferPickup(
        route,
        task,
        requestId: request,
        beforeMutation: () async {
          await _save(record);
          if (!_allowed(owner, canContinue)) {
            throw StateError('Execution paused before deferring the pickup.');
          }
          sending = true;
        },
      );
    } catch (error) {
      final rejected =
          !sending ||
          error is PostgrestException &&
              {
                'P0001',
                '42501',
                '23505',
                '23514',
                '40001',
                '40P01',
                '57014',
                '22023',
                '22P02',
              }.contains(error.code);
      record = _outcome(record, rejected ? 'rejected' : 'unknown');
      record = {
        ...record,
        'status': rejected ? 'paused' : 'uncertain',
        'message': rejected
            ? 'Pickup deferral rejected: ${routingError(error)}'
            : 'Pickup deferral outcome is unknown. Refresh to reconcile; no retry was sent.',
      };
      await _save(record);
      rethrow;
    }
    record = _outcome(record, 'confirmed');
    await _save({
      ...record,
      'status': 'paused',
      'message':
          'Pickup marked Needs reconciliation. Continue route explicitly when ready.',
    });
  });
}
