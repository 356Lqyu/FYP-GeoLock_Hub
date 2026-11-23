import 'dart:async';
import 'package:flutter/material.dart';
import 'ngo_routing_repository.dart';
import 'routing_page_support.dart';
import '../ui/geolock_role_style.dart';

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

  Widget _vehicleFacts(Map<String, dynamic> vehicle) {
    final facts = {
      'Capacity': '${vehicle['payload_capacity_kg']} kg',
      'Maximum duration': '${vehicle['max_route_duration_min'] ?? '—'} min',
      'Fixed cost': 'RM ${vehicle['fixed_cost_rm'] ?? '—'}',
      'Distance cost': 'RM ${vehicle['distance_cost_rm_per_km'] ?? '—'}/km',
    };
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          for (final fact in facts.entries)
            SizedBox(
              width: (constraints.maxWidth - 12) / 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(fact.key, style: Theme.of(context).textTheme.labelSmall),
                  Text(fact.value),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      GeoRoleTheme(child: _buildRolePage(context));

  Widget _buildRolePage(BuildContext context) => Scaffold(
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
          if (loading || busy) const LinearProgressIndicator(),
          if (error != null)
            GeoNoticeCard(
              tone: GeoTone.warning,
              child: Text(error!, key: const Key('routing-error')),
            ),
          if (!fresh && !loading)
            GeoNoticeCard(
              tone: GeoTone.info,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Refresh the fleet to verify availability before making changes.',
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : reload,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh fleet'),
                  ),
                ],
              ),
            ),
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${v['vehicle_label']}',
                                style: geoTitleStyle(context),
                              ),
                              Text(
                                '${v['vehicle_type'] ?? 'Incomplete vehicle'}',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (v['active_flag'] != true)
                          const GeoStatusChip(
                            'Deactivated',
                            tone: GeoTone.neutral,
                          )
                        else if (v['eligible_for_planning'] == true)
                          const GeoStatusChip(
                            'Available',
                            tone: GeoTone.success,
                          )
                        else if (v['available_for_planning'] == false)
                          const GeoStatusChip(
                            'Unavailable',
                            tone: GeoTone.neutral,
                          )
                        else
                          const GeoStatusChip(
                            'Planning blocked',
                            tone: GeoTone.warning,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _vehicleFacts(v),
                    const SizedBox(height: 8),
                    Text('Depot: ${v['depot_road_node_id'] ?? 'unverified'}'),
                    if (v['active_flag'] == true &&
                        v['available_for_planning'] != false &&
                        v['eligible_for_planning'] != true)
                      const Text('Check reservations and depot verification.'),
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
                      OutlinedButton(
                        onPressed: actionsEnabled ? () => _edit(v) : null,
                        child: const Text('Edit'),
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
  static const _hints = {
    'p_fixed_cost_rm': 'Fixed amount per vehicle used in reported cost.',
    'p_distance_cost_rm_per_km': 'Rate per road kilometre for reported cost.',
    'p_max_route_duration_min':
        'Maximum time for driving, pickup service and return to the depot.',
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
  Widget build(BuildContext context) => GeoRoleTheme(child: _buildForm());

  Widget _buildForm() => Scaffold(
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
                if (_error != null)
                  GeoNoticeCard(tone: GeoTone.warning, child: Text(_error!)),
                if (_pending)
                  const GeoNoticeCard(
                    tone: GeoTone.info,
                    child: Text(
                      'Saved registration awaiting confirmation. Retry uses the same request and vehicle details.',
                    ),
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
                      decoration: InputDecoration(
                        labelText: _labels[key],
                        helperText: _hints[key],
                        helperMaxLines: 3,
                      ),
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
