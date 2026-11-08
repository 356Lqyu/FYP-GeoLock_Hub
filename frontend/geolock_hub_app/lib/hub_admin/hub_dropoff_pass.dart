import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'hub_service.dart';
import 'hub_widgets.dart';
import 'hub_chooser_page.dart';

class HubDropOffCard extends StatefulWidget {
  final String donationId;

  /// Called after the donor booked a hub so the donation page can reload.
  final VoidCallback? onChanged;

  const HubDropOffCard({super.key, required this.donationId, this.onChanged});

  @override
  State<HubDropOffCard> createState() => _HubDropOffCardState();
}

class _HubDropOffCardState extends State<HubDropOffCard> {
  late Future<HubDropOffPass> _pass = HubService.dropOffPass(widget.donationId);
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(HubDropOffCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.donationId != widget.donationId) {
      _pass = HubService.dropOffPass(widget.donationId);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _choose(HubDropOffPass pass) async {
    final booked = await openHubChooser(
      context,
      widget.donationId,
      donationTitle: pass.title,
    );
    if (!booked || !mounted) return;
    setState(() => _pass = HubService.dropOffPass(widget.donationId));
    widget.onChanged?.call();
  }

  void _openPass() => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => HubDropOffPassPage(donationId: widget.donationId),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<HubDropOffPass>(
    future: _pass,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return HubCard(
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined, color: HubColors.muted),
              const SizedBox(width: 10),
              Expanded(child: Text(hubErrorMessage(snapshot.error!))),
              TextButton(
                onPressed: () => setState(
                  () => _pass = HubService.dropOffPass(widget.donationId),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      }
      if (!snapshot.hasData) {
        return const HubCard(child: LinearProgressIndicator());
      }
      final pass = snapshot.data!;
      final r = pass.reservation;
      switch (pass.nextStep) {
        case HubNextStep.notHub:
        case HubNextStep.cancelled:
          return const SizedBox.shrink();
        case HubNextStep.chooseHub:
          return _card(
            icon: Icons.storefront_outlined,
            color: HubColors.green,
            title: 'Choose a drop-off hub',
            body:
                'This donation is under 10 kg, so it is collected at a community hub. '
                'We show the best hub for your items first.',
            action: FilledButton.icon(
              onPressed: () => _choose(pass),
              icon: const Icon(Icons.storefront_outlined),
              label: const Text('Choose a hub'),
            ),
          );
        case HubNextStep.dropOff:
          final day = r?.dropOffDay;
          return _card(
            icon: Icons.directions_walk,
            color: HubColors.blue,
            title: 'Drop off at ${r?.hubName ?? 'the hub'}',
            body:
                'Reference ${r?.referenceCode ?? ''} ┬╖ '
                '${day == null ? 'before ${hubCloseLabel(r?.expiresAt)}' : '${hubDayLabel(day)}, any time ${r!.hours.textOn(day)}'}'
                '\n${r?.hubAddress ?? ''}',
            action: FilledButton.icon(
              onPressed: _openPass,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Show drop-off pass'),
            ),
          );
        case HubNextStep.chooseAgain:
          return _card(
            icon: Icons.timer_off_outlined,
            color: HubColors.amber,
            title: 'Your booking ended',
            body:
                'The booking at ${r?.hubName ?? 'the hub'}'
                '${r?.dropOffDay == null ? '' : ' for ${hubDayDate(r!.dropOffDay!)}'} ended '
                'before the drop-off, so the space was given back. Choose a hub and day '
                'again when you are ready.',
            action: FilledButton.icon(
              onPressed: () => _choose(pass),
              icon: const Icon(Icons.refresh),
              label: const Text('Choose a hub again'),
            ),
          );
        case HubNextStep.atHub:
          return _card(
            icon: Icons.inventory_2_outlined,
            color: HubColors.green,
            title: 'At ${r?.hubName ?? 'the hub'}',
            body:
                'Received ${hubDateTime(r?.receivedAt)}. The hub will add it to a batch '
                'for an NGO to collect.',
          );
        case HubNextStep.inBatch:
          return _card(
            icon: Icons.all_inbox_outlined,
            color: HubColors.blue,
            title: 'In a batch for NGOs',
            body:
                '${r?.hubName ?? 'The hub'} grouped your donation with others. An NGO '
                'nearby claims and collects the batch.',
          );
        case HubNextStep.done:
          return _card(
            icon: Icons.task_alt,
            color: HubColors.green,
            title: 'Collected by an NGO',
            body:
                'Thank you! Your donation has reached an NGO through ${r?.hubName ?? 'the hub'}.',
          );
      }
    },
  );

  Widget _card({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    Widget? action,
  }) => HubCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(body),
        if (action != null) ...[
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: action),
        ],
      ],
    ),
  );
}

