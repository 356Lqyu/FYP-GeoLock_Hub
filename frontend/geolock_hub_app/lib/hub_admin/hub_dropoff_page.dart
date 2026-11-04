// Drop-offs tab: booked drop-offs and the last 14 days. Receive with the real weight.
import 'package:flutter/material.dart';

import 'hub_admin_controller.dart';
import 'hub_donation_detail_page.dart';
import 'hub_service.dart';
import 'hub_widgets.dart';

class HubDropOffPage extends StatefulWidget {
  final HubAdminController controller;
  const HubDropOffPage({super.key, required this.controller});

  @override
  State<HubDropOffPage> createState() => _HubDropOffPageState();
}

class _HubDropOffPageState extends State<HubDropOffPage>
    with HubReloadOnChange {
  late Future<List<HubDropOff>> _rows;
  bool _showHistory = false;
  String _search = '';

  HubAdminController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    hubNeedsReload(_c);
    _rows = _load();
    _c.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (hubNeedsReload(_c) && mounted) setState(() => _rows = _load());
  }

  Future<List<HubDropOff>> _load() async {
    final rows = await HubService.dropOffs(_c.hubId);
    _c.awaitingCount = rows.where((r) => r.awaiting).length;
    return rows;
  }

  Future<void> _refresh() async {
    setState(() => _rows = _load());
    await _rows;
  }

  Future<void> _receive(HubDropOff row) async {
    final received = await showHubReceiveSheet(context, row);
    if (received && mounted) _c.dataChanged();
  }

  bool _matches(HubDropOff row) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return true;
    return row.referenceCode.toLowerCase().contains(q) ||
        row.title.toLowerCase().contains(q) ||
        (row.donorName ?? '').toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) => HubRefreshList<List<HubDropOff>>(
    future: _rows,
    onRefresh: _refresh,
    builder: (context, rows) {
      final awaiting = rows.where((r) => r.awaiting).toList();
      final history = rows.where((r) => !r.awaiting).toList();
      final shown = (_showHistory ? history : awaiting)
          .where(_matches)
          .toList();
      return [
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
              value: false,
              icon: const Icon(Icons.schedule),
              label: Text('Arriving (${awaiting.length})'),
            ),
            ButtonSegment(
              value: true,
              icon: const Icon(Icons.history),
              label: Text('History (${history.length})'),
            ),
          ],
          selected: {_showHistory},
          onSelectionChanged: (s) => setState(() => _showHistory = s.first),
        ),
        const SizedBox(height: 10),
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search reference code, item or donor',
          ),
          textCapitalization: TextCapitalization.characters,
          onChanged: (v) => setState(() => _search = v),
        ),
        const SizedBox(height: 6),
        if (!_showHistory)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'Ask the donor for the reference code on their drop-off pass, check '
              'the items, weigh them and tap Receive.',
              style: TextStyle(color: HubColors.muted),
            ),
          ),
        if (shown.isEmpty)
          HubEmptyState(
            icon: _showHistory ? Icons.history : Icons.inbox_outlined,
            title: _search.isNotEmpty
                ? 'No match'
                : _showHistory
                ? 'No drop-offs in the last 14 days'
                : 'No donors on the way',
            message: _showHistory
                ? 'Received, missed and cancelled drop-offs appear here.'
                : 'When a donor books this hub, the booking appears here with '
                      'the day they will come.',
          ),
        for (final row in shown)
          _DropOffCard(
            row: row,
            onReceive: row.awaiting ? () => _receive(row) : null,
            onOpen: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => HubDonationDetailPage(
                  controller: _c,
                  donationId: row.donationId,
                ),
              ),
            ),
          ),
      ];
    },
  );
}

class _DropOffCard extends StatelessWidget {
  final HubDropOff row;
  final VoidCallback? onReceive;
  final VoidCallback onOpen;

