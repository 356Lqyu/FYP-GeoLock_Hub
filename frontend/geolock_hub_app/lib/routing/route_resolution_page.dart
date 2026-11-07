import 'package:flutter/material.dart';
import 'ngo_routing_repository.dart' show routingObject, routingRows;
import 'route_resolution_repository.dart';

/// Participant inbox: server-scoped reads only, never opens a case by mutation.
class RouteResolutionInboxPage extends StatefulWidget {
  const RouteResolutionInboxPage({super.key, this.repository});
  final RouteResolutionRepository? repository;
  @override
  State<RouteResolutionInboxPage> createState() =>
      _RouteResolutionInboxPageState();
}

class _RouteResolutionInboxPageState extends State<RouteResolutionInboxPage> {
  late final repo = widget.repository ?? RouteResolutionRepository.live();
  late Future<List<Map<String, dynamic>>> rows = repo.listCases();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Route resolution cases'),
      actions: [
        IconButton(
          tooltip: 'Refresh cases',
          icon: const Icon(Icons.refresh),
          onPressed: () {
            final next = repo.listCases();
            setState(() {
              rows = next;
            });
          },
        ),
      ],
    ),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: rows,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text(resolutionError(snapshot.error!)));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.data!.isEmpty) {
          return Center(
            child: Text(
              repo.enabled
                  ? 'No accessible route resolution cases. This does not prove that no claim reconciliation holds exist.'
                  : 'Reconciliation backend unavailable — reporting not activated. Existing holds remain protected.',
            ),
          );
        }
        return ListView(
          children: [
            for (final item in snapshot.data!)
              ListTile(
                title: Text('Route resolution · ${item['status']}'),
                subtitle: SelectableText('${item['route_id']}'),
                onTap: item['route_id'] is String
                    ? () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RouteResolutionPage(
                            routeId: item['route_id'] as String,
                            repository: repo,
                          ),
                        ),
                      )
                    : null,
              ),
          ],
        );
      },
    ),
  );
}

/// Default-disabled local prototype; opening this page only performs reads.
class RouteResolutionPage extends StatefulWidget {
  const RouteResolutionPage({
    super.key,
    required this.routeId,
    this.repository,
    this.pickupDescriptions = const {},
    this.donorDonationId,
  });
  final String routeId;
  final RouteResolutionRepository? repository;
  final Map<String, Map<String, dynamic>> pickupDescriptions;
  final String? donorDonationId;
  @override
  State<RouteResolutionPage> createState() => _RouteResolutionPageState();
}

