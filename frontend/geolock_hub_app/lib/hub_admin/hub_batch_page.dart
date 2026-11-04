// Tick stored donations of one category and publish them as one listing.
import 'dart:async';

import 'package:flutter/material.dart';

import 'hub_admin_controller.dart';
import 'hub_service.dart';
import 'hub_widgets.dart';

// Shown before the first server check; the server sends the real limits.
const _defaultMin = 3;
const _defaultMax = 5;
const _defaultMaxKg = 30.0;

class DonationBatchPage extends StatefulWidget {
  final HubAdminController controller;
  final String? initialCategory;

  const DonationBatchPage({
    super.key,
    required this.controller,
    this.initialCategory,
  });

  @override
  State<DonationBatchPage> createState() => _DonationBatchPageState();
}

class _DonationBatchPageState extends State<DonationBatchPage> {
  late Future<List<HubStoredDonation>> _stock = _load();
  final List<String> _selected = [];
  String? _category;
  HubBatchCheck? _check;
  bool _checking = false;
  bool _publishing = false;
  int _checkVersion = 0;
  Timer? _debounce;

  String get _hubId => widget.controller.hubId;

  Future<List<HubStoredDonation>> _load() async {
    final rows = await HubService.inventory(_hubId);
    final stored = rows.where((r) => r.stored && r.singleCategory).toList();
    if (_category == null && stored.isNotEmpty) {
      final counts = <String, int>{};
      for (final r in stored) {
        counts[r.categoryName] = (counts[r.categoryName] ?? 0) + 1;
      }
      final initial = widget.initialCategory;
      _category = initial != null && counts.containsKey(initial)
          ? initial
          : (counts.entries.toList()
                  ..sort((a, b) => b.value.compareTo(a.value)))
                .first
                .key;
    }
    return stored;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _scheduleCheck() {
    _debounce?.cancel();
    _check = null;
    if (_selected.isEmpty) {
      _checkVersion++;
      _checking = false;
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), _runCheck);
  }

  void _toggle(String id, bool on) {
    setState(() {
      if (on) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
      _scheduleCheck();
    });
  }

  void _chooseCategory(String category) {
    if (category == _category) return;
    setState(() {
      _category = category;
      _selected.clear();
      _scheduleCheck();
    });
  }

  Future<void> _runCheck() async {
    final version = ++_checkVersion;
    setState(() => _checking = true);
    HubBatchCheck result;
    try {
      result = await HubService.checkBatch(_hubId, List.of(_selected));
    } catch (error) {
      result = HubBatchCheck.failed(hubErrorMessage(error));
    }
    if (!mounted || version != _checkVersion) return;
    setState(() {
      _check = result;
      _checking = false;
    });
  }

  Future<void> _publish() async {
    final check = _check!;
    final ok = await hubConfirm(
      context,
      title: 'Publish this batch?',
      message:
          '${check.donationCount} ${check.categoryName ?? ''} donations '
          '(${hubKg(check.totalKg)}) become one listing that NGOs within 20 km by road '
          'can claim. The batch cannot be changed afterwards.',
      confirmLabel: 'Publish',
    );
    if (!ok || !mounted) return;
    setState(() => _publishing = true);
    try {
      final batchId = await HubService.publishBatch(_hubId, List.of(_selected));
      if (mounted) Navigator.pop(context, batchId);
    } catch (error) {
      if (!mounted) return;
      hubToast(context, 'Batch not published: ${hubErrorMessage(error)}');
      setState(() {
        _stock = _load();
        _selected.clear();
        _check = null;
      });
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Build a batch')),
    body: FutureBuilder<List<HubStoredDonation>>(
      future: _stock,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return HubErrorState(
            error: snapshot.error!,
            onRetry: () => setState(() => _stock = _load()),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final all = snapshot.data!;
        if (all.isEmpty) {
          return const HubEmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'No stored donations to batch',
            message:
                'Receive drop-offs first. Donations with mixed categories '
                'cannot join a one-category batch.',
          );
        }
        final groups = <String, List<HubStoredDonation>>{};
        for (final r in all) {
          groups.putIfAbsent(r.categoryName, () => []).add(r);
        }
        final names = groups.keys.toList()..sort();
        final rows = groups[_category] ?? const <HubStoredDonation>[];
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  const _StepHeader(
                    number: 1,
                    title: 'Choose one category',
                    subtitle: 'A batch holds one category only.',
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final n in names)
                        ChoiceChip(
                          label: Text(
                            '$n · ${groups[n]!.length} · '
                            '${hubKg(groups[n]!.fold<double>(0, (s, r) => s + r.weightKg))}',
                          ),
                          selected: n == _category,
                          onSelected: _publishing
                              ? null
                              : (_) => _chooseCategory(n),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const _StepHeader(
                    number: 2,
                    title: 'Tick the donations',
                    subtitle:
                        'Tick 3–5 donations, up to 30 kg. Oldest are listed first.',
                  ),
                  for (final r in rows)
                    _PickTile(
                      row: r,
                      selected: _selected.contains(r.donationId),
                      onChanged: _publishing
                          ? null
                          : (on) => _toggle(r.donationId, on),
                    ),
                ],
              ),
            ),
            _BatchSummary(
              selectedCount: _selected.length,
              selectedKg: all
                  .where((r) => _selected.contains(r.donationId))
                  .fold<double>(0, (s, r) => s + r.weightKg),
              check: _check,
              checking: _checking,
              publishing: _publishing,
              onPublish: _check?.ok == true && !_checking && !_publishing
                  ? _publish
                  : null,
            ),
          ],
        );
      },
    ),
  );
}

