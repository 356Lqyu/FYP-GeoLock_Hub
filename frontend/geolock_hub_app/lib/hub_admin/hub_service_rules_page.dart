// Accepted categories, weekly opening hours and storage facilities.
import 'package:flutter/material.dart';

import 'hub_service.dart';
import 'hub_widgets.dart';

class HubServiceRulesPage extends StatefulWidget {
  final HubSummary hub;

  /// Hours typed at sign-up; used when the hub has no saved hours yet.
  final HubOperatingHours? initialHours;

  /// Categories ticked at sign-up; used when the hub accepts none yet.
  final Set<String>? initialCategoryIds;
  const HubServiceRulesPage({
    super.key,
    required this.hub,
    this.initialHours,
    this.initialCategoryIds,
  });

  @override
  State<HubServiceRulesPage> createState() => _HubServiceRulesPageState();
}

class _HubServiceRulesPageState extends State<HubServiceRulesPage> {
  late Future<HubServiceRules> _rules = _load();
  final Set<String> _accepted = {};
  HubOperatingHours _hours = HubOperatingHours.fromJson(null);
  List<DonationCategoryInfo> _categories = const [];
  HubFacilities? _facilities;
  bool _saving = false;

  Future<HubServiceRules> _load() async {
    final rules = await HubService.serviceRules(widget.hub.id);
    // Storage needs of each category; without them the list still works, just no hints.
    final needs = <String, DonationCategoryInfo>{};
    try {
      for (final c in await HubService.categories()) {
        needs[c.id] = c;
      }
    } catch (_) {}
    _categories = [
      for (final c in rules.categories)
        needs[c.id] ??
            DonationCategoryInfo.fromJson({
              'category_id': c.id,
              'category_name': c.name,
            }),
    ];
    final ids = _categories.map((c) => c.id).toSet();
    _accepted
      ..clear()
      ..addAll(rules.categories.where((c) => c.accepted).map((c) => c.id));
    if (_accepted.isEmpty && widget.initialCategoryIds != null) {
      _accepted.addAll(widget.initialCategoryIds!.where(ids.contains));
    }
    _hours = rules.hours.isEmpty && widget.initialHours != null
        ? widget.initialHours!
        : rules.hours;
    try {
      _facilities = await HubService.facilities(widget.hub.id);
    } catch (_) {
      _facilities = null; // database not updated yet: the section is hidden
    }
    return rules;
  }

  Future<void> _save() async {
    final problem = _accepted.isEmpty ? 'Choose at least one category.' : _hours.validate();
    if (problem != null) {
      hubToast(context, problem);
      return;
    }
    setState(() => _saving = true);
    try {
      await HubService.saveServiceRules(widget.hub.id, _accepted, _hours);
      if (_facilities != null) {
        await HubService.saveFacilities(widget.hub.id, _facilities!);
      }
      if (!mounted) return;
      hubToast(context, 'Saved. Donors can now choose this hub when it fits.');
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) hubToast(context, 'Not saved: ${hubErrorMessage(error)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Categories, hours & storage')),
    body: FutureBuilder<HubServiceRules>(
      future: _rules,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return HubErrorState(
            error: snapshot.error!,
            onRetry: () => setState(() => _rules = _load()),
          );
        }
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            if (!snapshot.data!.ready)
              const HubCard(
                color: Color(0xfffff8e8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: HubColors.amber),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Donors cannot choose this hub until you save the categories '
                        'and opening hours.',
                      ),
                    ),
                  ],
                ),
              ),
            const HubSectionTitle(
              'Accepted categories',
              subtitle: 'Donors can only bring donations in these categories.',
            ),
            HubCategoryPicker(
              categories: _categories,
              selected: _accepted,
              facilities: _facilities,
              onChanged: () => setState(() {}),
            ),
            const HubSectionTitle(
              'Opening hours (Malaysia time)',
              subtitle:
                  'Add a second time on a day if you close for a break. Donors choose the '
                  'day they come and can arrive any time you are open that day.',
            ),
            HubHoursEditor(hours: _hours),
            if (_facilities != null) ...[
              const HubSectionTitle(
                'Storage at your hub',
                subtitle:
                    'Tick what your hub has. Donors are pointed to hubs that can store '
                    'their items well.',
              ),
              HubFacilitiesEditor(
                facilities: _facilities!,
                onChanged: () => setState(() {}),
              ),
            ],
          ],
        );
      },
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _saving ? null : _save,
      icon: const Icon(Icons.save_outlined),
      label: Text(_saving ? 'Saving…' : 'Save'),
    ),
  );
}

/// Weekly opening hours editor. Changes the given [hours] in place.
class HubHoursEditor extends StatefulWidget {
  final HubOperatingHours hours;
  final VoidCallback? onChanged;
  const HubHoursEditor({super.key, required this.hours, this.onChanged});

  @override
  State<HubHoursEditor> createState() => _HubHoursEditorState();
}

