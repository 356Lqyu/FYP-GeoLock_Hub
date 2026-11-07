import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'hub_admin_controller.dart';
import 'hub_donation_detail_page.dart';
import 'hub_service.dart';
import 'hub_widgets.dart';

enum _ListingFilter { open, waiting, claimed, done, all }

class HubListingPage extends StatefulWidget {
  final HubAdminController controller;
  const HubListingPage({super.key, required this.controller});

  @override
  State<HubListingPage> createState() => _HubListingPageState();
}

class _HubListingPageState extends State<HubListingPage>
    with HubReloadOnChange {
  late Future<List<HubBatchListing>> _rows;
  _ListingFilter _filter = _ListingFilter.open;

  HubAdminController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    hubNeedsReload(_c);
    _rows = HubService.listings(_c.hubId);
    _c.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (hubNeedsReload(_c) && mounted) {
      setState(() => _rows = HubService.listings(_c.hubId));
    }
  }

  Future<void> _refresh() async {
    setState(() => _rows = HubService.listings(_c.hubId));
    await _rows;
  }

  static bool _keep(HubBatchListing r, _ListingFilter f) => switch (f) {
    _ListingFilter.open => r.isOpen,
    _ListingFilter.waiting => r.stage == HubListingStage.waitingForNgo,
    _ListingFilter.claimed =>
      r.stage == HubListingStage.claimed ||
          r.stage == HubListingStage.pickupInProgress ||
          r.stage == HubListingStage.handoverReview,
    _ListingFilter.done => !r.isOpen,
    _ListingFilter.all => true,
  };

  Future<void> _open(HubBatchListing r) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HubListingDetailPage(
          controller: _c,
          batchId: r.batchId,
          hubName: _c.hub.name,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) => HubRefreshList<List<HubBatchListing>>(
    future: _rows,
    onRefresh: _refresh,
    builder: (context, rows) {
      const labels = {
        _ListingFilter.open: 'Active',
        _ListingFilter.waiting: 'Waiting',
        _ListingFilter.claimed: 'Claimed',
        _ListingFilter.done: 'Done',
        _ListingFilter.all: 'All',
      };
      final chips = {
        for (final f in _ListingFilter.values)
          f: rows.where((r) => _keep(r, f)).length,
      };
      final shown = rows.where((r) => _keep(r, _filter)).toList();
      return [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final f in _ListingFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${labels[f]} (${chips[f]})'),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          HubEmptyState(
            icon: Icons.campaign_outlined,
            title: rows.isEmpty ? 'No batch listings yet' : 'Nothing here',
            message: rows.isEmpty
                ? 'Build a batch from stored donations to list it for NGOs.'
                : 'Try another filter.',
            actionLabel: rows.isEmpty ? 'Go to inventory' : null,
            onAction: rows.isEmpty
                ? () => _c.openTab(HubAdminTab.inventory)
                : null,
          ),
        for (final r in shown) _ListingCard(row: r, onTap: () => _open(r)),
      ];
    },
  );
}

class _ListingCard extends StatelessWidget {
  final HubBatchListing row;
  final VoidCallback onTap;
  const _ListingCard({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) => HubCard(
    onTap: onTap,
    borderColor: row.stage == HubListingStage.handoverReview
        ? HubColors.amber.withValues(alpha: .6)
        : null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HubPhoto(
              row.coverPath,
              size: 60,
              placeholderIcon: Icons.all_inbox_outlined,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${row.categoryName} batch',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    '${row.donationCount} donations · ${hubKg(row.weightKg)}',
                    style: const TextStyle(color: HubColors.muted),
                  ),
                  Text(
                    row.ngoName != null
                        ? 'NGO: ${row.ngoName}'
                        : 'Listed ${hubAgo(row.publishedAt)}',
                    style: const TextStyle(color: HubColors.muted),
                  ),
                ],
              ),
            ),
            HubStatusChip(
              hubStageLabel(row.stage),
              color: hubStageColor(row.stage),
              icon: hubStageIcon(row.stage),
            ),
          ],
        ),
        if (row.stage != HubListingStage.cancelled) ...[
          const SizedBox(height: 12),
          HubPickupProgress(stage: row.stage),
        ],
      ],
    ),
  );
}