class _StepHeader extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;
  const _StepHeader({
    required this.number,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: HubColors.green,
          child: Text(
            '$number',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(
                subtitle,
                style: const TextStyle(color: HubColors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _PickTile extends StatelessWidget {
  final HubStoredDonation row;
  final bool selected;
  final ValueChanged<bool>? onChanged;
  const _PickTile({
    required this.row,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => HubCard(
    padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
    borderColor: selected ? HubColors.green : null,
    color: selected ? const Color(0xfff3fbf8) : null,
    onTap: onChanged == null ? null : () => onChanged!(!selected),
    child: Row(
      children: [
        Checkbox(
          value: selected,
          onChanged: onChanged == null ? null : (v) => onChanged!(v == true),
        ),
        HubPhoto(row.photoPath, size: 46),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                'Stored ${hubDuration(row.waitingMinutes)} ago',
                style: const TextStyle(color: HubColors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        Text(
          hubKg(row.weightKg),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}

class _BatchSummary extends StatelessWidget {
  final int selectedCount;
  final double selectedKg;
  final HubBatchCheck? check;
  final bool checking;
  final bool publishing;
  final VoidCallback? onPublish;

  const _BatchSummary({
    required this.selectedCount,
    required this.selectedKg,
    required this.check,
    required this.checking,
    required this.publishing,
    required this.onPublish,
  });

  @override
  Widget build(BuildContext context) {
    final min = check?.minDonations ?? _defaultMin;
    final max = check?.maxDonations ?? _defaultMax;
    final maxKg = check?.maxKg ?? _defaultMaxKg;
    final countOk = selectedCount >= min && selectedCount <= max;
    final kgOk = selectedKg <= maxKg;
    return Material(
      elevation: 12,
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _Meter(
                      label: 'Donations',
                      value: '$selectedCount / $min–$max',
                      ratio: max == 0 ? 0 : selectedCount / max,
                      ok: countOk,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _Meter(
                      label: 'Weight',
                      value: '${hubKg(selectedKg)} / ${hubKg(maxKg)}',
                      ratio: maxKg == 0 ? 0 : selectedKg / maxKg,
                      ok: kgOk && selectedCount > 0,
                    ),
                  ),
                ],
              ),
              if (checking)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Checking with the server…',
                    style: TextStyle(color: HubColors.muted),
                  ),
                ),
              for (final p in check?.problems ?? const <String>[])
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          p,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              for (final w in check?.warnings ?? const <String>[])
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 16,
                        color: HubColors.amber,
                      ),
                      const SizedBox(width: 6),
                      Expanded(child: Text(w)),
                    ],
                  ),
                ),
              if (check?.ok == true && !checking)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        size: 16,
                        color: HubColors.green,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Ready to publish',
                        style: TextStyle(color: HubColors.green),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onPublish,
                  icon: const Icon(Icons.campaign_outlined),
                  label: Text(
                    publishing ? 'Publishing…' : 'Publish as one listing',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  final String label;
  final String value;
  final double ratio;
  final bool ok;
  const _Meter({
    required this.label,
    required this.value,
    required this.ratio,
    required this.ok,
  });

  @override
  Widget build(BuildContext context) {
    final color = ok
        ? HubColors.green
        : (ratio > 1 ? HubColors.red : HubColors.amber);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(color: HubColors.muted, fontSize: 12),
            ),
            const Spacer(),
            Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: color,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: ratio.clamp(0.0, 1.0),
            minHeight: 7,
            color: color,
            backgroundColor: HubColors.softGreen,
          ),
        ),
      ],
    );
  }
}