class _HubHoursEditorState extends State<HubHoursEditor> {
  HubOperatingHours get _hours => widget.hours;

  void _change(VoidCallback edit) {
    setState(edit);
    widget.onChanged?.call();
  }

  Future<String?> _pickTime(String initial, {required bool closing}) async {
    final minutes = initial == '24:00' ? 0 : hubMinutesOf(initial);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      helpText: closing ? 'CLOSING TIME (00:00 = MIDNIGHT)' : 'OPENING TIME',
    );
    if (picked == null) return null;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    return closing && text == '00:00' ? '24:00' : text;
  }

  Future<void> _editSlot(String day, int index, {required bool closing}) async {
    final slot = _hours.days[day]![index];
    final value = await _pickTime(closing ? slot.close : slot.open, closing: closing);
    if (value == null || !mounted) return;
    _change(() {
      _hours.days[day]![index] = closing
          ? HubTimeSlot(slot.open, value)
          : HubTimeSlot(value, slot.close);
    });
  }

  void _copyToAllDays(String from) => _change(() {
    for (final day in hubWeekdays) {
      _hours.days[day] = [..._hours.days[from]!];
    }
  });

  void _usePreset(List<HubTimeSlot> weekday, List<HubTimeSlot> weekend) => _change(() {
    for (final day in hubWeekdays) {
      _hours.days[day] = [...(day == 'sat' || day == 'sun' ? weekend : weekday)];
    }
  });

  /// Next opening after a break: one hour after the last closing time, for up to 4 hours.
  void _addAfterBreak(String day) {
    final slots = _hours.days[day]!;
    final lastClose = slots.map((s) => s.closeMinute).reduce((a, b) => a > b ? a : b);
    final start = lastClose + 60;
    if (start > 23 * 60) {
      hubToast(context, 'No time left in the day after ${hubTimeLabel(slots.last.close)}.');
      return;
    }
    final end = start + 4 * 60 >= 24 * 60 ? 24 * 60 : start + 4 * 60;
    _change(() => slots.add(HubTimeSlot(_text(start), end == 24 * 60 ? '24:00' : _text(end))));
  }

  static String _text(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        children: [
          ActionChip(
            avatar: const Icon(Icons.business_center_outlined, size: 18),
            label: const Text('Mon–Fri 9–5'),
            onPressed: () => _usePreset(const [HubTimeSlot('09:00', '17:00')], const []),
          ),
          ActionChip(
            avatar: const Icon(Icons.restaurant_outlined, size: 18),
            label: const Text('Mon–Fri 9–5, lunch 1–2'),
            onPressed: () => _usePreset(
              const [HubTimeSlot('09:00', '13:00'), HubTimeSlot('14:00', '17:00')],
              const [],
            ),
          ),
          ActionChip(
            avatar: const Icon(Icons.calendar_month_outlined, size: 18),
            label: const Text('Every day 9–9'),
            onPressed: () => _usePreset(
              const [HubTimeSlot('09:00', '21:00')],
              const [HubTimeSlot('09:00', '21:00')],
            ),
          ),
        ],
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(2, 8, 2, 8),
        child: Text(
          'Closed for a break (e.g. lunch)? End the first time at the break, then tap + to add '
          'the time you open again.',
          style: TextStyle(fontSize: 12, color: HubColors.muted),
        ),
      ),
      HubCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (final day in hubWeekdays) ...[
              if (day != hubWeekdays.first) const Divider(height: 1),
              _dayRow(day),
            ],
          ],
        ),
      ),
    ],
  );

  Widget _timeBox(String day, int index, {required bool closing}) {
    final slot = _hours.days[day]![index];
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () => _editSlot(day, index, closing: closing),
        child: Text(
          hubTimeLabel(closing ? slot.close : slot.open),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _dayRow(String day) {
    final slots = _hours.days[day]!;
    final open = slots.isNotEmpty;
    final label = hubWeekdayLabels[day]!.substring(0, 3);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Switch(
            value: open,
            onChanged: (on) => _change(() {
              _hours.days[day] = on ? [const HubTimeSlot('09:00', '17:00')] : [];
            }),
          ),
          SizedBox(
            width: 40,
            height: 48,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: day == hubTodayKey() ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          ),
          Expanded(
            child: open
                ? Column(
                    children: [
                      for (var i = 0; i < slots.length; i++)
                        Padding(
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                          child: Row(
                            children: [
                              _timeBox(day, i, closing: false),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Text('to', style: TextStyle(color: HubColors.muted)),
                              ),
                              _timeBox(day, i, closing: true),
                              if (i == 0)
                                IconButton(
                                  tooltip: 'Add a time after a break',
                                  onPressed: () => _addAfterBreak(day),
                                  icon: const Icon(Icons.add_circle_outline),
                                )
                              else
                                IconButton(
                                  tooltip: 'Remove this time',
                                  onPressed: () => _change(() => slots.removeAt(i)),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                            ],
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => _copyToAllDays(day),
                          icon: const Icon(Icons.copy_all_outlined, size: 16),
                          label: const Text('Copy to every day', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  )
                : const SizedBox(
                    height: 48,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          Icon(Icons.bedtime_outlined, size: 20, color: HubColors.muted),
                          SizedBox(width: 6),
                          Text('Closed', style: TextStyle(color: HubColors.muted)),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Tick boxes for the hub's storage facilities. Changes the given [facilities] in place.
class HubFacilitiesEditor extends StatefulWidget {
  final HubFacilities facilities;

  /// Called after a tick changes (e.g. to update the category warnings).
  final VoidCallback? onChanged;
  const HubFacilitiesEditor({super.key, required this.facilities, this.onChanged});

  @override
  State<HubFacilitiesEditor> createState() => _HubFacilitiesEditorState();
}

class _HubFacilitiesEditorState extends State<HubFacilitiesEditor> {
  Widget _tick(String title, String example, bool value, ValueChanged<bool> onChanged) =>
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: value,
        onChanged: (on) {
          setState(() => onChanged(on ?? false));
          widget.onChanged?.call();
        },
        title: Text(title),
        subtitle: Text(example, style: const TextStyle(fontSize: 12)),
      );

  @override
  Widget build(BuildContext context) {
    final f = widget.facilities;
    return Column(
      children: [
        _tick(
          'Food-safe storage',
          'Closed cabinets or sealed boxes, off the floor, away from pests.',
          f.foodSafeStorage,
          (on) => f.foodSafeStorage = on,
        ),
        _tick(
          'Shelves for fragile items',
          'So phones, electronics and glassware are not stacked under heavy bags.',
          f.fragileShelving,
          (on) => f.fragileShelving = on,
        ),
        _tick(
          'Lockable storeroom',
          'A room or cabinet you can lock, for valuable items.',
          f.lockableStoreroom,
          (on) => f.lockableStoreroom = on,
        ),
        _tick(
          'Vehicle access',
          'Ground-floor entrance a car or van can stop next to, for bulky items.',
          f.vehicleAccess,
          (on) => f.vehicleAccess = on,
        ),
      ],
    );
  }
}

/// Accepted-category chips. Each chip shows the storage that category needs. If the hub
/// accepts a category but has not ticked the storage it needs, a warning explains it and
/// offers to tick it. The hub may still accept it (donors are pointed to hubs that have
/// the storage first). Changes [selected] and [facilities] in place.
class HubCategoryPicker extends StatelessWidget {
  final List<DonationCategoryInfo> categories;
  final Set<String> selected;

  /// The hub's storage ticks; null hides the warnings.
  final HubFacilities? facilities;
  final VoidCallback onChanged;

  const HubCategoryPicker({
    super.key,
    required this.categories,
    required this.selected,
    required this.facilities,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final f = facilities;
    // need -> accepted categories that need it but the hub has not ticked it
    final missing = <String, List<String>>{};
    if (f != null) {
      for (final c in categories.where((c) => selected.contains(c.id))) {
        for (final need in c.needs.where((n) => !f.has(n))) {
          missing.putIfAbsent(need, () => []).add(c.name);
        }
      }
    }
    final usedNeeds = {for (final c in categories) ...c.needs};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final c in categories)
              FilterChip(
                tooltip: c.needsText ?? 'No special storage needed',
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(c.name),
                    for (final need in hubNeedKeys.where(c.needs.contains))
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          hubNeedIcons[need],
                          size: 15,
                          color: f != null && selected.contains(c.id) && !f.has(need)
                              ? HubColors.amber
                              : HubColors.muted,
                        ),
                      ),
                  ],
                ),
                selected: selected.contains(c.id),
                onSelected: (on) {
                  if (on) {
                    selected.add(c.id);
                  } else {
                    selected.remove(c.id);
                  }
                  onChanged();
                },
              ),
          ],
        ),
        if (usedNeeds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final need in hubNeedKeys.where(usedNeeds.contains))
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(hubNeedIcons[need], size: 14, color: HubColors.muted),
                      const SizedBox(width: 3),
                      Text(
                        'needs ${hubNeedLabels[need]!.toLowerCase()}',
                        style: const TextStyle(fontSize: 12, color: HubColors.muted),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        for (final entry in missing.entries)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: HubCard(
              color: const Color(0xfffff8e8),
              borderColor: Colors.transparent,
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(hubNeedIcons[entry.key], color: HubColors.amber, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${entry.value.join(', ')} '
                          '${entry.value.length == 1 ? 'needs' : 'need'} '
                          '${hubNeedLabels[entry.key]!.toLowerCase()}, which is not ticked '
                          'under storage. You can still accept '
                          '${entry.value.length == 1 ? 'it' : 'them'}, but donors are '
                          'pointed to hubs that have it first.',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () {
                        f!.set(entry.key, true);
                        onChanged();
                      },
                      icon: const Icon(Icons.check_box_outlined, size: 18),
                      label: Text('My hub has ${hubNeedLabels[entry.key]!.toLowerCase()}'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