/// Four-step bar: Listed -> Claimed -> On the way -> Collected.
class HubPickupProgress extends StatelessWidget {
  final HubListingStage stage;
  const HubPickupProgress({super.key, required this.stage});

  int get _reached => switch (stage) {
    HubListingStage.waitingForNgo => 0,
    HubListingStage.claimed => 1,
    HubListingStage.pickupInProgress => 2,
    HubListingStage.handoverReview => 2,
    HubListingStage.collected => 3,
    HubListingStage.cancelled => -1,
  };

  @override
  Widget build(BuildContext context) {
    const steps = ['Listed', 'Claimed', 'On the way', 'Collected'];
    final reached = _reached;
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: i <= reached ? HubColors.green : HubColors.softGreen,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  steps[i],
                  style: TextStyle(
                    fontSize: 11,
                    color: i <= reached ? HubColors.ink : HubColors.muted,
                    fontWeight: i == reached
                        ? FontWeight.w800
                        : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (i < steps.length - 1) const SizedBox(width: 4),
        ],
      ],
    );
  }
}

// Detail of one batch listing.

class HubListingDetailPage extends StatefulWidget {
  final HubAdminController controller;
  final String batchId;
  final String hubName;

  const HubListingDetailPage({
    super.key,
    required this.controller,
    required this.batchId,
    required this.hubName,
  });

  @override
  State<HubListingDetailPage> createState() => _HubListingDetailPageState();
}

class _HubListingDetailPageState extends State<HubListingDetailPage> {
  late Future<(HubBatchListing?, Map<String, dynamic>)> _data = _load();
  bool _busy = false;

  String get _hubId => widget.controller.hubId;

  Future<(HubBatchListing?, Map<String, dynamic>)> _load() async {
    final results = await Future.wait([
      HubService.listings(_hubId),
      HubService.batchDetail(_hubId, widget.batchId),
    ]);
    final listings = results[0] as List<HubBatchListing>;
    final match = listings.where((l) => l.batchId == widget.batchId);
    return (
      match.isEmpty ? null : match.first,
      results[1] as Map<String, dynamic>,
    );
  }

  Future<void> _refresh() async {
    setState(() => _data = _load());
    await _data;
  }

