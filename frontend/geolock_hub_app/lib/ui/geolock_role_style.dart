/// NGO / Donor presentation layer that follows the Hub Admin visual language
/// (`hub_admin/hub_widgets.dart`): mint background, flat white cards with a
/// 16 px radius and a thin `HubColors.line` border, w800 ink headings and
/// tinted status pills.
///
/// It is applied by wrapping individual NGO / Donor pages in [GeoRoleTheme],
/// so Hub Admin pages and the global app theme are NOT changed. Presentation
/// only: nothing here changes data, permissions or actions.
library;

import 'package:flutter/material.dart';

import '../hub_admin/hub_widgets.dart' show HubColors;
import '../routing/reconciliation_status.dart';

/// Semantic tones taken from Hub Admin's [HubColors].
class GeoTone {
  GeoTone._();
  static const danger = HubColors.red;
  static const warning = HubColors.amber;
  static const info = HubColors.blue;
  static const success = HubColors.green;
  static const neutral = HubColors.muted;
}

/// Marks a subtree as an NGO / Donor page so shared widgets (for example the
/// reconciliation summary, which Hub Admin also embeds) can opt into the role
/// styling without changing their appearance on Hub Admin pages.
class GeoRoleScope extends InheritedWidget {
  const GeoRoleScope({super.key, required super.child});

  static bool active(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GeoRoleScope>() != null;

  @override
  bool updateShouldNotify(GeoRoleScope oldWidget) => false;
}

/// Hub-Admin-style theme for one NGO / Donor page.
class GeoRoleTheme extends StatelessWidget {
  const GeoRoleTheme({super.key, required this.child});
  final Widget child;

  static ThemeData of(ThemeData base) => base.copyWith(
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: HubColors.line),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Colors.white,
      selectedColor: HubColors.softGreen,
      checkmarkColor: HubColors.green,
      side: const BorderSide(color: HubColors.line),
      shape: const StadiumBorder(),
      labelStyle: const TextStyle(
        color: HubColors.ink,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: base.dividerTheme.copyWith(color: HubColors.line),
    listTileTheme: base.listTileTheme.copyWith(iconColor: HubColors.green),
  );

  @override
  Widget build(BuildContext context) => GeoRoleScope(
    child: Theme(data: of(Theme.of(context)), child: child),
  );
}

/// Shared tone for a status label, so NGO and Donor screens colour the same
/// state the same way. Unknown labels use the neutral ink tone.
Color geoStatusTone(String label) {
  switch (label) {
    case GeoLockStatusText.reconciliationRequired:
    case 'Next pickup — blocked':
    case 'Status Needs Review':
      return HubColors.red;
    case GeoLockStatusText.actionRequired:
    case GeoLockStatusText.expiredAwaitingRecovery:
    case 'Expired':
      return HubColors.amber;
    case GeoLockStatusText.awaitingCounterpart:
    case GeoLockStatusText.underReview:
    case 'Current pickup':
      return HubColors.blue;
    case GeoLockStatusText.resolvedCollected:
    case 'Completed pickup':
    case 'Collected':
    case 'Completed':
    case 'Active':
    case 'Next pickup — not started':
      return HubColors.green;
    case GeoLockStatusText.resolvedReleased:
    case GeoLockStatusText.expiredReleased:
    case 'Not collected — resolved':
    case 'Released':
    case 'Cancelled':
    case 'Removed from route — claim kept':
    case 'Not started':
    case 'Upcoming pickup':
      return HubColors.muted;
  }
  if (label.startsWith('Handover · ')) {
    return geoStatusTone(label.substring('Handover · '.length));
  }
  return HubColors.ink;
}

IconData? _toneIcon(Color tone) {
  if (tone == HubColors.red) return Icons.report_gmailerrorred_outlined;
  if (tone == HubColors.amber) return Icons.schedule;
  if (tone == HubColors.blue) return Icons.hourglass_top;
  if (tone == HubColors.green) return Icons.check_circle_outline;
  return null;
}

/// Tinted status pill in the Hub Admin style. It is still a [Chip], so its
/// semantics and finders are unchanged.
class GeoStatusChip extends StatelessWidget {
  const GeoStatusChip(this.label, {super.key, this.tone});
  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final color = tone ?? geoStatusTone(label);
    final icon = _toneIcon(color);
    return Chip(
      avatar: icon == null ? null : Icon(icon, size: 16, color: color),
      label: Text(label),
      labelStyle: TextStyle(color: color, fontWeight: FontWeight.w700),
      backgroundColor: color.withValues(alpha: .12),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Tinted, bordered notice card (warnings, blocked stops, reconciliation).
class GeoNoticeCard extends StatelessWidget {
  const GeoNoticeCard({
    super.key,
    required this.tone,
    required this.child,
    this.padding = const EdgeInsets.all(12),
  });
  final Color tone;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    color: Color.alphaBlend(tone.withValues(alpha: .07), Colors.white),
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: tone.withValues(alpha: .35)),
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// Card title style matching Hub Admin (`titleMedium`, w800, ink).
TextStyle? geoTitleStyle(BuildContext context) => Theme.of(
  context,
).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: HubColors.ink);

/// Section heading matching `HubSectionTitle` (w800 ink title, muted subtitle).
class GeoSectionTitle extends StatelessWidget {
  const GeoSectionTitle(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
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
  );
}
