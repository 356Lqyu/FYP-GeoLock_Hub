import 'package:flutter/material.dart';

enum StatusTimelineTone { completed, current, pending, attention }

class StatusTimelineEvent {
  final String title;
  final DateTime? occurredAt;
  final String? detail;
  final StatusTimelineTone tone;

  const StatusTimelineEvent({
    required this.title,
    this.occurredAt,
    this.detail,
    this.tone = StatusTimelineTone.completed,
  });
}

/// A presentation-only timeline. It never derives historical events from a
/// later current state; callers must provide recorded events explicitly.
class GeoStatusTimeline extends StatelessWidget {
  final String title;
  final String? currentStatus;
  final List<StatusTimelineEvent> events;
  final List<String> pendingMilestones;
  final bool loading;
  final String? errorMessage;
  final String emptyMessage;

  const GeoStatusTimeline({
    super.key,
    required this.title,
    this.currentStatus,
    this.events = const [],
    this.pendingMilestones = const [],
    this.loading = false,
    this.errorMessage,
    this.emptyMessage = 'No recorded history is available.',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (currentStatus != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xffe1f3ed),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xff2f806c)),
                ),
                child: Text('Current status · $currentStatus'),
              ),
            if (loading)
              const LinearProgressIndicator()
            else if (errorMessage != null)
              Text(errorMessage!, style: theme.textTheme.bodyMedium)
            else ...[
              if (events.isEmpty && currentStatus == null)
                Text(emptyMessage, style: theme.textTheme.bodyMedium),
              for (var index = 0; index < events.length; index++)
                _TimelineRow(
                  event: events[index],
                  isLast:
                      index == events.length - 1 && pendingMilestones.isEmpty,
                ),
              for (var index = 0; index < pendingMilestones.length; index++)
                _TimelineRow(
                  event: StatusTimelineEvent(
                    title: pendingMilestones[index],
                    tone: StatusTimelineTone.pending,
                  ),
                  isLast: index == pendingMilestones.length - 1,
                ),
              if (events.isEmpty && currentStatus != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(emptyMessage, style: theme.textTheme.bodySmall),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

bool shouldShowHubReservationSection(String? collectionPath) =>
    collectionPath == 'HUB_COLLECTION';

class _TimelineRow extends StatelessWidget {
  final StatusTimelineEvent event;
  final bool isLast;

  const _TimelineRow({required this.event, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final color = switch (event.tone) {
      StatusTimelineTone.completed => const Color(0xff2f806c),
      StatusTimelineTone.current => const Color(0xff0c6656),
      StatusTimelineTone.pending => Colors.grey,
      StatusTimelineTone.attention => Colors.deepOrange,
    };
    final icon = switch (event.tone) {
      StatusTimelineTone.completed => Icons.check_circle,
      StatusTimelineTone.current => Icons.radio_button_checked,
      StatusTimelineTone.pending => Icons.radio_button_unchecked,
      StatusTimelineTone.attention => Icons.error_outline,
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Icon(icon, size: 18, color: color),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: color.withValues(alpha: .35),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: TextStyle(
                      fontWeight: event.tone == StatusTimelineTone.current
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: event.tone == StatusTimelineTone.pending
                          ? Colors.black54
                          : null,
                    ),
                  ),
                  if (event.detail != null) Text(event.detail!),
                  if (event.occurredAt != null)
                    Text(_formatTimestamp(context, event.occurredAt!)),
                  if (event.tone == StatusTimelineTone.pending)
                    const Text(
                      'Pending',
                      style: TextStyle(color: Colors.black54),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTimestamp(BuildContext context, DateTime timestamp) {
  final local = timestamp.toLocal();
  final date = MaterialLocalizations.of(context).formatMediumDate(local);
  final time = MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay.fromDateTime(local));
  return '$date · $time';
}

String? statusTimestampText(BuildContext context, Object? value) {
  if (value == null) return null;
  final parsed = value is DateTime
      ? value
      : DateTime.tryParse(value.toString());
  if (parsed == null) return null;
  final local = parsed.toLocal();
  final date = MaterialLocalizations.of(context).formatMediumDate(local);
  final time = MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay.fromDateTime(local));
  return '$date · $time';
}

String friendlyWorkflowStatus(Object? value) {
  final status = value?.toString();
  const labels = {
    'SUBMITTED': 'Awaiting Hub Selection',
    'VALIDATED': 'Validation complete',
    'READY_FOR_PICKUP': 'Ready for Pickup',
    'HUB_ASSIGNED': 'Hub Assigned',
    'AT_HUB': 'At Hub',
    'BATCHED': 'Included in a Batch',
    'PICKUP_IN_PROGRESS': 'Pickup in Progress',
    'COLLECTED': 'Collected',
    'DELIVERED': 'Delivered',
    'CANCELLED': 'Cancelled',
    'AVAILABLE': 'Available',
    'CLAIMED': 'Claimed',
    'CLOSED': 'Closed',
    'ACTIVE': 'Active',
    'EXPIRED': 'Expired',
    'RELEASED': 'Released',
    'COMPLETED': 'Completed',
    'RECONCILIATION_REQUIRED': 'Needs Reconciliation',
    'CONSUMED': 'Used for Receipt',
    'STORED': 'Stored at Hub',
    'PUBLISHED': 'Published',
    'DRAFT': 'Draft',
    'CONFIRMED': 'Confirmed',
    'PLANNED': 'Planned',
    'DISPATCHED': 'Pickup Started',
    'STALE': 'No Longer Active',
    'PENDING_NODE': 'Road Check Pending',
    'UNVERIFIED': 'Not Verified for Routing',
    'OPEN': 'Open',
    'MANUAL_REVIEW': 'Manual Review',
    'RESOLVED_COLLECTED': 'Resolved · Collected',
    'RESOLVED_RELEASED': 'Resolved · Released',
  };
  if (status == null || status.isEmpty) return 'Not available';
  return labels[status] ?? status.replaceAll('_', ' ').toLowerCase();
}

String reservationStatusLabel({
  required Object? recordedStatus,
  required Object? effectiveStatus,
  required bool isLatest,
}) {
  if (isLatest && effectiveStatus != null) {
    final effective = effectiveStatus.toString();
    if (effective == 'STATUS_UNVERIFIED') {
      return 'Recorded as Active · current validity not available';
    }
    return friendlyWorkflowStatus(effective);
  }
  if (recordedStatus == 'ACTIVE') {
    return 'Recorded as Active · current validity not available';
  }
  return friendlyWorkflowStatus(recordedStatus);
}

List<StatusTimelineEvent> recordedAuditEvents(
  Iterable<Map<String, dynamic>> rows, {
  required Set<String> allowedEventTypes,
}) {
  const eventLabels = {
    'CREATE_VALIDATE': 'Donation submitted',
    'RESERVE_HUB': 'Hub reservation updated',
    'EXPIRE_HUB_RESERVATION': 'Hub reservation expired',
    'CONFIRM_HUB_RECEIPT': 'Donation received at hub',
    'CANCEL_DONATION': 'Donation cancelled',
    'CANCEL_CLAIM': 'Claim released',
    'START_PICKUP': 'Pickup started',
    'COMPLETE_PICKUP': 'Handover completed',
    'LEASE_RECOVERY': 'Claim recovery processed',
    'CLAIM_RECONCILIATION_EVIDENCE': 'Reconciliation updated',
    'PUBLISH_BATCH': 'Batch published',
  };
  final events = <StatusTimelineEvent>[];
  for (final row in rows) {
    final type = row['event_type']?.toString();
    final label = eventLabels[type];
    if (type == null || label == null || !allowedEventTypes.contains(type)) {
      continue;
    }
    final rawTime = row['occurred_at']?.toString();
    final outcome = row['outcome']?.toString();
    final state = row['resulting_state']?.toString();
    final detailParts = <String>[];
    if (state != null && state.isNotEmpty) {
      detailParts.add(friendlyWorkflowStatus(state));
    }
    if (outcome == 'REJECTED') {
      detailParts.add('Not accepted');
    }
    final timestamp = rawTime == null ? null : DateTime.tryParse(rawTime);
    events.add(
      StatusTimelineEvent(
        title: label,
        occurredAt: timestamp,
        detail: detailParts.isEmpty ? null : detailParts.join(' · '),
        tone: outcome == 'REJECTED'
            ? StatusTimelineTone.attention
            : StatusTimelineTone.completed,
      ),
    );
  }
  return events;
}

List<String> pendingDonationMilestones({
  required String? collectionPath,
  required String? currentStatus,
}) {
  if (currentStatus == 'CANCELLED' || currentStatus == 'COLLECTED') {
    return const [];
  }
  final path = collectionPath == 'HUB_COLLECTION'
      ? const [
          'HUB_ASSIGNED',
          'AT_HUB',
          'BATCHED',
          'PICKUP_IN_PROGRESS',
          'COLLECTED',
        ]
      : const ['READY_FOR_PICKUP', 'PICKUP_IN_PROGRESS', 'COLLECTED'];
  final index = path.indexOf(currentStatus ?? '');
  final start = index >= 0 ? index + 1 : 0;
  return path.skip(start).map(friendlyWorkflowStatus).toList();
}