  Future<void> _addPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1800,
    );
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await HubService.addBatchPhoto(widget.batchId, File(picked.path));
      if (!mounted) return;
      hubToast(context, 'Cover photo added. NGOs will see it on the listing.');
      widget.controller.dataChanged();
      await _refresh();
    } catch (error) {
      if (mounted) {
        hubToast(context, 'Photo not added: ${hubErrorMessage(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _answerHandover(HubBatchListing listing, bool collected) async {
    final ok = await hubConfirm(
      context,
      title: collected ? 'NGO collected the batch?' : 'Batch not collected?',
      message: collected
          ? 'Confirm that ${listing.ngoName ?? 'the NGO'} took all '
                '${listing.donationCount} donations from the hub.'
          : 'Confirm that the batch is still at the hub. The case will be resolved '
                'with the NGO\'s answer.',
      confirmLabel: collected ? 'Yes, collected' : 'Not collected',
      destructive: !collected,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await HubService.confirmHandover(listing.claimId!, collected: collected);
      if (!mounted) return;
      hubToast(context, 'Thank you. Your answer was saved.');
      widget.controller.dataChanged();
      await _refresh();
    } catch (error) {
      if (mounted) hubToast(context, 'Not saved: ${hubErrorMessage(error)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Batch listing')),
    body: HubRefreshList<(HubBatchListing?, Map<String, dynamic>)>(
      future: _data,
      onRefresh: _refresh,
      builder: (context, data) {
        final (listing, detail) = data;
        final donations = (detail['donations'] as List? ?? const [])
            .whereType<Map>()
            .map((d) => Map<String, dynamic>.from(d))
            .toList();
        final cover = hubText(detail['batch_cover_path']);
        return [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: LayoutBuilder(
                builder: (context, box) => HubPhoto(
                  cover,
                  size: box.maxWidth,
                  placeholderIcon: Icons.all_inbox_outlined,
                ),
              ),
            ),
          ),
          if (listing != null && listing.isOpen)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : _addPhoto,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Add batch photo'),
              ),
            ),
          if (listing != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${listing.categoryName} batch',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                HubStatusChip(
                  hubStageLabel(listing.stage),
                  color: hubStageColor(listing.stage),
                  icon: hubStageIcon(listing.stage),
                ),
              ],
            ),
            Text(
              '${listing.donationCount} donations · ${hubKg(listing.weightKg)} · '
              'from ${widget.hubName}',
              style: const TextStyle(color: HubColors.muted),
            ),
            const SizedBox(height: 12),
            if (listing.handoverCaseOpen) _handoverCard(listing),
            HubCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Pickup progress',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  if (listing.stage != HubListingStage.cancelled)
                    HubPickupProgress(stage: listing.stage),
                  const SizedBox(height: 10),
                  HubInfoRow(
                    Icons.campaign_outlined,
                    'Listed',
                    hubDateTime(listing.publishedAt),
                  ),
                  if (listing.claimedAt != null)
                    HubInfoRow(
                      Icons.assignment_turned_in_outlined,
                      'Claimed',
                      hubDateTime(listing.claimedAt),
                    ),
                  if (listing.collectedAt != null)
                    HubInfoRow(
                      Icons.task_alt,
                      'Collected',
                      hubDateTime(listing.collectedAt),
                    ),
                  if (listing.endedClaimCount > 0)
                    HubInfoRow(
                      Icons.undo,
                      'Earlier claims',
                      '${listing.endedClaimCount} ended without pickup',
                    ),
                ],
              ),
            ),
            if (listing.ngoName != null)
              HubCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Collecting NGO',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    HubInfoRow(Icons.groups_outlined, 'NGO', listing.ngoName!),
                    if (listing.ngoPhone != null)
                      HubInfoRow(
                        Icons.phone_outlined,
                        'Phone',
                        listing.ngoPhone!,
                      ),
                    if (listing.claimStatus == 'ACTIVE' &&
                        listing.leaseExpiresAt != null)
                      HubInfoRow(
                        Icons.timer_outlined,
                        'Pickup by',
                        '${hubDateTime(listing.leaseExpiresAt)} '
                            '(claim is released after that)',
                      ),
                    if (listing.claimStatus == 'ACTIVE')
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Hand over all donations in this batch when the NGO arrives. '
                          'The NGO confirms the pickup in their app.',
                          style: TextStyle(color: HubColors.muted),
                        ),
                      ),
                  ],
                ),
              ),
          ],
          HubSectionTitle('Donations in this batch (${donations.length})'),
          for (final d in donations)
            HubCard(
              padding: const EdgeInsets.all(10),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HubDonationDetailPage(
                    controller: widget.controller,
                    donationId: d['donation_id'].toString(),
                  ),
                ),
              ),
              child: Row(
                children: [
                  HubPhoto(hubText(d['primary_image_path']), size: 44),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      d['title']?.toString() ?? 'Donation',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(hubKg(hubDouble(d['weight_kg']))),
                  const Icon(Icons.chevron_right, color: HubColors.muted),
                ],
              ),
            ),
        ];
      },
    ),
  );

  Widget _handoverCard(HubBatchListing listing) => HubCard(
    color: const Color(0xfffff8e8),
    borderColor: HubColors.amber.withValues(alpha: .5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.help_outline, color: HubColors.amber),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Did the NGO collect this batch?',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'The pickup was not confirmed before the claim expired. Your answer and the '
          'NGO\'s answer decide what happens to the donations.',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _answerHandover(listing, false),
                child: const Text('Not collected'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _answerHandover(listing, true),
                child: const Text('Yes, collected'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
