// Colours, formatting and small widgets shared by the hub screens.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'hub_service.dart';

// Colours, text and labels

class HubColors {
  HubColors._();
  static const green = Color(0xff2f806c);
  static const mint = Color(0xffedfbf7);
  static const softGreen = Color(0xffdff2eb);
  static const ink = Color(0xff102c2a);
  static const muted = Color(0xff687a73);
  static const line = Color(0xffe2ebe6);
  static const blue = Color(0xff2670a7);
  static const amber = Color(0xff9a6a12);
  static const red = Color(0xffa84a4a);
}

// Numbers and time

/// "4 kg", "4.5 kg", "18.25 kg".
String hubKg(num value) {
  final text = value.toStringAsFixed(2);
  final trimmed = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return '$trimmed kg';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// "14:05" in the phone's local time.
String hubClock(DateTime? time) =>
    time == null ? '—' : '${_two(time.hour)}:${_two(time.minute)}';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today 14:05", "Yesterday 09:10" or "3 Oct 14:05".
String hubDateTime(DateTime? time) {
  if (time == null) return '—';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today ${hubClock(time)}';
  if (diff == 1) return 'Yesterday ${hubClock(time)}';
  return '${time.day} ${_months[time.month - 1]} ${hubClock(time)}';
}

/// "just now", "5 min ago", "3 h ago", "2 days ago".
String hubAgo(DateTime? time) {
  if (time == null) return '';
  final minutes = DateTime.now().difference(time).inMinutes;
  if (minutes < 1) return 'just now';
  if (minutes < 60) return '$minutes min ago';
  if (minutes < 48 * 60) return '${minutes ~/ 60} h ago';
  return '${minutes ~/ (24 * 60)} days ago';
}

/// "45 min", "2 h 15 min", "3 days".
String hubDuration(int minutes) {
  if (minutes < 60) return '$minutes min';
  if (minutes < 48 * 60) {
    final rest = minutes % 60;
    return rest == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h $rest min';
  }
  return '${minutes ~/ (24 * 60)} days';
}

/// Minutes left until [deadline] (never negative).
int hubMinutesLeft(DateTime? deadline) {
  if (deadline == null) return 0;
  final seconds = deadline.difference(DateTime.now()).inSeconds;
  return seconds <= 0 ? 0 : (seconds / 60).ceil();
}

/// Icon for each storage need (hubNeedKeys).
const hubNeedIcons = {
  'food_safe_storage': Icons.kitchen_outlined,
  'fragile_shelving': Icons.wine_bar_outlined,
  'lockable_storeroom': Icons.lock_outline,
  'vehicle_access': Icons.local_shipping_outlined,
};

// Database codes in plain words

const _reasonText = {
  'HUB_INACTIVE': 'Hub is not active',
  'NO_ROAD_ROUTE': 'No road route from your pickup point',
  'CATEGORY_NOT_ACCEPTED': 'Does not accept this category',
  'CAPACITY_STATE_INVALID': 'Hub capacity record needs checking',
  'INSUFFICIENT_CAPACITY': 'Not enough free space',
  'HOURS_NOT_SET': 'Opening hours not set yet',
  'HUB_CLOSED_ON_DROPOFF_DAY': 'Closed that day (or open less than 30 minutes)',
  'HUB_NOT_VERIFIED': 'Hub registration not finished',
};

/// Why a hub cannot be chosen (reason codes from get_hub_options).
String hubReasonText(String code) => _reasonText[code] ?? code.replaceAll('_', ' ');

const _errorText = {
  'ACCEPTED_CATEGORIES_REQUIRED': 'Choose at least one category.',
  'UNKNOWN_OR_INACTIVE_CATEGORY': 'A selected category is no longer available.',
  'INVALID_OPERATING_HOURS': 'Opening hours are not valid.',
  'HUB_NOT_FOUND_OR_FORBIDDEN': 'You do not manage this hub.',
  'HUB_ADMIN_ONLY': 'Only hub administrators can open this page.',
  'HUB_CLOSED_ON_DROPOFF_DAY':
      'This hub is closed on that day, or open for less than 30 more minutes. Choose another day.',
  'DROPOFF_DATE_OUT_OF_RANGE': 'Choose a drop-off day from today up to 6 days ahead.',
  'HUB_HOURS_NOT_SET': 'This hub has not set its opening hours yet.',
  'HUB_CAPACITY_EXCEEDED': 'This hub no longer has enough free space.',
  'CATEGORY_NOT_ACCEPTED': 'This hub does not accept your donation category.',
  'HUB_INACTIVE': 'This hub is not active.',
  'HUB_RESERVATION_STILL_ACTIVE':
      'Your current booking is still active. Drop off on the booked day, or wait until it ends.',
  'HUB_RESERVATION_NOT_EXPIRED':
      'Your current booking is still active. Drop off on the booked day, or wait until it ends.',
  'DONATION_NOT_HUB_ELIGIBLE': 'This donation can no longer be taken to a hub.',
  'DONATION_HAS_PHYSICAL_CUSTODY': 'The hub has already received this donation.',
  'RESERVATION_NOT_ACTIVE':
      'This booking has ended or was cancelled. The donor must book again.',
  'RECEIVED_WEIGHT_EXCEEDS_RESERVATION':
      'The weight must be more than 0 and not more than the booked weight.',
  'INVALID_DONATION_STATE': 'This donation is no longer waiting for drop-off.',
  'INVALID_BATCH_COUNT': 'The batch does not have an allowed number of donations.',
  'BATCH_WEIGHT_EXCEEDED': 'The batch is over the weight limit.',
  'BATCH_CATEGORY_INCOMPATIBLE': 'All donations in a batch must be one category.',
  'DONATION_NOT_STORED_AT_HUB': 'A selected donation is no longer stored at this hub.',
  'DONATION_ALREADY_BATCHED': 'A selected donation is already in a batch.',
  'DONATION_NOT_AT_THIS_HUB': 'This donation was not booked at this hub.',
  'RECONCILIATION_NOT_OPEN': 'This handover case is already closed.',
  'RECONCILIATION_PARTICIPANT_ONLY': 'Only the hub and the NGO can answer this case.',
  'HUB_NOT_VERIFIED': 'This hub is not active yet: its admin has not finished registration.',
  'HUB_ADMIN_ALREADY_HAS_HUB':
      'This account already has a hub. Each account can run one hub.',
  'CONTACT_PHONE_IN_USE':
      'This phone number is already used by another hub admin account.',
  'HUB_TOO_CLOSE_TO_EXISTING_HUB':
      'Another hub is already registered within 200 m of this location.',
  'INVALID_CONTACT_PHONE': 'Enter a phone number with 9–15 digits.',
  'HUB_NAME_AND_ADDRESS_REQUIRED': 'Enter the hub name and choose its location.',
  'CAPACITY_MUST_BE_50_TO_250_KG': 'Capacity must be from 50 to 250 kg.',
  'HUB_LOCATION_NOT_ROUTABLE':
      'We could not find a road near this pin. Move the pin to the hub entrance by the road.',
  'OPERATIONAL_ROAD_COVERAGE_UNAVAILABLE':
      'Road data is not available right now. Try again later.',
  'HUB_LOCATION_NODE_MISMATCH':
      'The road point for this location changed while saving. Try again.',
  'HUB_HAS_ACTIVE_INVENTORY_OR_COMMITMENTS':
      'Location and capacity cannot change while the hub has stored donations, '
      'active drop-offs or open batches. You can still rename it.',
  'INVALID_HUB_COORDINATES': 'Choose a valid hub location on the map.',
};

/// Plain message for a failed hub call; keeps the database code in brackets.
String hubErrorMessage(Object error) {
  final text = error is PostgrestException ? error.message : '$error';
  for (final entry in _errorText.entries) {
    if (text.contains(entry.key)) return '${entry.value} (${entry.key})';
  }
  if (text.contains('SocketException') || text.contains('ClientException')) {
    return 'No connection. Check the internet and try again.';
  }
  return text.replaceFirst('Exception: ', '');
}

// Status labels

String hubDropOffLabel(HubDropOffStatus status) => switch (status) {
  HubDropOffStatus.awaiting => 'Awaiting drop-off',
  HubDropOffStatus.received => 'Received',
  HubDropOffStatus.expired => 'Not dropped off',
  HubDropOffStatus.cancelled => 'Cancelled by donor',
  HubDropOffStatus.other => 'Unknown',
};

Color hubDropOffColor(HubDropOffStatus status) => switch (status) {
  HubDropOffStatus.awaiting => HubColors.blue,
  HubDropOffStatus.received => HubColors.green,
  HubDropOffStatus.expired => HubColors.amber,
  HubDropOffStatus.cancelled => HubColors.red,
  HubDropOffStatus.other => HubColors.muted,
};

String hubStageLabel(HubListingStage stage) => switch (stage) {
  HubListingStage.waitingForNgo => 'Waiting for NGO',
  HubListingStage.claimed => 'Claimed',
  HubListingStage.pickupInProgress => 'NGO on the way',
  HubListingStage.collected => 'Collected',
  HubListingStage.handoverReview => 'Confirm handover',
  HubListingStage.cancelled => 'Cancelled',
};

Color hubStageColor(HubListingStage stage) => switch (stage) {
  HubListingStage.waitingForNgo => HubColors.green,
  HubListingStage.claimed => HubColors.blue,
  HubListingStage.pickupInProgress => HubColors.blue,
  HubListingStage.collected => HubColors.muted,
  HubListingStage.handoverReview => HubColors.amber,
  HubListingStage.cancelled => HubColors.red,
};

IconData hubStageIcon(HubListingStage stage) => switch (stage) {
  HubListingStage.waitingForNgo => Icons.campaign_outlined,
  HubListingStage.claimed => Icons.assignment_turned_in_outlined,
  HubListingStage.pickupInProgress => Icons.local_shipping_outlined,
  HubListingStage.collected => Icons.task_alt,
  HubListingStage.handoverReview => Icons.help_outline,
  HubListingStage.cancelled => Icons.cancel_outlined,
};

/// Icon and colour of one notification type (get_my_hub_activity.event_type).
(IconData, Color) hubActivityStyle(String type) => switch (type) {
  'DROP_OFF_BOOKED' => (Icons.event_available_outlined, HubColors.blue),
  'DROP_OFF_EXPIRED' => (Icons.timer_off_outlined, HubColors.amber),
  'DROP_OFF_CANCELLED' => (Icons.event_busy_outlined, HubColors.red),
  'DONATION_RECEIVED' => (Icons.move_to_inbox_outlined, HubColors.green),
  'BATCH_PUBLISHED' => (Icons.campaign_outlined, HubColors.green),
  'BATCH_CLAIMED' => (Icons.assignment_turned_in_outlined, HubColors.blue),
  'PICKUP_STARTED' => (Icons.local_shipping_outlined, HubColors.blue),
  'BATCH_COLLECTED' => (Icons.task_alt, HubColors.green),
  'CLAIM_ENDED' => (Icons.undo, HubColors.amber),
  'HANDOVER_REVIEW' => (Icons.help_outline, HubColors.amber),
  _ => (Icons.notifications_none, HubColors.muted),
};

// Widgets

class HubCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final Color? borderColor;

  const HubCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
    this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    elevation: 0,
    color: color ?? Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: borderColor ?? HubColors.line),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    ),
  );
}