  const _DropOffCard({
    required this.row,
    required this.onReceive,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final minutes = hubMinutesLeft(row.expiresAt);
    final day = row.dropOffDay;
    final today = day != null && day == hubToday();
    final urgent = row.awaiting && today && minutes <= 30;
    return HubCard(
      onTap: onOpen,
      borderColor: urgent ? HubColors.amber.withValues(alpha: .5) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HubPhoto(row.photoPath, size: 60),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        _ReferenceCode(row.referenceCode),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${hubKg(row.reservedKg)} · ${row.itemCount} '
                      '${row.itemCount == 1 ? 'item' : 'items'} · ${row.categories}',
                      style: const TextStyle(color: HubColors.muted),
                    ),
                    if (row.donorName != null)
                      Text(
                        'Donor: ${row.donorName}',
                        style: const TextStyle(color: HubColors.muted),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (row.awaiting)
                HubStatusChip(
                  minutes == 0
                      ? 'Time is up'
                      : day == null
                      ? 'Coming by ${hubCloseLabel(row.expiresAt)}'
                      : 'Coming ${hubOnDay(day)} · before ${hubCloseLabel(row.expiresAt)}',
                  color: urgent ? HubColors.amber : HubColors.blue,
                  icon: Icons.schedule,
                )
              else
                HubStatusChip(
                  row.status == HubDropOffStatus.received
                      ? 'Received ${hubDateTime(row.receivedAt)} · ${hubKg(row.receivedKg ?? 0)}'
                      : '${hubDropOffLabel(row.status)} · booked ${hubDateTime(row.reservedAt)}',
                  color: hubDropOffColor(row.status),
                ),
              const Spacer(),
              if (onReceive != null)
                FilledButton.icon(
                  onPressed: onReceive,
                  icon: const Icon(Icons.move_to_inbox_outlined, size: 18),
                  label: const Text('Receive'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReferenceCode extends StatelessWidget {
  final String code;
  const _ReferenceCode(this.code);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: HubColors.mint,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: HubColors.line),
    ),
    child: Text(
      code,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
        color: HubColors.ink,
      ),
    ),
  );
}

/// Bottom sheet to receive one drop-off. Returns true when the receipt was saved.
Future<bool> showHubReceiveSheet(BuildContext context, HubDropOff row) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ReceiveSheet(row: row),
  );
  return result == true;
}

class _ReceiveSheet extends StatefulWidget {
  final HubDropOff row;
  const _ReceiveSheet({required this.row});

  @override
  State<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends State<_ReceiveSheet> {
  late final _weight = TextEditingController(
    text: hubKg(widget.row.reservedKg).replaceAll(' kg', ''),
  );
  bool _itemsChecked = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _weight.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final kg = double.tryParse(_weight.text.trim());
    if (kg == null || kg <= 0 || kg > widget.row.reservedKg) {
      setState(
        () => _error =
            'Enter a weight above 0 and not more than ${hubKg(widget.row.reservedKg)} '
            '(the booked weight).',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await HubService.confirmReceipt(widget.row.reservationId, kg);
      if (!mounted) return;
      hubToast(context, '${widget.row.title} received and stored.');
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = hubErrorMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      0,
      20,
      20 + MediaQuery.of(context).viewInsets.bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Receive donation',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            HubPhoto(widget.row.photoPath, size: 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.row.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'Ref ${widget.row.referenceCode} · booked ${hubKg(widget.row.reservedKg)}',
                    style: const TextStyle(color: HubColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _itemsChecked,
          onChanged: _saving
              ? null
              : (v) => setState(() => _itemsChecked = v == true),
          title: const Text('Items match the donation photos and categories'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        TextField(
          controller: _weight,
          enabled: !_saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Measured weight (kg)',
            helperText: 'Not more than ${hubKg(widget.row.reservedKg)}',
            suffixText: 'kg',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _saving || !_itemsChecked ? null : _save,
            icon: const Icon(Icons.check),
            label: Text(_saving ? 'Saving…' : 'Confirm receipt'),
          ),
        ),
      ],
    ),
  );
}
