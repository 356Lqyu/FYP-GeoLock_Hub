// One donation as the hub sees it. An awaited drop-off can be received here.
import 'package:flutter/material.dart';

import 'hub_admin_controller.dart';
import 'hub_dropoff_page.dart';
import 'hub_service.dart';
import 'hub_widgets.dart';

class HubDonationDetailPage extends StatefulWidget {
  final HubAdminController controller;
  final String donationId;

  const HubDonationDetailPage({
    super.key,
    required this.controller,
    required this.donationId,
  });

  @override
  State<HubDonationDetailPage> createState() => _HubDonationDetailPageState();
}

class _HubDonationDetailPageState extends State<HubDonationDetailPage> {
  late Future<Map<String, dynamic>> _detail = _load();

  Future<Map<String, dynamic>> _load() =>
      HubService.donationDetail(widget.controller.hubId, widget.donationId);

  Future<void> _refresh() async {
    setState(() => _detail = _load());
    await _detail;
  }

  Future<void> _receive(Map<String, dynamic> detail) async {
    final ok = await showHubReceiveSheet(
      context,
      HubDropOff.fromDonationDetail(detail),
    );
    if (!ok || !mounted) return;
    widget.controller.dataChanged();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Donation')),
    body: HubRefreshList<Map<String, dynamic>>(
      future: _detail,
      onRefresh: _refresh,
      builder: (context, d) {
        final photos = (d['image_paths'] as List? ?? const [])
            .map((p) => '$p')
            .toList();
        final items = (d['items'] as List? ?? const [])
            .whereType<Map>()
            .toList();
        final reservation = d['reservation'] is Map
            ? d['reservation'] as Map
            : null;
        final receipt = d['receipt'] is Map ? d['receipt'] as Map : null;
        final batch = d['batch'] is Map ? d['batch'] as Map : null;
        final booking = reservation == null
            ? null
            : HubDropOff.fromDonationDetail(d);
        return [
          if (photos.isNotEmpty) _PhotoStrip(paths: photos),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  d['title']?.toString() ?? 'Donation',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (booking != null)
                HubStatusChip(
                  hubDropOffLabel(booking.status),
                  color: hubDropOffColor(booking.status),
                ),
            ],
          ),
          if (hubText(d['description']) != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(d['description'].toString()),
            ),
          const SizedBox(height: 12),
          if (booking != null && booking.awaiting)
            HubCard(
              color: const Color(0xffeef5fb),
              borderColor: HubColors.blue.withValues(alpha: .3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    booking.dropOffDay == null
                        ? 'Donor coming before ${hubCloseLabel(booking.expiresAt)}'
                        : 'Donor coming ${hubOnDay(booking.dropOffDay!)}, '
                              'before ${hubCloseLabel(booking.expiresAt)}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  if (booking.donorName != null)
                    Text('Donor: ${booking.donorName}'),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _receive(d),
                      icon: const Icon(Icons.move_to_inbox_outlined),
                      label: const Text('Receive this donation'),
                    ),
                  ),
                ],
              ),
            ),
          HubCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Hub record',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                HubInfoRow(
                  Icons.scale_outlined,
                  'Weight',
                  receipt != null
                      ? '${hubKg(hubDouble(receipt['received_weight_kg']))} measured'
                      : '${hubKg(hubDouble(d['total_weight_kg']))} declared',
                ),
                if (booking != null) ...[
                  HubInfoRow(
                    Icons.qr_code_2,
                    'Reference',
                    booking.referenceCode,
                  ),
                  HubInfoRow(
                    Icons.event_available_outlined,
                    'Booked',
                    hubDateTime(booking.reservedAt),
                  ),
                ],
                if (receipt != null) ...[
                  HubInfoRow(
                    Icons.move_to_inbox_outlined,
                    'Received',
                    hubDateTime(hubDate(receipt['received_at'])),
                  ),
                  if (hubText(receipt['received_by']) != null)
                    HubInfoRow(
                      Icons.badge_outlined,
                      'Received by',
                      receipt['received_by'].toString(),
                    ),
                ],
                if (d['waiting_minutes'] != null)
                  HubInfoRow(
                    Icons.schedule,
                    'Waiting',
                    hubDuration(hubInt(d['waiting_minutes'])),
                  ),
                if (batch != null)
                  HubInfoRow(
                    Icons.all_inbox_outlined,
                    'Batch',
                    batch['listing_status'] == 'CLAIMED'
                        ? 'In a claimed batch'
                        : batch['batch_status'] == 'COLLECTED'
                        ? 'Collected by NGO'
                        : 'In a listed batch',
                  ),
              ],
            ),
          ),
          HubSectionTitle('Items (${items.length})'),
          for (final item in items)
            HubCard(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(
                    Icons.inventory_2_outlined,
                    color: HubColors.green,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['item_name']?.toString() ?? 'Item',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          '${item['category']} · ${item['item_condition']}'
                          '${hubText(item['description']) == null ? '' : ' · ${item['description']}'}',
                          style: const TextStyle(color: HubColors.muted),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${item['quantity']} ${item['unit_label']}\n'
                    '${hubKg(hubDouble(item['unit_weight_kg']) * hubInt(item['quantity']))}',
                    textAlign: TextAlign.right,
                  ),
                ],
              ),
            ),
        ];
      },
    ),
  );
}

class _PhotoStrip extends StatelessWidget {
  final List<String> paths;
  const _PhotoStrip({required this.paths});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 180,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: paths.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (_, i) => HubPhoto(paths[i], size: 180),
    ),
  );
}