/// Section heading with an optional action on the right.
class HubSectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;

  const HubSectionTitle(
    this.title, {
    super.key,
    this.subtitle,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: HubColors.ink,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: HubColors.muted),
                ),
            ],
          ),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ],
    ),
  );
}

/// Coloured pill with a short status.
class HubStatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const HubStatusChip(this.label, {super.key, required this.color, this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

/// Donation or batch photo from private storage (signed URL), with a placeholder.
class HubPhoto extends StatelessWidget {
  final String? path;
  final double size;
  final IconData placeholderIcon;

  const HubPhoto(
    this.path, {
    super.key,
    this.size = 56,
    this.placeholderIcon = Icons.inventory_2_outlined,
  });

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: HubColors.softGreen,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(placeholderIcon, color: HubColors.green, size: size * .45),
    );
    final p = path;
    if (p == null || p.isEmpty) return placeholder();
    return FutureBuilder<String>(
      future: HubService.signedPhotoUrl(p),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return placeholder();
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            snapshot.data!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder(),
          ),
        );
      },
    );
  }
}

/// Number tile for dashboards.
class HubStatTile extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const HubStatTile({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    this.color = HubColors.green,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => HubCard(
    onTap: onTap,
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: HubColors.ink,
                ),
              ),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: HubColors.muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Used / free capacity bar.
class HubCapacityBar extends StatelessWidget {
  final double usedKg;
  final double capacityKg;

  const HubCapacityBar({super.key, required this.usedKg, required this.capacityKg});

  @override
  Widget build(BuildContext context) {
    final ratio = capacityKg <= 0 ? 0.0 : (usedKg / capacityKg).clamp(0.0, 1.0);
    final color = ratio >= .9
        ? HubColors.red
        : ratio >= .7
        ? HubColors.amber
        : HubColors.green;
    final free = (capacityKg - usedKg).clamp(0, capacityKg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${(ratio * 100).round()}% used',
              style: TextStyle(fontWeight: FontWeight.w700, color: color),
            ),
            const Spacer(),
            Text(
              '${hubKg(free)} free of ${hubKg(capacityKg)}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: HubColors.muted),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 10,
            color: color,
            backgroundColor: HubColors.softGreen,
          ),
        ),
      ],
    );
  }
}

