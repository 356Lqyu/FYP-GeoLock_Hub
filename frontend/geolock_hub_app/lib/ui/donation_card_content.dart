import 'package:flutter/material.dart';

class DonationCardContent extends StatelessWidget {
  const DonationCardContent({
    super.key,
    required this.title,
    required this.badge,
    required this.thumbnail,
    required this.facts,
    this.titleStyle,
    this.trailing,
    this.footer,
  });

  final String title;
  final Widget badge;
  final Widget thumbnail;
  final Map<String, String> facts;
  final TextStyle? titleStyle;
  final Widget? trailing;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(title, style: titleStyle)),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .52,
                ),
                child: badge,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            thumbnail,
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 12.0;
                  final columnWidth = constraints.maxWidth >= 176
                      ? (constraints.maxWidth - gap) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: gap,
                    runSpacing: 8,
                    children: [
                      for (final fact in facts.entries)
                        SizedBox(
                          width: columnWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(fact.key, style: textTheme.labelSmall),
                              Text(fact.value, style: textTheme.bodySmall),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            ?trailing,
          ],
        ),
        if (footer != null) ...[const SizedBox(height: 8), footer!],
      ],
    );
  }
}

String donationCardDate(Object? date) {
  final parsed = DateTime.tryParse('$date');
  return parsed == null
      ? 'Date unavailable'
      : '${parsed.day}/${parsed.month}/${parsed.year}';
}
