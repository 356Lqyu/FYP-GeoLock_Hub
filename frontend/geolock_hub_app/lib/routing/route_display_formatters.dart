/// Presentation only. Never use formatted values for routing or authorization.
String routeStatusLabel(Object? status) => switch (status) {
  'AUTHORISED' => 'Authorised',
  'IN_PROGRESS' => 'In progress',
  'COMPLETED' => 'Completed',
  'CANCELLED' => 'Cancelled',
  'ABANDONED' => 'Abandoned',
  _ => 'Status unavailable',
};

String routeMytTime(Object? value, {String missing = 'Time unavailable'}) {
  DateTime? instant;
  if (value is DateTime) {
    instant = value.toUtc();
  } else if (value is String) {
    final text = value.trim();
    // Reject timezone-less strings rather than interpret them in the phone zone.
    if (!RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(text)) return missing;
    instant = DateTime.tryParse(text)?.toUtc();
  }
  if (instant == null) return missing;
  // Asia/Kuala_Lumpur is UTC+08:00 for these contemporary routing timestamps.
  // Render the shifted fields directly; never call toLocal() on the phone.
  final myt = instant.add(const Duration(hours: 8));
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${myt.day} ${months[myt.month - 1]} ${myt.year}, ${two(myt.hour)}:${two(myt.minute)} MYT';
}

String routeDisplayAddress(Object? value) {
  if (value is! String || value.trim().isEmpty) return 'Address unavailable';
  final components = <String>[];
  final seen = <String>{};
  for (final raw in value.split(',')) {
    final part = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (part.isNotEmpty && seen.add(part.toLowerCase())) components.add(part);
  }
  final postcodes = <String>{}, localities = <String>{};
  for (final part in components) {
    final match = RegExp(r'^(\d{5})\s+(.+)$').firstMatch(part);
    if (match != null) {
      postcodes.add(match[1]!);
      localities.add(match[2]!.toLowerCase());
    }
  }
  // Remove only exact standalone components already present in a postcode/city
  // pair. Do not infer abbreviations, strip unit numbers, or rewrite street text.
  return components
      .where(
        (p) => !postcodes.contains(p) && !localities.contains(p.toLowerCase()),
      )
      .join(', ');
}

String routeLoadText(Object? value) {
  if (value is! num || !value.isFinite) return '—';
  return value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}
