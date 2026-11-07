import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'ngo_routing_repository.dart' show RpcCall, routingObject, routingRows;

/// Durable actor-scoped requests. Reads never retry a mutation automatically.
class ClaimCoordinationRepository {
  ClaimCoordinationRepository({required this.rpc, required this.identity});
  factory ClaimCoordinationRepository.live() {
    final c = Supabase.instance.client;
    return ClaimCoordinationRepository(
      rpc: (n, p) => c.rpc(n, params: p),
      identity: () => c.auth.currentUser?.id,
    );
  }
  final RpcCall rpc;
  final String? Function() identity;
  static final Set<String> _flights = {};
  static const _operations = {
    'submit_claim_reconciliation_v2',
    'resolve_my_claim_reconciliation',
    'review_my_claim_reconciliation',
    'confirm_my_route_depot_checkpoint',
  };
  String _key(String owner, String subject) =>
      'claim_coordination_${owner}_$subject';

  Future<Map<String, dynamic>> _read(
    String name,
    Map<String, dynamic> params,
  ) async {
    final owner = identity();
    if (owner == null) throw StateError('Sign in to review reconciliation.');
    final value = routingObject(await rpc(name, params));
    if (identity() != owner) throw StateError('Account changed.');
    return value;
  }

  Future<List<Map<String, dynamic>>> donation(String id) async => routingRows(
    (await _read('get_my_donation_coordination', {
      'p_donation': id,
    }))['contexts'],
  );

  Future<Map<String, dynamic>> read(String claim) async {
    final row = await _read('get_my_claim_coordination', {'p_claim': claim});
    if (row['claim_id'] != claim ||
        row['contract'] != 'geolock.claim-coordination.v2') {
      throw StateError('Claim association changed.');
    }
    return row;
  }

  Future<Map<String, dynamic>?> pending(String subject) async {
    final owner = identity();
    if (owner == null) return null;
    final prefs = await SharedPreferences.getInstance();
    if (identity() != owner) throw StateError('Account changed.');
    final raw = prefs.getString(_key(owner, subject));
    if (raw == null) return null;
    final saved = routingObject(jsonDecode(raw));
    final params = routingObject(saved['params']);
    if (!_operations.contains(saved['name']) ||
        params['p_request'] is! String ||
        (params['p_claim'] != subject && params['p_route'] != subject)) {
      throw StateError(
        'Saved reconciliation request is invalid. No operation sent.',
      );
    }
    return saved;
  }

