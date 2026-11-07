import 'dart:async';
import 'package:flutter/material.dart';
import 'ngo_routing_repository.dart';
import 'routing_page_support.dart';

class NgoFleetPage extends StatefulWidget {
  const NgoFleetPage({super.key, this.repository});
  final NgoRoutingRepository? repository;
  @override
  State<NgoFleetPage> createState() => _NgoFleetPageState();
}

class _NgoFleetPageState extends NgoSessionPage<NgoFleetPage> {
  @override
  NgoRoutingRepository? get injectedRepository => widget.repository;
  Map<String, dynamic>? _fleet;
  @override
  Future<Object?> fetch() => repository.fleet();
  @override
  void received(Object? value) => _fleet = routingObject(value);
  @override
  void clearSessionData() => _fleet = null;

  Future<void> _edit([Map<String, dynamic>? vehicle]) async {
    if (!actionsEnabled) return;
    final owner = repository.identity;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _VehicleForm(repository: repository, vehicle: vehicle),
      ),
    );
    if (mounted && owner == repository.identity) await reload();
  }

  Future<void> _change(Future<void> Function() action) async {
    await perform(action);
    if (mounted && error == null) await reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('NGO vehicles'),
      actions: [
        IconButton(
          onPressed: busy ? null : reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: actionsEnabled ? _edit : null,
      icon: const Icon(Icons.add),
      label: const Text('Register vehicle'),
    ),
    body: RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          ...notices,
          if (_fleet?['fleet_outcome'] == 'NO_FEASIBLE_PLAN')
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No eligible vehicle. Route planning cannot invent a vehicle or capacity.',
                ),
              ),
            ),
          for (final v in routingRows(_fleet?['vehicles'] ?? []))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${v['vehicle_label']}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${v['vehicle_type'] ?? 'Incomplete vehicle'} · ${v['payload_capacity_kg']} kg',
                    ),
                    Text(
                      'Fixed RM ${v['fixed_cost_rm'] ?? '—'} · RM ${v['distance_cost_rm_per_km'] ?? '—'}/km',
                    ),
                    Text(
                      'Maximum ${v['max_route_duration_min'] ?? '—'} min · depot ${v['depot_road_node_id'] ?? 'unverified'}',
                    ),
                    Text(
                      v['active_flag'] != true
                          ? 'Deactivated'
                          : v['eligible_for_planning'] == true
                          ? 'Eligible for planning'
                          : 'Unavailable, reserved or depot verification required',
                    ),
                    if (v['active_flag'] == true) ...[
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Available for planning'),
                        value: v['available_for_planning'] == true,
                        onChanged: actionsEnabled
                            ? (available) => _change(
                                () => repository.availability(v, available),
                              )
                            : null,
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: actionsEnabled ? () => _edit(v) : null,
                            child: const Text('Edit'),
                          ),
                          TextButton(
                            onPressed: actionsEnabled
                                ? () async {
                                    if (await routingConfirm(
                                      context,
                                      'Deactivate vehicle?',
                                      'This preserves its history. Reserved vehicles cannot be deactivated.',
                                    )) {
                                      if (mounted) {
                                        await _change(
                                          () => repository.deactivate(v),
                                        );
                                      }
                                    }
                                  }
                                : null,
                            child: const Text('Deactivate'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _VehicleForm extends StatefulWidget {
  const _VehicleForm({required this.repository, this.vehicle});
  final NgoRoutingRepository repository;
  final Map<String, dynamic>? vehicle;
  @override
  State<_VehicleForm> createState() => _VehicleFormState();
}

class _VehicleFormState extends State<_VehicleForm> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  bool _loading = true, _busy = false, _available = false, _pending = false;
  String? _error;
  late final String? _owner;
  StreamSubscription<void>? _identityChanges;
  static const _labels = {
    'p_label': 'Vehicle label',
    'p_vehicle_type': 'Vehicle type',
    'p_capacity_kg': 'Capacity (kg)',
    'p_fixed_cost_rm': 'Fixed cost (RM)',
    'p_distance_cost_rm_per_km': 'Distance cost (RM/km)',
    'p_max_route_duration_min': 'Maximum route duration (minutes)',
  };
  @override
  void initState() {
    super.initState();
    _owner = widget.repository.identity;
    _identityChanges = widget.repository.identityChanges.listen((_) {
      if (mounted && _owner != widget.repository.identity) {
        for (final controller in _fields.values) {
          controller.clear();
        }
        setState(() {
          _loading = false;
          _error = 'Account changed. Close this form and reopen it.';
        });
      }
    });
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final existing = widget.vehicle;
      final pending = existing == null
          ? await widget.repository.pendingRegistration()
          : <String, dynamic>{};
      if (!mounted || _owner != widget.repository.identity) return;
      final values = existing == null
          ? pending
          : <String, dynamic>{
              'p_label': existing['vehicle_label'],
              'p_vehicle_type': existing['vehicle_type'],
              'p_capacity_kg': existing['payload_capacity_kg'],
              'p_fixed_cost_rm': existing['fixed_cost_rm'],
              'p_distance_cost_rm_per_km': existing['distance_cost_rm_per_km'],
              'p_max_route_duration_min': existing['max_route_duration_min'],
            };
      for (final key in _labels.keys) {
        _fields[key] = TextEditingController(
          text: values[key]?.toString() ?? '',
        );
      }
      setState(() {
        _loading = false;
        _pending = pending.isNotEmpty;
        _available = pending['p_available'] == true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = routingError(e);
        });
      }
    }
  }

  String? _validate(String key, String? text) {
    final value = text?.trim() ?? '';
    if (key == 'p_label' || key == 'p_vehicle_type') {
      return value.isEmpty || value.length > 80
          ? 'Enter 1–80 characters.'
          : null;
    }
    final n = num.tryParse(value);
    if (key == 'p_capacity_kg' && n != null && n >= 1000000000) {
      return 'Capacity must be below 1,000,000,000 kg.';
    }
    final positive =
        key == 'p_capacity_kg' || key == 'p_max_route_duration_min';
    if (n == null || !n.isFinite || n < 0 || (positive && n == 0)) {
      return positive
          ? 'Enter a positive number.'
          : 'Enter a nonnegative number.';
    }
    final precision = key == 'p_fixed_cost_rm'
        ? 2
        : key == 'p_distance_cost_rm_per_km'
        ? 4
        : 3;
    if (!RegExp('^\\d+(\\.\\d{1,$precision})?\$').hasMatch(value)) {
      return 'Use at most $precision decimal places.';
    }
    return null;
  }

  Future<void> _save() async {
    if (_busy ||
        !_form.currentState!.validate() ||
        _owner != widget.repository.identity) {
      return;
    }
    final fields = <String, dynamic>{
      for (final k in _labels.keys)
        k: (k == 'p_label' || k == 'p_vehicle_type')
            ? _fields[k]!.text.trim()
            : num.parse(_fields[k]!.text.trim()),
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.vehicle == null) {
        _pending = true;
        await widget.repository.register({
          ...fields,
          'p_available': _available,
        });
      } else {
        await widget.repository.updateVehicle(widget.vehicle!, fields);
      }
      if (mounted && _owner == widget.repository.identity) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => _error = routingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _identityChanges?.cancel();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.vehicle == null ? 'Register vehicle' : 'Edit vehicle'),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null) Text(_error!),
                if (_pending)
                  const Text(
                    'Saved registration awaiting confirmation. Retry uses the same request and vehicle details.',
                  ),
                for (final key in _fields.keys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      controller: _fields[key],
                      enabled:
                          !_busy &&
                          !_pending &&
                          _owner == widget.repository.identity,
                      decoration: InputDecoration(labelText: _labels[key]),
                      keyboardType: key == 'p_label' || key == 'p_vehicle_type'
                          ? TextInputType.text
                          : const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                      validator: (value) => _validate(key, value),
                    ),
                  ),
                if (widget.vehicle == null)
                  SwitchListTile(
                    title: const Text('Available for planning'),
                    value: _available,
                    onChanged: _busy || _pending
                        ? null
                        : (v) => setState(() => _available = v),
                  ),
                FilledButton(
                  onPressed:
                      _busy ||
                          _fields.isEmpty ||
                          _owner != widget.repository.identity
                      ? null
                      : _save,
                  child: Text(
                    _busy
                        ? 'Saving…'
                        : _pending
                        ? 'Retry registration'
                        : 'Save',
                  ),
                ),
              ],
            ),
          ),
  );
}
