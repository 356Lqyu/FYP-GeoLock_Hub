// Inventory tab: stored donations by category, oldest first.
import 'package:flutter/material.dart';

import 'hub_batch_page.dart';
import 'hub_admin_controller.dart';
import 'hub_donation_detail_page.dart';
import 'hub_service.dart';
import 'hub_widgets.dart';

/// Stored this long or more is highlighted so old donations are batched first.
const hubLongWaitMinutes = 3 * 24 * 60;

class HubInventoryManagePage extends StatefulWidget {
  final HubAdminController controller;
  const HubInventoryManagePage({super.key, required this.controller});

  @override
  State<HubInventoryManagePage> createState() => _HubInventoryManagePageState();
}

class _HubInventoryManagePageState extends State<HubInventoryManagePage>
    with HubReloadOnChange {
  late Future<List<HubStoredDonation>> _rows;
  String? _category;

  HubAdminController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    hubNeedsReload(_c);
    _rows = HubService.inventory(_c.hubId);
    _category = _c.takeInventoryCategory();
    _c.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final category = _c.takeInventoryCategory();
    if (!mounted) return;
    if (category != null) setState(() => _category = category);
    if (hubNeedsReload(_c)) {
      setState(() => _rows = HubService.inventory(_c.hubId));
    }
  }

  Future<void> _refresh() async {
    setState(() => _rows = HubService.inventory(_c.hubId));
    await _rows;
  }

  Future<void> _buildBatch() async {
    final batchId = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            DonationBatchPage(controller: _c, initialCategory: _category),
      ),
    );
    if (batchId == null || !mounted) return;
    _c.dataChanged();
    hubToast(context, 'Batch published. NGOs nearby can now claim it.');
    _c.openTab(HubAdminTab.listings);
  }

  void _open(HubStoredDonation row) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) =>
          HubDonationDetailPage(controller: _c, donationId: row.donationId),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    floatingActionButton: FloatingActionButton.extended(
      heroTag: 'hub-build-batch',
      onPressed: _buildBatch,
      icon: const Icon(Icons.playlist_add_check),
      label: const Text('Build batch'),
    ),
    body: HubRefreshList<List<HubStoredDonation>>(
      future: _rows,
      onRefresh: _refresh,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      builder: (context, rows) {
        final stored = rows.where((r) => r.stored).toList();
        final batched = rows.where((r) => !r.stored).toList();
        final counts = <String, int>{};
        for (final r in stored) {
          counts[r.categoryName] = (counts[r.categoryName] ?? 0) + 1;
        }
        final categories = counts.keys.toList()..sort();
        if (_category != null && !counts.containsKey(_category)) {
          _category = null;
        }
        final shown = stored
            .where((r) => _category == null || r.categoryName == _category)
            .toList();
        final totalKg = stored.fold<double>(0, (sum, r) => sum + r.weightKg);
        final longWait = stored
            .where((r) => r.waitingMinutes >= hubLongWaitMinutes)
            .length;
        return [
          Row(
            children: [
              Expanded(
                child: HubStatTile(
                  value: '${stored.length}',
                  label: 'Stored donations',
                  icon: Icons.inventory_2_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: HubStatTile(
                  value: hubKg(totalKg),
                  label: 'Stored weight',
                  icon: Icons.scale_outlined,
                ),
              ),
            ],
          ),
          if (longWait > 0)
            HubCard(
              color: const Color(0xfffff8e8),
              borderColor: HubColors.amber.withValues(alpha: .4),
              child: Row(
                children: [
                  const Icon(Icons.hourglass_bottom, color: HubColors.amber),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$longWait ${longWait == 1 ? 'donation has' : 'donations have'} '
                      'waited 3 days or more. Batch the oldest first.',
                    ),
                  ),
                ],
              ),
            ),
          if (categories.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('All (${stored.length})'),
                      selected: _category == null,
                      onSelected: (_) => setState(() => _category = null),
                    ),
                  ),
                  for (final c in categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('$c (${counts[c]})'),
                        selected: _category == c,
                        onSelected: (_) => setState(() => _category = c),
                      ),
                    ),
                ],
              ),
            ),
          HubSectionTitle(
            'Stored at the hub',
            subtitle: 'Oldest first. Tap a donation to see its items.',
          ),
          if (shown.isEmpty)
            const HubEmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'Nothing stored',
              message: 'Received drop-offs appear here until you batch them.',
            ),
          for (final row in shown)
            _StoredTile(row: row, onTap: () => _open(row)),
          if (batched.isNotEmpty)
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 2),
                title: Text(
                  'In batches (${batched.length})',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: const Text(
                  'Still at the hub until the NGO collects them',
                ),
                children: [
                  for (final row in batched)
                    _StoredTile(row: row, onTap: () => _open(row)),
                ],
              ),
            ),
        ];
      },
    ),
  );
}

class _StoredTile extends StatelessWidget {
  final HubStoredDonation row;
  final VoidCallback onTap;
  const _StoredTile({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final long = row.stored && row.waitingMinutes >= hubLongWaitMinutes;
    return HubCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          HubPhoto(row.photoPath, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${hubKg(row.weightKg)} · ${row.categoryName}',
                  style: const TextStyle(color: HubColors.muted),
                ),
              ],
            ),
          ),
          if (row.stored)
            HubStatusChip(
              hubDuration(row.waitingMinutes),
              color: long ? HubColors.amber : HubColors.green,
              icon: Icons.schedule,
            )
          else
            const HubStatusChip('In batch', color: HubColors.blue),
        ],
      ),
    );
  }
}
