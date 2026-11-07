import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub_admin_controller.dart';
import 'hub_donation_detail_page.dart';
import 'hub_listing_page.dart';
import 'hub_service.dart';
import 'hub_widgets.dart';

/// Remembers, per hub, the time of the newest notification the admin has seen.
class HubNotificationStore {
  HubNotificationStore._();

  static String _key(String hubId) => 'geolock.hub.notifications_seen.$hubId';

  static Future<DateTime?> lastSeen(String hubId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_key(hubId));
      return value == null ? null : DateTime.tryParse(value);
    } catch (_) {
      return null;
    }
  }

  static Future<void> markSeen(String hubId, DateTime newest) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(hubId), newest.toUtc().toIso8601String());
    } catch (_) {
      // Unread markers are a convenience; ignore storage problems.
    }
  }

  /// Number of notifications newer than the last one seen.
  static Future<int> unreadCount(String hubId, List<HubActivity> items) async {
    final seen = await lastSeen(hubId);
    return items
        .where(
          (a) =>
              a.occurredAt != null &&
              (seen == null || a.occurredAt!.isAfter(seen)),
        )
        .length;
  }
}

class HubNotificationPage extends StatefulWidget {
  final HubAdminController controller;
  const HubNotificationPage({super.key, required this.controller});

  @override
  State<HubNotificationPage> createState() => _HubNotificationPageState();
}

class _HubNotificationPageState extends State<HubNotificationPage> {
  late Future<List<HubActivity>> _items = _load();
  DateTime? _seenBefore;

  String get _hubId => widget.controller.hubId;

  Future<List<HubActivity>> _load() async {
    _seenBefore ??= await HubNotificationStore.lastSeen(_hubId);
    final items = await HubService.activity(_hubId, limit: 100);
    final newest = items.isEmpty ? null : items.first.occurredAt;
    if (newest != null) {
      await HubNotificationStore.markSeen(_hubId, newest);
      widget.controller.unreadCount = 0;
    }
    return items;
  }

  Future<void> _refresh() async {
    setState(() => _items = _load());
    await _items;
  }

  bool _isNew(HubActivity a) =>
      a.occurredAt != null &&
      (_seenBefore == null || a.occurredAt!.isAfter(_seenBefore!));

  void _open(HubActivity a) {
    final hub = widget.controller.hub;
    if (a.donationId != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HubDonationDetailPage(
            controller: widget.controller,
            donationId: a.donationId!,
          ),
        ),
      );
    } else if (a.batchId != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HubListingDetailPage(
            controller: widget.controller,
            batchId: a.batchId!,
            hubName: hub.name,
          ),
        ),
      );
    }
  }

  String _dayGroup(DateTime? time) {
    if (time == null) return 'Earlier';
    final now = DateTime.now();
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(time.year, time.month, time.day)).inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7) return 'This week';
    return 'Earlier';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notifications')),
    body: HubRefreshList<List<HubActivity>>(
      future: _items,
      onRefresh: _refresh,
      builder: (context, items) {
        if (items.isEmpty) {
          return const [
            HubEmptyState(
              icon: Icons.notifications_none,
              title: 'No notifications yet',
              message:
                  'You will see drop-off bookings, received donations and NGO '
                  'pickups here.',
            ),
          ];
        }
        final widgets = <Widget>[];
        String? group;
        for (final a in items) {
          final g = _dayGroup(a.occurredAt);
          if (g != group) {
            group = g;
            widgets.add(HubSectionTitle(g));
          }
          widgets.add(
            _NotificationTile(
              activity: a,
              isNew: _isNew(a),
              onTap: () => _open(a),
            ),
          );
        }
        return widgets;
      },
    ),
  );
}

class _NotificationTile extends StatelessWidget {
  final HubActivity activity;
  final bool isNew;
  final VoidCallback onTap;

  const _NotificationTile({
    required this.activity,
    required this.isNew,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, color) = hubActivityStyle(activity.type);
    return HubCard(
      onTap: onTap,
      color: isNew ? const Color(0xfff6fcfa) : null,
      borderColor: isNew ? color.withValues(alpha: .35) : null,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        activity.title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (isNew)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(activity.message),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      '${hubDateTime(activity.occurredAt)} · ${hubAgo(activity.occurredAt)}',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: HubColors.muted),
                    ),
                    const Spacer(),
                    if (activity.needsAction)
                      const HubStatusChip(
                        'Action needed',
                        color: HubColors.amber,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