  Future<void> discardUnsent(String subject) async {
    final owner = identity();
    final saved = await pending(subject);
    if (owner == null || saved == null) return;
    final receipt = await _read('get_my_coordination_receipt', {
      'p_request': saved['params']['p_request'],
    });
    if (receipt['found'] != false) {
      throw StateError('A committed request must be recovered, not discarded.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (identity() != owner) throw StateError('Account changed.');
    await prefs.remove(_key(owner, subject));
  }

  Future<Map<String, dynamic>> send(
    String subject,
    String name,
    Map<String, dynamic> params,
  ) async {
    if (!_operations.contains(name) ||
        (params['p_claim'] != subject && params['p_route'] != subject)) {
      throw StateError('Unsupported coordination operation.');
    }
    final owner = identity();
    if (owner == null) throw StateError('Sign in before submitting.');
    final key = _key(owner, subject);
    if (!_flights.add(key)) {
      throw StateError('A request is already in progress.');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      var saved = await pending(subject);
      if (saved == null) {
        saved = {
          'name': name,
          'params': {...params, 'p_request': const Uuid().v4()},
        };
        if (!await prefs.setString(key, jsonEncode(saved))) {
          throw StateError('Unable to preserve request.');
        }
      } else if (name != saved['name'] ||
          jsonEncode(params) !=
              jsonEncode(
                Map<String, dynamic>.from(saved['params'])..remove('p_request'),
              )) {
        throw StateError(
          'Recover or discard the saved request before choosing another action.',
        );
      }
      if (identity() != owner) throw StateError('Account changed.');
      final request = routingObject(saved['params']);
      final receipt = await _read('get_my_coordination_receipt', {
        'p_request': request['p_request'],
      });
      if (receipt['request_id'] != request['p_request']) {
        throw StateError('Receipt identity changed.');
      }
      final Map<String, dynamic> result;
      if (receipt['found'] == true) {
        result = routingObject(receipt['result']);
      } else if (receipt['found'] == false) {
        result = routingObject(await rpc(saved['name'] as String, request));
      } else {
        throw StateError('Receipt is not confirmed. Request retained.');
      }
      if (identity() != owner ||
          result['outcome'] == null ||
          (result['claim_id'] != subject && result['route_id'] != subject)) {
        throw StateError(
          'Outcome ownership or association changed. Request retained.',
        );
      }
      await prefs.remove(key);
      return result;
    } finally {
      _flights.remove(key);
    }
  }

  Future<Map<String, dynamic>> recover(String subject) async {
    final saved = await pending(subject);
    if (saved == null) throw StateError('No saved request.');
    return send(
      subject,
      saved['name'] as String,
      Map<String, dynamic>.from(saved['params'])..remove('p_request'),
    );
  }
}

String claimCoordinationMessage(Map<String, dynamic> row) {
  if (row['case_status'] == 'RESOLVED_RELEASED') {
    return 'Resolved — no handover. Claim released.';
  }
  if (row['case_status'] == 'RESOLVED_COLLECTED') {
    return 'Resolved — handover confirmed. Collected.';
  }
  if (row['review_waiting'] == true) {
    return 'Awaiting counterpart acceptance of joint review.';
  }
  if (row['blocker'] == 'PARTY_EVIDENCE_CONFLICT') {
    return 'Disagreement unresolved — contact your counterpart and request joint review.';
  }
  if (row['blocker'] == 'AWAITING_COUNTERPART') return 'Awaiting Counterpart';
  if (row['can_resolve'] == true) return 'Matching statements can be resolved.';
  return switch (row['blocker']) {
    'JOINT_REVIEW_ACCEPTANCE_PENDING' =>
      'Joint review is awaiting counterpart acceptance.',
    'REVIEW_CONTEXT_CHANGED' =>
      'Pickup details changed. Refresh and arrange a new joint review.',
    'RECORDED_COLLECTION_OR_SOURCE_CONFLICT' ||
    'HANDOVER_SOURCE_STATE_CONFLICT' ||
    'BATCH_CUSTODY_CONFLICT' =>
      'Recorded collection or source details conflict with these statements. Custody remains protected.',
    'UNRESOLVED_CUSTODY_OR_INCIDENT' =>
      'A custody incident remains unresolved. No release or collection can be confirmed.',
    'LEASE_NOT_EXPIRED' =>
      'The lease has not expired. Use the current pickup workflow.',
    'AUTHORITATIVE_ASSOCIATION_MISSING' ||
    'SOURCE_SET_MISSING' ||
    'ROUTE_BINDING_DRIFT' ||
    'MANAGED_DISPATCH_EVIDENCE_REQUIRED' =>
      'Pickup records are incomplete or inconsistent. Custody remains protected.',
    _ => 'This pickup needs further evidence before it can be resolved.',
  };
}

/// Shared donor, NGO and hub participant flow; no administrator dependency.
class ClaimCoordinationPanel extends StatefulWidget {
  const ClaimCoordinationPanel({
    super.key,
    this.claimId,
    this.donationId,
    this.repository,
    this.onChanged,
  });
  final String? claimId, donationId;
  final ClaimCoordinationRepository? repository;
  final Future<void> Function()? onChanged;
  @override
  State<ClaimCoordinationPanel> createState() => _ClaimCoordinationPanelState();
}

class _ClaimCoordinationPanelState extends State<ClaimCoordinationPanel> {
  ClaimCoordinationRepository? _repo;
  late Future<List<Map<String, dynamic>>> _rows = _load();
  bool _busy = false;
  String? _error;
  final Map<String, bool> _pending = {};
  @override
  void didUpdateWidget(covariant ClaimCoordinationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.claimId != widget.claimId ||
        oldWidget.donationId != widget.donationId ||
        oldWidget.repository != widget.repository) {
      _repo = widget.repository;
      _pending.clear();
      _error = null;
      _rows = _load();
    }
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final repo = _repo ??=
        widget.repository ?? ClaimCoordinationRepository.live();
    final owner = repo.identity();
    final rows = widget.claimId != null
        ? [await repo.read(widget.claimId!)]
        : await repo.donation(widget.donationId!);
    for (final row in rows) {
      _pending[row['claim_id'] as String] =
          await repo.pending(row['claim_id'] as String) != null;
      row['_viewer'] = owner;
    }
    if (repo.identity() != owner) throw StateError('Account changed.');
    return rows;
  }

  Future<void> _act(
    Map<String, dynamic> row,
    String action, [
    bool? handover,
  ]) async {
    if (_busy) return;
    final owner = _repo?.identity();
    if (owner == null || row['_viewer'] != owner) {
      setState(() {
        _error = 'Account changed. Refresh reconciliation.';
        _rows = _load();
      });
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          action == 'SUBMIT'
              ? 'Confirm your handover statement'
              : action == 'RESOLVE'
              ? 'Resolve matching statements?'
              : 'Confirm joint review action',
        ),
        content: Text(
          action == 'SUBMIT'
              ? (handover == true
                    ? 'Goods were handed over to the NGO.'
                    : 'No goods were handed over. Do not use this to reverse a recorded collection.')
              : 'Previous evidence and receipts will remain in history. PostgreSQL will recheck your authority and the current evidence version.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_repo?.identity() != owner) {
      setState(() {
        _error = 'Account changed. No request sent.';
        _rows = _load();
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = row['claim_id'] as String;
    try {
      if (action == 'RECOVER') {
        await _repo!.recover(id);
      } else if (action == 'DISCARD') {
        await _repo!.discardUnsent(id);
      } else {
        final fresh = await _repo!.read(id);
        if (_repo!.identity() != owner) {
          throw StateError('Account changed. No request sent.');
        }
        if (fresh['evidence_version'] != row['evidence_version']) {
          throw StateError('Version changed. Refresh before choosing again.');
        }
        final params = <String, dynamic>{'p_claim': id};
        final String rpc;
        if (action == 'SUBMIT') {
          if (fresh['can_submit'] != true) {
            throw StateError('Statement is no longer authorized.');
          }
          rpc = 'submit_claim_reconciliation_v2';
          params.addAll({
            'p_handover_confirmed': handover,
            'p_expected_round': fresh['evidence_round'],
            'p_expected_version': fresh['evidence_version'],
          });
        } else if (action == 'RESOLVE') {
          if (fresh['can_resolve'] != true) {
            throw StateError('Matching resolution is no longer authorized.');
          }
          rpc = 'resolve_my_claim_reconciliation';
        } else {
          if (fresh[action == 'REQUEST'
                  ? 'can_request_review'
                  : 'can_accept_review'] !=
              true) {
            throw StateError('Joint review action is no longer authorized.');
          }
          rpc = 'review_my_claim_reconciliation';
          params.addAll({
            'p_action': action,
            'p_expected_version': fresh['evidence_version'],
          });
        }
        await _repo!.send(id, rpc, params);
      }
      await widget.onChanged?.call();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _rows = _load();
        });
      }
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _rows,
    builder: (context, snap) {
      if (snap.hasError) {
        return Column(
          children: [
            const Text(
              'Reconciliation backend unavailable. Custody remains protected.',
            ),
            TextButton(
              onPressed: () => setState(() => _rows = _load()),
              child: const Text('Refresh reconciliation'),
            ),
          ],
        );
      }
      if (!snap.hasData) return const LinearProgressIndicator();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null) Text(_error!),
          for (final row in snap.data!) ...[
            Text(claimCoordinationMessage(row)),
            Text('Evidence round ${row['evidence_round']}'),
            for (final s in routingRows(row['statements']))
              Text(
                'Round ${s['round']} · ${s['participant']}: ${s['handover_confirmed'] == true ? 'Handover' : 'No handover'}',
              ),
            if (_pending[row['claim_id']] == true)
              Wrap(
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _act(row, 'RECOVER'),
                    child: const Text('Recover saved request'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _act(row, 'DISCARD'),
                    child: const Text('Discard uncommitted request'),
                  ),
                ],
              )
            else
              Wrap(
                spacing: 8,
                children: [
                  if (row['can_submit'] == true) ...[
                    FilledButton(
                      onPressed: _busy ? null : () => _act(row, 'SUBMIT', true),
                      child: const Text('Handover'),
                    ),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _act(row, 'SUBMIT', false),
                      child: const Text('No Handover'),
                    ),
                  ],
                  if (row['can_resolve'] == true)
                    FilledButton(
                      onPressed: _busy ? null : () => _act(row, 'RESOLVE'),
                      child: const Text('Resolve Matching Statements'),
                    ),
                  if (row['can_request_review'] == true)
                    TextButton(
                      onPressed: _busy ? null : () => _act(row, 'REQUEST'),
                      child: const Text('Request joint review'),
                    ),
                  if (row['can_accept_review'] == true) ...[
                    TextButton(
                      onPressed: _busy ? null : () => _act(row, 'ACCEPT'),
                      child: const Text('Accept joint review'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _act(row, 'DECLINE'),
                      child: const Text('Decline joint review'),
                    ),
                  ],
                ],
              ),
          ],
          if (snap.data!.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _rows = _load()),
              child: const Text('Refresh reconciliation'),
            ),
        ],
      );
    },
  );
}

