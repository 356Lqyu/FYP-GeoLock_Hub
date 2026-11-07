// Offline synthetic transport only; no real handover or DEV evidence.
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolock_hub_app/routing/ngo_routing_repository.dart';
import 'package:geolock_hub_app/routing/route_execution_controller.dart';

class Lane {
  final states = ['PLANNED', 'PLANNED', 'PLANNED'];
  final reconciliationNeeded = [false, false, false];
  final deferred = [false, false, false];
  final deferredRequests = <String?>[null, null, null];
  final deferRequestIds = <String>[];
  final writes = <String>[];
  String owner = 'ngo';
  int? rejectStart, lostStart, lostComplete, unsentComplete, unsentStart;
  int? lostDefer;
  int? lostDeferBeforeCommit;
  bool blocked = false, failRead = false;
  Completer<void>? startGate;
  void Function()? afterComplete;
  late final repo = NgoRoutingRepository(identity: () => owner, rpc: rpc);
  RouteExecutionController get controller => RouteExecutionController(repo);
  Map<String, dynamic> detail() {
    var current = states.indexWhere((s) => s == 'DISPATCHED');
    if (current < 0) {
      for (var i = 0; i < states.length; i++) {
        if (states[i] != 'COLLECTED' && !deferred[i]) {
          current = i;
          break;
        }
      }
    }
    return {
      'contract': 'geolock.ngo-routing.v1',
      'ngo_id': 'ngo',
      'route_id': 'route',
      'route_status': states.every((s) => s == 'PLANNED')
          ? 'AUTHORISED'
          : 'IN_PROGRESS',
      'authorization_confirmed': true,
      'dispatch_block_reason': blocked ? 'REMAINING_ROUTE_INFEASIBLE' : null,
      'next_executable_task_id': current < 0 ? null : 't$current',
      'awaiting_individual_reconciliation':
          current < 0 && deferred.any((value) => value),
      'can_close': current == -1,
      'stops': [
        for (var i = 0; i < 3; i++)
          {
            'task_id': 't$i',
            'claim_id': 'c$i',
            'task_status': states[i],
            'stop_order': i + 1,
            'can_start':
                !blocked &&
                !states.contains('DISPATCHED') &&
                current == i &&
                !deferred[i] &&
                !reconciliationNeeded[i],
            'can_complete': current == i && states[i] == 'DISPATCHED',
            'needs_reconciliation': reconciliationNeeded[i] || deferred[i],
            'can_defer':
                reconciliationNeeded[i] &&
                !deferred[i] &&
                !states.contains('DISPATCHED') &&
                states[i] == 'PLANNED',
            'deferred_for_reconciliation': deferred[i],
            'deferred_request_id': deferredRequests[i],
          },
      ],
    };
  }

