import 'package:flutter/material.dart';

import 'hub_service.dart';
import 'hub_widgets.dart';

/// Opens the hub recommendation and reservation screen.
/// Returns true only when a reservation is confirmed.
Future<bool> openHubChooser(
  BuildContext context,
  String donationId, {
  String? donationTitle,
}) async {
  final result = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) =>
          HubChoosePage(donationId: donationId, donationTitle: donationTitle),
    ),
  );

  return result == true;
}

class HubChoosePage extends StatefulWidget {
  final String donationId;
  final String? donationTitle;

  const HubChoosePage({
    super.key,
    required this.donationId,
    this.donationTitle,
  });

  @override
  State<HubChoosePage> createState() => _HubChoosePageState();
}

class _HubChoosePageState extends State<HubChoosePage> {
  /// The day the donor will bring the donation (Malaysia date).
  DateTime _day = hubToday();
  late Future<List<HubOption>> _options = _load();
  bool _reserving = false;

  Future<List<HubOption>> _load() =>
      HubService.hubOptions(widget.donationId, day: _day);

  Future<void> _refresh() async {
    setState(() => _options = _load());
    await _options;
  }

  void _setDay(DateTime day) {
    if (day == _day) return;
    setState(() {
      _day = day;
      _options = _load();
    });
  }

  Future<void> _reserve(HubOption hub) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _ConfirmSheet(hub: hub, day: _day),
    );
    if (ok != true || !mounted) return;
    setState(() => _reserving = true);
    try {
      await HubService.reserveHub(widget.donationId, hub.hubId, day: _day);
      if (!mounted) return;
      hubToast(
        context,
        'Booked at ${hub.name} for ${hubOnDay(_day).replaceFirst('on ', '')}. '
        'Come any time it is open that day.',
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      hubToast(context, 'Not booked: ${hubErrorMessage(error)}');
      await _refresh();
    } finally {
      if (mounted) setState(() => _reserving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Choose a drop-off hub'),
      bottom: widget.donationTitle == null
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(22),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'For: ${widget.donationTitle}',
                  style: const TextStyle(color: HubColors.muted),
                ),
              ),
            ),
    ),
    body: Stack(
      children: [
        HubRefreshList<List<HubOption>>(
          future: _options,
          onRefresh: _refresh,
          builder: (context, options) {
            final feasible = options.where((o) => o.feasible).toList();
            final others = options.where((o) => !o.feasible).toList();
            // Keep the server's order; the first feasible hub is the recommendation.
            final recommended = feasible.isEmpty ? null : feasible.first;
            return [
              const _HowItWorks(),
              _DayPicker(
                selected: _day,
                onChanged: _reserving ? null : _setDay,
              ),
              if (recommended != null)
                _RankingBanner(mode: recommended.rankingMode),
              if (recommended != null) ...[
                HubSectionTitle(
                  recommended.rankingMode == 'MODEL'
                      ? 'AI recommended for you'
                      : 'Recommended for you',
                ),
                _HubOptionCard(
                  hub: recommended,
                  day: _day,
                  recommended: true,
                  onTap: _reserving ? null : () => _reserve(recommended),
                ),
              ],
              if (feasible.length > 1) ...[
                HubSectionTitle(
                  'Other hubs (${feasible.length - 1})',
                  subtitle: recommended!.aiRanked
                      ? 'Best match first'
                      : 'Nearest first',
                ),
                for (final hub in feasible.skip(1))
                  _HubOptionCard(
                    hub: hub,
                    day: _day,
                    onTap: _reserving ? null : () => _reserve(hub),
                  ),
              ],
              if (feasible.isEmpty)
                HubEmptyState(
                  icon: Icons.storefront_outlined,
                  title: 'No hub can take this donation ${hubOnDay(_day)}',
                  message:
                      'Hubs may be closed, full, or not accept these items that day. '
                      'Try another day above, or pull down to check again.',
                ),
              if (others.isNotEmpty)
                Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 2),
                    title: Text(
                      'Not available ${hubOnDay(_day)} (${others.length})',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    children: [
                      for (final hub in others) _UnavailableTile(hub: hub),
                    ],
                  ),
                ),
            ];
          },
        ),
        if (_reserving)
          const ColoredBox(
            color: Color(0x66ffffff),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    ),
  );
}

/// Drop-off day: today and the next 6 days.
class _DayPicker extends StatelessWidget {
  final DateTime selected;
  final ValueChanged<DateTime>? onChanged;
  const _DayPicker({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const HubSectionTitle(
        'When will you drop it off?',
        subtitle: 'Pick a day. You can come any time the hub is open that day.',
      ),
      SizedBox(
        height: 42,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final day in hubDropOffDays())
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(hubDayLabel(day)),
                  selected: day == selected,
                  onSelected: onChanged == null ? null : (_) => onChanged!(day),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 4),
    ],
  );
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) => const HubCard(
    color: HubColors.softGreen,
    borderColor: Colors.transparent,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, color: HubColors.green),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Small donations are collected at a community hub. Pick the day you will '
            'come, then a hub: it keeps space for you until it closes that day. Come any '
            'time it is open and show your reference code at the counter.',
          ),
        ),
      ],
    ),
  );
}