class VehicleDepotCheckpoint extends StatefulWidget {
  const VehicleDepotCheckpoint({
    super.key,
    required this.routeId,
    required this.requiredCheckpoint,
    required this.authorized,
    required this.repository,
    required this.readRoute,
    required this.onChanged,
  });
  final String routeId;
  final bool requiredCheckpoint, authorized;
  final ClaimCoordinationRepository repository;
  final Future<Map<String, dynamic>> Function() readRoute;
  final Future<void> Function() onChanged;
  @override
  State<VehicleDepotCheckpoint> createState() => _VehicleDepotCheckpointState();
}

class _VehicleDepotCheckpointState extends State<VehicleDepotCheckpoint> {
  bool busy = false, saved = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _pending();
  }

  Future<void> _pending() async {
    try {
      final value = await widget.repository.pending(widget.routeId);
      if (mounted) setState(() => saved = value != null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _send() async {
    final owner = widget.repository.identity();
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Confirm vehicle location'),
        content: const Text(
          'The vehicle is back at its registered NGO depot and under NGO control. This does not confirm goods return or close the route.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.repository.identity() != owner) {
        throw StateError('Account changed.');
      }
      if (saved) {
        await widget.repository.recover(widget.routeId);
      } else {
        final row = await widget.readRoute();
        if (row['can_confirm_depot_checkpoint'] != true ||
            row['authorization_confirmed'] != true ||
            widget.repository.identity() != owner) {
          throw StateError(
            'Checkpoint is no longer authorized. Refresh route.',
          );
        }
        await widget.repository.send(
          widget.routeId,
          'confirm_my_route_depot_checkpoint',
          {'p_route': widget.routeId, 'p_confirmed': true},
        );
      }
      await widget.onChanged();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await _pending();
      }
    }
  }

  @override
  Widget build(BuildContext context) => !widget.requiredCheckpoint && !saved
      ? const SizedBox.shrink()
      : Column(
          children: [
            const Text(
              'Vehicle origin needs confirmation before continuing pickup work.',
            ),
            if (error != null) Text(error!),
            FilledButton(
              onPressed: !busy && widget.authorized ? _send : null,
              child: Text(
                saved
                    ? 'Recover vehicle checkpoint request'
                    : 'Confirm vehicle at registered depot',
              ),
            ),
            if (saved)
              TextButton(
                onPressed: !busy && widget.authorized
                    ? () async {
                        setState(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await widget.repository.discardUnsent(widget.routeId);
                          await widget.onChanged();
                        } catch (e) {
                          if (mounted) setState(() => error = e.toString());
                        } finally {
                          if (mounted) {
                            setState(() => busy = false);
                            await _pending();
                          }
                        }
                      }
                    : null,
                child: const Text('Discard uncommitted checkpoint request'),
              ),
          ],
        );
}