  Future<Object?> rpc(String name, Map<String, dynamic> args) async {
    if (name == 'get_my_authorized_route') {
      if (failRead) throw TimeoutException('synthetic read failure');
      return detail();
    }
    if (name == 'defer_my_pickup_for_reconciliation') {
      final i = int.parse((args['p_claim'] as String).substring(1));
      writes.add('defer:$i');
      deferRequestIds.add(args['p_request'] as String);
      expect(reconciliationNeeded[i], isTrue);
      expect(states[i], 'PLANNED');
      if (lostDeferBeforeCommit == i) {
        lostDeferBeforeCommit = null;
        throw TimeoutException('synthetic timeout before commit');
      }
      deferred[i] = true;
      deferredRequests[i] = args['p_request'] as String;
      if (lostDefer == i) {
        throw TimeoutException('synthetic lost defer response');
      }
      return {'task_id': 't$i', 'status': 'DEFERRED'};
    }
    if (name == 'get_my_deferred_pickup_receipt') {
      final request = args['p_request'] as String;
      final index = deferredRequests.indexOf(request);
      return {
        'found': index >= 0,
        'request_id': request,
        if (index >= 0) 'route_id': 'route',
        if (index >= 0) 'task_id': 't$index',
      };
    }
    final i = int.parse((args['p_claim'] as String).substring(1));
    final prefs = await SharedPreferences.getInstance();
    final persisted =
        jsonDecode(prefs.getString('ngo_route_execution_ngo_route')!) as Map;
    expect(persisted['status'], 'sending');
    expect((persisted['attempt'] as Map)['task_id'], 't$i');
    expect((persisted['attempt'] as Map)['id'], isNotEmpty);
    if (name == 'start_pickup') {
      writes.add('start:$i');
      if (unsentStart == i) throw TimeoutException('synthetic unknown start');
      if (rejectStart == i) {
        throw const PostgrestException(
          message: 'REMAINING_ROUTE_INFEASIBLE',
          code: 'P0001',
        );
      }
      if (startGate != null) await startGate!.future;
      expect(states[i], 'PLANNED');
      states[i] = 'DISPATCHED';
      if (lostStart == i) {
        throw TimeoutException('synthetic lost start response');
      }
    } else {
      expect(name, 'complete_pickup');
      expect(args['p_handover_confirmed'], true);
      writes.add('complete:$i');
      if (unsentComplete == i) {
        throw TimeoutException('synthetic unknown completion');
      }
      expect(states[i], 'DISPATCHED');
      states[i] = 'COLLECTED';
      afterComplete?.call();
      if (lostComplete == i) {
        throw TimeoutException('synthetic lost completion response');
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> read() =>
      controller.reconcile('route', detail());
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a never-started expired middle stop can be deferred and later stops continue',
    () async {
      final l = Lane()..reconciliationNeeded[1] = true;
      await l.controller.startRoute('route');
      await l.controller.completeCurrent('route', 't0');
      expect(l.states, ['COLLECTED', 'PLANNED', 'PLANNED']);
      expect(l.detail()['next_executable_task_id'], 't1');

      await l.controller.deferForReconciliation('route', 't1');
      expect(l.deferred, [false, true, false]);
      expect(l.states, ['COLLECTED', 'PLANNED', 'PLANNED']);
      expect(l.writes, ['start:0', 'complete:0', 'defer:1']);

      await l.controller.startRoute('route');
      expect(l.writes.last, 'start:2');
      await l.controller.completeCurrent('route', 't2');
      expect(l.states, ['COLLECTED', 'PLANNED', 'COLLECTED']);
      expect((await l.read())['status'], 'awaiting_reconciliation');
      expect(
        l.writes.where((write) => write == 'start:1' || write == 'complete:1'),
        isEmpty,
      );
    },
  );

  test(
    'uncommitted uncertain deferral recovers with its original request ID',
    () async {
      final l = Lane()
        ..reconciliationNeeded[1] = true
        ..lostDeferBeforeCommit = 1;
      await l.controller.startRoute('route');
      await l.controller.completeCurrent('route', 't0');
      await expectLater(
        l.controller.deferForReconciliation('route', 't1'),
        throwsA(isA<TimeoutException>()),
      );
      expect((await l.read())['status'], 'retryable_same_request');
      expect(l.deferRequestIds, hasLength(1));
      final original = l.deferRequestIds.single;
      await l.controller.deferForReconciliation('route', 't1');
      expect(l.deferRequestIds, [original, original]);
      expect(l.deferred[1], isTrue);
    },
  );

  test(
    'lost deferral response reconciles by durable request and never retries',
    () async {
      final l = Lane()
        ..reconciliationNeeded[1] = true
        ..lostDefer = 1;
      await l.controller.startRoute('route');
      await l.controller.completeCurrent('route', 't0');
      await expectLater(
        l.controller.deferForReconciliation('route', 't1'),
        throwsA(isA<TimeoutException>()),
      );
      expect((await l.read())['status'], 'paused');
      expect(l.writes.where((write) => write == 'defer:1').length, 1);
      await l.controller.startRoute('route');
      expect(l.writes.where((write) => write == 'defer:1').length, 1);
    },
  );

  test(
    'unknown first-start response stays held when backend state is unchanged',
    () async {
      final l = Lane()..unsentStart = 0;
      await expectLater(
        l.controller.startRoute('route'),
        throwsA(isA<TimeoutException>()),
      );
      expect((await l.read())['status'], 'uncertain');
      await expectLater(l.controller.startRoute('route'), throwsStateError);
      expect(l.writes, ['start:0']);
      expect(l.states, ['PLANNED', 'PLANNED', 'PLANNED']);
    },
  );

  test(
    'one explicit start advances three protected stops and retains intent',
    () async {
      final l = Lane();
      await l.controller.startRoute('route');
      final intent = (await l.read())['intent_id'];
      for (var i = 0; i < 3; i++) {
        expect(l.states[i], 'DISPATCHED');
        await l.controller.completeCurrent('route', 't$i');
        expect((await l.read())['intent_id'], intent);
      }
      expect(l.states, ['COLLECTED', 'COLLECTED', 'COLLECTED']);
      expect(l.writes, [
        'start:0',
        'complete:0',
        'start:1',
        'complete:1',
        'start:2',
        'complete:2',
      ]);
      final record = await l.read();
      expect(record['status'], 'awaiting_depot');
      expect((record['history'] as List).length, 6);
      expect(
        l.detail()['can_close'],
        true,
      ); // Closure still requires its own UI consent/RPC.
    },
  );

  test(
    'duplicate taps and duplicate controller instances send only one start',
    () async {
      final l = Lane()..startGate = Completer<void>();
      final first = l.controller.startRoute('route');
      while (l.writes.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(l.controller.startRoute('route'), throwsStateError);
      l.startGate!.complete();
      await first;
      await l.controller.startRoute(
        'route',
      ); // Known dispatched state cannot start again.
      expect(l.writes, ['start:0']);
    },
  );

  test(
    'next start rejection preserves completed A; retry is explicit and same intent',
    () async {
      final l = Lane();
      await l.controller.startRoute('route');
      final intent = (await l.read())['intent_id'];
      l.rejectStart = 1;
      await expectLater(
        l.controller.completeCurrent('route', 't0'),
        throwsA(isA<PostgrestException>()),
      );
      expect(l.states, ['COLLECTED', 'PLANNED', 'PLANNED']);
      expect((await l.read())['status'], 'paused');
      expect(
        (await l.read())['message'],
        contains('Previous pickup completed'),
      );
      final before = List.of(l.writes);
      await l.read();
      expect(l.writes, before);
      l.rejectStart = null;
      await l.controller.startRoute('route');
      expect((await l.read())['intent_id'], intent);
      expect(l.writes, ['start:0', 'complete:0', 'start:1', 'start:1']);
      expect((await l.read())['history'], hasLength(4));
    },
  );

  test('blocked next permission never calls start B', () async {
    final l = Lane();
    await l.controller.startRoute('route');
    l.afterComplete = () => l.blocked = true;
    await l.controller.completeCurrent('route', 't0');
    expect(l.writes, ['start:0', 'complete:0']);
    expect((await l.read())['message'], contains('Next pickup not started'));
    expect((await l.read())['message'], contains('leases'));
  });

  test(
    'lost completion response reconciles collected A without auto-start on reopen',
    () async {
      final l = Lane();
      await l.controller.startRoute('route');
      l.lostComplete = 0;
      await expectLater(
        l.controller.completeCurrent('route', 't0'),
        throwsA(isA<TimeoutException>()),
      );
      expect(l.states[0], 'COLLECTED');
      expect((await l.read())['status'], 'paused');
      await l.controller.reconcile(
        'route',
        l.detail(),
      ); // New instance/page: reads only.
      expect(l.writes, ['start:0', 'complete:0']);
      await l.controller.startRoute('route');
      expect(l.writes, ['start:0', 'complete:0', 'start:1']);
    },
  );

  test(
    'unchanged state after uncertain completion cannot authorize any retry',
    () async {
      final l = Lane();
      await l.controller.startRoute('route');
      l.unsentComplete = 0;
      await expectLater(
        l.controller.completeCurrent('route', 't0'),
        throwsA(isA<TimeoutException>()),
      );
      expect((await l.read())['status'], 'uncertain');
      await expectLater(
        l.controller.completeCurrent('route', 't0'),
        throwsStateError,
      );
      await expectLater(l.controller.startRoute('route'), throwsStateError);
      expect(l.writes, ['start:0', 'complete:0']);
    },
  );

  test('lost next-start response is confirmed by read, never resent', () async {
    final l = Lane();
    await l.controller.startRoute('route');
    l.lostStart = 1;
    await expectLater(
      l.controller.completeCurrent('route', 't0'),
      throwsA(isA<TimeoutException>()),
    );
    expect(l.states, ['COLLECTED', 'DISPATCHED', 'PLANNED']);
    expect((await l.read())['status'], 'active');
    await l.read();
    expect(l.writes, ['start:0', 'complete:0', 'start:1']);
  });

  test(
    'reopening active route only reads; old manual start grants no auto-advance consent',
    () async {
      final l = Lane();
      l.states[0] = 'DISPATCHED';
      expect(await l.read(), isEmpty);
      await l.controller.completeCurrent('route', 't0');
      expect(l.writes, ['complete:0']);
      expect((await l.read())['intent_id'], isNull);
      await l.read();
      expect(l.writes, ['complete:0']);
      await l.controller.startRoute('route');
      expect(l.states[1], 'DISPATCHED');
    },
  );

  test('leaving/backgrounding after completion pauses next start', () async {
    final l = Lane();
    var visible = true;
    await l.controller.startRoute('route');
    l.afterComplete = () => visible = false;
    await l.controller.completeCurrent(
      'route',
      't0',
      canContinue: () => visible,
    );
    expect(l.writes, ['start:0', 'complete:0']);
    visible = true;
    await l.read();
    expect(l.writes, ['start:0', 'complete:0']);
  });

  test(
    'read failure after confirmed completion preserves A without starting B',
    () async {
      final l = Lane();
      await l.controller.startRoute('route');
      l.afterComplete = () => l.failRead = true;
      await expectLater(
        l.controller.completeCurrent('route', 't0'),
        throwsA(isA<TimeoutException>()),
      );
      expect(l.states[0], 'COLLECTED');
      expect(l.writes, ['start:0', 'complete:0']);
      l.failRead = false;
      expect((await l.read())['last_completed_task_id'], 't0');
      expect(l.writes, ['start:0', 'complete:0']);
    },
  );

  test(
    'out of order completion is rejected locally before any write',
    () async {
      final l = Lane();
      await l.controller.startRoute('route');
      await expectLater(
        l.controller.completeCurrent('route', 't1'),
        throwsStateError,
      );
      expect(l.writes, ['start:0']);
    },
  );

  test(
    'owner change after completion sends no next pickup and retains sending evidence',
    () async {
      final l = Lane();
      await l.controller.startRoute('route');
      l.afterComplete = () => l.owner = 'other';
      await expectLater(
        l.controller.completeCurrent('route', 't0'),
        throwsStateError,
      );
      expect(l.writes, ['start:0', 'complete:0']);
      l.owner = 'ngo';
      expect((await l.read())['status'], 'paused');
      expect(l.writes, ['start:0', 'complete:0']);
    },
  );
}