class _HubOptionCard extends StatelessWidget {
  final HubOption hub;
  final DateTime day;
  final bool recommended;
  final VoidCallback? onTap;

  const _HubOptionCard({
    required this.hub,
    required this.day,
    this.recommended = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final today = day == hubToday();
    final open = today && hub.hours.isOpenNow;
    final close = hub.hours.lastCloseOn(day);
    final until = close == null ? '' : ' ┬╖ until ${hubTimeLabel(close)}';
    return HubCard(
      onTap: onTap,
      borderColor: recommended ? HubColors.green : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: HubColors.softGreen,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.storefront_outlined,
                  color: HubColors.green,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hub.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      hub.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: HubColors.muted),
                    ),
                  ],
                ),
              ),
              if (recommended)
                HubStatusChip(
                  hub.rankingMode == 'MODEL' ? 'AI pick' : 'Recommended',
                  color: HubColors.green,
                  icon: hub.rankingMode == 'MODEL'
                      ? Icons.auto_awesome
                      : Icons.star_rounded,
                )
              else if (hub.inTopK && hub.rank != null)
                HubStatusChip('Top ${hub.rank}', color: HubColors.blue),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (hub.roadKm != null)
                HubStatusChip(
                  '${hub.roadKm!.toStringAsFixed(1)} km by road',
                  color: HubColors.blue,
                  icon: Icons.route_outlined,
                ),
              HubStatusChip(
                today
                    ? (open ? 'Open now$until' : 'Opens later$until')
                    : 'Open ${hubDayLabel(day)}$until',
                color: open || !today ? HubColors.green : HubColors.amber,
                icon: Icons.schedule,
              ),
              HubStatusChip(
                '${hubKg(hub.availableKg)} free',
                color: HubColors.muted,
                icon: Icons.inventory_2_outlined,
              ),
              if (hub.storageNote != null)
                HubStatusChip(
                  hub.storageNote!,
                  color: hub.storageNote!.startsWith('Has')
                      ? HubColors.green
                      : HubColors.amber,
                  icon: Icons.warehouse_outlined,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${hubDayLabel(day)}: ${hub.hours.textOn(day)}',
            style: const TextStyle(fontSize: 13, color: HubColors.muted),
          ),
          if (recommended)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _whyRecommended(hub),
                style: const TextStyle(fontSize: 12, color: HubColors.muted),
              ),
            ),
        ],
      ),
    );
  }
}

String _whyRecommended(HubOption hub) => switch (hub.rankingMode) {
  'MODEL' =>
    hub.explanation ?? 'Best balance of distance, free space and handling.',
  'REFERENCE_FALLBACK' =>
    hub.explanation ??
        'Best balance of road distance, how full the hub is and free space.',
  _ =>
    'Nearest hub by road that accepts your items, has space and is open '
        'on your drop-off day.',
};

/// Says how the hub list is ordered.
class _RankingBanner extends StatelessWidget {
  final String mode;
  const _RankingBanner({required this.mode});

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (mode) {
      'MODEL' => (
        Icons.auto_awesome,
        HubColors.green,
        'Ranked by AI: road distance, how full each hub is, free space and whether '
            'the hub has the storage your items need.',
      ),
      'REFERENCE_FALLBACK' => (
        Icons.rule,
        HubColors.amber,
        'AI is unavailable. Ranked by the standard rule (distance, fullness, free space).',
      ),
      _ => (Icons.route_outlined, HubColors.muted, 'Sorted by road distance.'),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, color: HubColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnavailableTile extends StatelessWidget {
  final HubOption hub;
  const _UnavailableTile({required this.hub});

  @override
  Widget build(BuildContext context) => HubCard(
    color: const Color(0xfff7f9f8),
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        const Icon(Icons.block, color: HubColors.muted),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hub.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                hub.reasons.map(hubReasonText).join(' ┬╖ '),
                style: const TextStyle(color: HubColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
        if (hub.roadKm != null)
          Text(
            '${hub.roadKm!.toStringAsFixed(1)} km',
            style: const TextStyle(color: HubColors.muted),
          ),
      ],
    ),
  );
}

class _ConfirmSheet extends StatelessWidget {
  final HubOption hub;
  final DateTime day;
  const _ConfirmSheet({required this.hub, required this.day});

  @override
  Widget build(BuildContext context) {
    final label = hubDayLabel(day);
    final close = hub.hours.lastCloseOn(day);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Book ${hub.name}?',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            HubInfoRow(Icons.place_outlined, 'Address', hub.address),
            HubInfoRow(
              Icons.event_outlined,
              'Drop-off day',
              label.startsWith('To') ? '$label (${hubDayDate(day)})' : label,
            ),
            HubInfoRow(Icons.schedule, 'Open that day', hub.hours.textOn(day)),
            HubInfoRow(
              Icons.timer_outlined,
              'Space held until',
              hub.closesAt != null
                  ? hubCloseLabel(hub.closesAt)
                  : (close == null ? 'ΓÇö' : hubTimeLabel(close)),
            ),
            const SizedBox(height: 8),
            const Text(
              'Come any time the hub is open that day; no appointment needed. If you do '
              'not come by closing time, the booking ends and you can choose a hub and '
              'day again.',
              style: TextStyle(color: HubColors.muted),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Book this hub'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