class _RouteResolutionPageState extends State<RouteResolutionPage> {
  late final repo = widget.repository ?? RouteResolutionRepository.live();
  Map<String, dynamic>? state;
  bool busy = true, uncertain = false;
  bool _confirming = false;
  String? error;
  String? notice;
  String? _viewer;
  Map<String, dynamic>? _donorBinding;
  String? _donorTitle;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<Map<String, dynamic>?> _reload() async {
    Map<String, dynamic>? recovered;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final viewer = repo.identity;
      if (repo.enabled) {
        recovered = await repo.reconcile(
          widget.routeId,
        ); // Receipt SELECT only, never retries a write.
      }
      Map<String, dynamic> value;
      Map<String, dynamic>? donorBinding;
      String? donorTitle;
      if (widget.donorDonationId != null) {
        final donor = await repo.donorContext(widget.donorDonationId!);
        donorTitle = donor['title'] as String?;
        final matches = routingRows(
          donor['contexts'] ?? [],
        ).where((c) => c['route_id'] == widget.routeId).toList();
        final active = actionableDonorContext(donor);
        if (matches.length == 1 && matches.single['case_id'] is String) {
          final binding = matches.single;
          value = await repo.read(widget.routeId);
          if (value['is_owner'] != false ||
              value['case_id'] != binding['case_id'] ||
              value['version'] != binding['case_version']) {
            throw ResolutionVersionConflict();
          }
          final items = routingRows(value['items'])
              .where(
                (i) =>
                    i['task_id'] == binding['task_id'] &&
                    i['claim_id'] == binding['claim_id'],
              )
              .toList();
          if (items.length != 1) {
            throw StateError('Protected pickup association changed.');
          }
          value = {...value, 'items': items};
          if (active != null &&
              active['route_id'] == widget.routeId &&
              active['task_id'] == binding['task_id']) {
            donorBinding = binding;
          }
        } else {
          value = {
            'enabled': false,
            'is_owner': false,
            'status': donor['status'] == 'DISABLED'
                ? 'DISABLED'
                : 'DONOR_ASSOCIATION_UNAVAILABLE',
          };
        }
      } else {
        value = await repo.read(widget.routeId);
      }
      final pending = repo.enabled
          ? await repo.pending(widget.routeId)
          : <String, dynamic>{};
      if (repo.identity != viewer) throw StateError('Account changed.');
      if (mounted) {
        setState(() {
          state = value;
          _viewer = viewer;
          _donorBinding = donorBinding;
          _donorTitle = donorTitle;
          uncertain = pending.isNotEmpty;
          if (recovered != null) {
            notice = _recordedNotice(recovered, recovered: true);
          }
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = resolutionError(failure);
          state = null;
          _donorBinding = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    return recovered;
  }

  String _recordedNotice(
    Map<String, dynamic> result, {
    bool recovered = false,
  }) {
    final status = result['status'] ?? result['outcome'];
    final suffix = status is String ? ' Status: $status.' : '';
    return recovered
        ? 'Saved statement confirmed by its protected receipt.$suffix'
        : 'Statement recorded by the protected service.$suffix';
  }

  bool _allows(Map<String, dynamic> item, String assertion) {
    if (state?['is_owner'] == true) return true;
    final binding = _donorBinding;
    return binding != null &&
        binding['task_id'] == item['task_id'] &&
        (binding['allowed_assertions'] as List).contains(assertion);
  }

  Future<Object?> _submit(Map<String, dynamic> item, String assertion) =>
      widget.donorDonationId == null
      ? repo.submit(
          widget.routeId,
          item['task_id'] as String,
          assertion,
          expectedVersion: state!['version'] as int,
        )
      : repo.submitDonor(widget.donorDonationId!, _donorBinding!, assertion);

  String? _sourceType(Map<String, dynamic> item) {
    // The donor reader is DIRECT_DONATION-only. NGO source types come from
    // protected route stops; absent metadata is never guessed from a title/state.
    if (widget.donorDonationId != null) return 'DIRECT_DONATION';
    final type = widget.pickupDescriptions[item['task_id']]?['source_type'];
    return type is String ? type : null;
  }

  String _sourceName(Map<String, dynamic> item) => switch (_sourceType(item)) {
    'DIRECT_DONATION' => 'donor',
    'HUB_BATCH' => 'community hub',
    _ => 'collection source',
  };

  String _sourcePossession(Map<String, dynamic> item) =>
      _sourceType(item) == 'HUB_BATCH'
      ? 'at the community hub'
      : 'with the ${_sourceName(item)}';

  Future<void> _confirm(
    String title,
    Future<Object?> Function() action, {
    String? explanation,
  }) async {
    if (busy ||
        _confirming ||
        uncertain ||
        state?['enabled'] != true ||
        _viewer == null ||
        repo.identity != _viewer) {
      return;
    }
    // The dialog is also part of the in-flight action; double taps cannot open
    // a second submission. Keep the viewer pinned across the confirmation.
    setState(() => _confirming = true);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(
          explanation ??
              'Submit only accurate custody evidence. This does not release a claim or vehicle. No action will be retried automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm statement'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _confirming = false);
    if (accepted != true || repo.identity != _viewer) {
      await _reload();
      return;
    }
    setState(() => busy = true);
    String? submissionError;
    Map<String, dynamic>? submitted;
    try {
      final result = await action();
      if (result is Map) submitted = routingObject(result);
    } catch (failure) {
      submissionError = resolutionError(failure);
    }
    final recovered = mounted ? await _reload() : null;
    if (!mounted) return;
    final confirmed = recovered ?? submitted;
    if (confirmed != null) {
      final message = _recordedNotice(confirmed, recovered: recovered != null);
      setState(() {
        notice = message;
        error = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } else if (submissionError != null) {
      final saved = await repo.pending(widget.routeId);
      if (!mounted) return;
      setState(() {
        error = saved.isNotEmpty
            ? 'No receipt is confirmed yet. The original request is saved; refresh to check it. Do not submit a replacement. $submissionError'
            : submissionError;
      });
    }
  }

  bool _alreadyRecorded(Map<String, dynamic> item, String assertion) =>
      item['my_assertion'] == assertion;

  @override
  Widget build(BuildContext context) {
    final enabled =
        !busy &&
        !_confirming &&
        !uncertain &&
        state?['enabled'] == true &&
        _viewer != null &&
        _viewer == repo.identity;
    final reported = state?['case_id'] is String;
    final terminal = state?['status'] == 'RESOLVED';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reconciliation details'),
        actions: [
          IconButton(
            onPressed: busy ? null : _reload,
            tooltip: 'Refresh resolution',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          if (notice != null) Semantics(liveRegion: true, child: Text(notice!)),
          if (state?['status'] == 'DISABLED')
            const Text('Route resolution is not activated.'),
          if (state?['enabled'] == false)
            const Text(
              'Reconciliation reporting unavailable. Existing holds remain protected.',
            ),
          if (state?['simulation'] == true)
            const Text(
              'Synthetic DEV evidence — no physical handover is implied.',
            ),
          if (uncertain)
            const Text(
              'Resolution outcome needs attention. Refresh checks the same saved request without retrying it.',
            ),
          Text(resolutionStatusLabel(state)),
          const Text(
            'This screen is retained for legacy route cases only. New custody questions belong to individual claim reconciliation.',
          ),
          if (!reported)
            const Text(
              'No legacy route case exists for this route. Use the individual claim screen for custody statements.',
            ),
          if (reported && !terminal) ...[
            if (state?['is_owner'] != true && _donorBinding == null)
              const Text(
                'Donation-specific confirmation unavailable: no uniquely actionable protected donation association is confirmed. Do not guess which goods a task represents.',
              ),
            for (final item in routingRows(state?['items'] ?? []))
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _donorTitle ??
                            widget.pickupDescriptions[item['task_id']]?['title']
                                ?.toString() ??
                            'Pickup name unavailable',
                      ),
                      Text(
                        'Pickup state when reported: ${item['initial_class']}',
                      ),
                      Text(
                        'My statement: ${custodyLabel(item['my_assertion'])}',
                      ),
                      Text('NGO: ${custodyLabel(item['ngo_assertion'])}'),
                      Text(
                        '${_sourceType(item) == 'HUB_BATCH'
                            ? 'Hub'
                            : _sourceType(item) == 'DIRECT_DONATION'
                            ? 'Donor'
                            : 'Source'}: ${custodyLabel(item['source_assertion'])}',
                      ),
                      if (item['source_assertion'] == null)
                        Text('Awaiting ${_sourceName(item)} confirmation'),
                      Text(
                        state?['is_owner'] == true
                            ? 'Has your NGO collected this donation?'
                            : 'Has the NGO collected this donation?',
                      ),
                      Text(
                        'Collected: the NGO received the goods from the ${_sourceName(item)}.\n'
                        'Not Collected: the goods remain ${_sourcePossession(item)}.',
                      ),
                      if (_sourceType(item) == 'HUB_BATCH')
                        const Text(
                          'This pickup represents a complete hub batch. Confirm only if your answer is true for the entire batch.',
                        ),
                      const Text(
                        'Choose only what you can truthfully confirm. No answer is preselected. If neither answer is accurate or you are unsure, do not submit; request authorized review. Not Collected is not an unsure answer. Changes append evidence and may require manual review.',
                      ),
                      if (item['my_assertion'] != null)
                        Text(
                          'Your latest statement is recorded: ${custodyLabel(item['my_assertion'])}. The same statement cannot be submitted again; choose another only to correct it truthfully.',
                        ),
                      OutlinedButton(
                        onPressed:
                            enabled &&
                                _allows(item, 'HANDOVER_TO_NGO_CONFIRMED') &&
                                !_alreadyRecorded(
                                  item,
                                  'HANDOVER_TO_NGO_CONFIRMED',
                                ) &&
                                item['initial_class'] != 'NEVER_STARTED' &&
                                (item['initial_class'] == 'DISPATCHED' ||
                                    widget.donorDonationId != null)
                            ? () => _confirm(
                                'Record Collected?',
                                () =>
                                    _submit(item, 'HANDOVER_TO_NGO_CONFIRMED'),
                                explanation:
                                    'Confirm that the NGO received the goods from the ${_sourceName(item)}${_sourceType(item) == 'HUB_BATCH' ? ' for the entire batch' : ''}. '
                                    'The protected backend may record collection when its checks pass. This does not close the route or release its vehicle. No action will be retried automatically.',
                              )
                            : null,
                        child: const Text('Collected'),
                      ),
                      OutlinedButton(
                        onPressed:
                            enabled &&
                                _allows(
                                  item,
                                  'NO_HANDOVER_SOURCE_RETAINS_GOODS',
                                ) &&
                                !_alreadyRecorded(
                                  item,
                                  'NO_HANDOVER_SOURCE_RETAINS_GOODS',
                                ) &&
                                item['initial_class'] != 'COLLECTED'
                            ? () => _confirm(
                                'Record Not Collected?',
                                () => _submit(
                                  item,
                                  'NO_HANDOVER_SOURCE_RETAINS_GOODS',
                                ),
                                explanation:
                                    'Confirm that the goods remain ${_sourcePossession(item)}${_sourceType(item) == 'HUB_BATCH' ? ' for the entire batch' : ''}. '
                                    'This is not an unverified or unknown-custody answer. This statement does not release a claim, donation or vehicle. No action will be retried automatically.',
                              )
                            : null,
                        child: const Text('Not Collected'),
                      ),
                      if (item['initial_class'] == 'NEVER_STARTED')
                        const Text(
                          'Collected is not accepted for a never-started pickup. If handover occurred, request authorized review; do not choose another statement unless it is truthful.',
                        ),
                    ],
                  ),
                ),
              ),
            if (state?['is_owner'] == true)
              OutlinedButton(
                onPressed: enabled && state?['is_owner'] == true
                    ? () => _confirm(
                        'Confirm vehicle at NGO depot and collected goods accounted for?',
                        () => repo.submit(
                          widget.routeId,
                          null,
                          'VEHICLE_RETURNED_TO_NGO_CONTROL',
                          expectedVersion: state!['version'] as int,
                        ),
                      )
                    : null,
                child: const Text(
                  'Vehicle and collected goods accounted for at depot',
                ),
              ),
            if (state?['is_owner'] == true)
              Text(
                state?['vehicle_confirmed'] == true
                    ? 'Vehicle accountability: confirmed by your recorded statement'
                    : 'Vehicle accountability: statement not provided',
              ),
          ],
          if (terminal) ...[
            const Text(
              'The backend confirms resolution. Refresh routes and claims for their authoritative final states. Reopened listings remain subject to normal discovery eligibility.',
            ),
            const Text(
              'This resolution is terminal. A new concern is recorded as a linked incident; it cannot reverse custody or release records.',
            ),
            for (final item in routingRows(state?['items'] ?? []))
              OutlinedButton(
                onPressed: enabled && state?['is_owner'] == true
                    ? () => _confirm(
                        'Record a concern about this resolved pickup?',
                        () => repo.incident(
                          widget.routeId,
                          item['task_id'] as String,
                        ),
                      )
                    : null,
                child: Text('Report concern · ${item['task_id']}'),
              ),
          ],
          const Text(
            'Finalization requires the restricted operator and all protected checks. It is not an NGO action.',
          ),
          ExpansionTile(
            title: const Text('Reconciliation diagnostics'),
            children: [
              SelectableText('Route: ${widget.routeId}'),
              SelectableText('Case: ${state?['case_id'] ?? 'Unavailable'}'),
              Text('Version: ${state?['version'] ?? 'Unavailable'}'),
              for (final item in routingRows(state?['items'] ?? []))
                SelectableText(
                  'Task: ${item['task_id']} · Claim: ${item['claim_id']} · Initial state: ${item['initial_class']}',
                ),
            ],
          ),
        ],
      ),
    );
  }
}