/// Label / value line inside detail cards.
class HubInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const HubInfoRow(this.icon, this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: HubColors.muted),
        const SizedBox(width: 10),
        SizedBox(
          width: 110,
          child: Text(label, style: const TextStyle(color: HubColors.muted)),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
}

/// Friendly empty list message.
class HubEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const HubEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
    child: Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
            color: HubColors.softGreen,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 30, color: HubColors.green),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        const SizedBox(height: 4),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: HubColors.muted),
        ),
        if (actionLabel != null) ...[
          const SizedBox(height: 14),
          FilledButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ],
    ),
  );
}

/// Error message with a retry button.
class HubErrorState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const HubErrorState({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => HubEmptyState(
    icon: Icons.cloud_off_outlined,
    title: 'Could not load',
    message: hubErrorMessage(error),
    actionLabel: 'Try again',
    onAction: onRetry,
  );
}

/// Loads [future] and shows a pull-to-refresh list built by [builder].
/// Loading and error states are handled here so pages stay short.
class HubRefreshList<T> extends StatelessWidget {
  final Future<T> future;
  final Future<void> Function() onRefresh;
  final List<Widget> Function(BuildContext context, T data) builder;
  final EdgeInsetsGeometry padding;

  const HubRefreshList({
    super.key,
    required this.future,
    required this.onRefresh,
    required this.builder,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 32),
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: future,
    builder: (context, snapshot) {
      final List<Widget> children;
      if (snapshot.hasError) {
        children = [HubErrorState(error: snapshot.error!, onRetry: onRefresh)];
      } else if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      } else if (snapshot.connectionState == ConnectionState.waiting) {
        // A new request (e.g. another day) is loading: keep the old content visible but
        // faded and untappable, so it is not mistaken for the new result.
        children = [
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          for (final child in builder(context, snapshot.data as T))
            IgnorePointer(child: Opacity(opacity: .4, child: child)),
        ];
      } else {
        children = builder(context, snapshot.data as T);
      }
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: padding,
          children: children,
        ),
      );
    },
  );
}

/// Snackbar helper.
void hubToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Yes / no confirmation dialog.
Future<bool> hubConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}