class HubDropOffPassPage extends StatefulWidget {
  final String donationId;
  const HubDropOffPassPage({super.key, required this.donationId});

  @override
  State<HubDropOffPassPage> createState() => _HubDropOffPassPageState();
}

class _HubDropOffPassPageState extends State<HubDropOffPassPage> {
  late Future<HubDropOffPass> _pass = HubService.dropOffPass(widget.donationId);
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Redraw the countdown every 30 seconds.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _pass = HubService.dropOffPass(widget.donationId));
    await _pass;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Drop-off pass')),
    body: HubRefreshList<HubDropOffPass>(
      future: _pass,
      onRefresh: _refresh,
      builder: (context, pass) {
        final r = pass.reservation;
        if (r == null) {
          return const [
            HubEmptyState(
              icon: Icons.storefront_outlined,
              title: 'No hub booked',
              message: 'Choose a hub from the donation page first.',
            ),
          ];
        }
        final booked = r.dropOffDay;
        final bookedKey = booked == null ? hubTodayKey() : hubDayKey(booked);
        return [
          _PassCard(pass: pass, reservation: r),
          const HubSectionTitle('Hub'),
          HubCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.hubName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(r.hubAddress)),
                    IconButton(
                      tooltip: 'Copy address',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: r.hubAddress));
                        hubToast(
                          context,
                          'Address copied. Paste it into your maps app.',
                        );
                      },
                    ),
                  ],
                ),
                const Divider(height: 20),
                const Text(
                  'Opening hours',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                for (final day in hubWeekdays)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 110,
                          child: Text(
                            hubWeekdayLabels[day]!,
                            style: TextStyle(
                              fontWeight: day == bookedKey
                                  ? FontWeight.w800
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            r.hours.dayText(day),
                            style: TextStyle(
                              fontWeight: day == bookedKey
                                  ? FontWeight.w800
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (r.status == HubDropOffStatus.awaiting) ...[
            const HubSectionTitle('At the hub'),
            const HubCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Step(1, 'Bring all the items in this donation.'),
                  _Step(2, 'Show the reference code to the hub staff.'),
                  _Step(
                    3,
                    'The staff weigh the items and confirm the receipt.',
                  ),
                  _Step(
                    4,
                    'You will see "At hub" on your donation. Thank you!',
                  ),
                ],
              ),
            ),
            const HubSectionTitle('Cannot make it?'),
            HubCard(
              child: Text(
                'If you do not come by ${hubCloseLabel(r.expiresAt)}'
                '${booked == null ? '' : ' ${hubOnDay(booked)}'}, the booking ends and the '
                'space is given back. You can then choose a hub and day again from the '
                'donation page, or cancel the donation there.',
              ),
            ),
          ],
        ];
      },
    ),
  );
}

class _PassCard extends StatelessWidget {
  final HubDropOffPass pass;
  final HubPassReservation reservation;
  const _PassCard({required this.pass, required this.reservation});

  @override
  Widget build(BuildContext context) {
    final r = reservation;
    final awaiting = r.status == HubDropOffStatus.awaiting;
    final left = hubMinutesLeft(r.expiresAt);
    final day = r.dropOffDay;
    final today = day != null && day == hubToday();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xff2f806c), Color(0xff1f5f50)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Text(
            pass.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          Text(
            '${hubKg(r.reservedKg)} ┬╖ ${r.hubName}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          const Text('Reference code', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              r.referenceCode,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w900,
                letterSpacing: 6,
                fontFamily: 'monospace',
                color: HubColors.ink,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (awaiting) ...[
            Text(
              left == 0
                  ? 'Time is up'
                  : day == null
                  ? 'Drop off before ${hubCloseLabel(r.expiresAt)}'
                  : 'Drop off ${hubOnDay(day)}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (day != null)
              Text(
                '${hubDayDate(day)} ┬╖ any time ${r.hours.textOn(day)}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            if (today && left > 0 && left <= 120)
              Text(
                'Closes in ${hubDuration(left)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ] else
            Text(
              r.status == HubDropOffStatus.received
                  ? 'Received ${hubDateTime(r.receivedAt)} ┬╖ ${hubKg(r.receivedKg ?? r.reservedKg)}'
                  : hubDropOffLabel(r.status),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final String text;
  const _Step(this.number, this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 11,
          backgroundColor: HubColors.softGreen,
          child: Text(
            '$number',
            style: const TextStyle(
              fontSize: 12,
              color: HubColors.green,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
