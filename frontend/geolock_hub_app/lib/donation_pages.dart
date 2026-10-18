import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

import 'location/location_picker_page.dart';
import 'location/location_result.dart';
import 'donation_photo_rules.dart';
import 'donation_photo_errors.dart';

final _db = Supabase.instance.client;

class EligibleListingsPage extends StatefulWidget {
  const EligibleListingsPage({super.key});
  @override
  State<EligibleListingsPage> createState() => _EligibleListingsPageState();
}

class _EligibleListingsPageState extends State<EligibleListingsPage> {
  late Future<List<Map<String, dynamic>>> _listings = _load();
  late final Future<bool> _trustedRouting = _loadTrustedRouting();

  Future<bool> _loadTrustedRouting() async {
    try {
      final response = await _db.rpc('geolock_app_capabilities');
      return response is Map && response['road_node_resolution'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final response = await _db.rpc('discover_eligible_listing_cards');
    if (response is! List) {
      throw const FormatException('Invalid listing response.');
    }
    return response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> _claim(String listingId) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'geolock_claim_request_${userId}_$listingId';
    final request = prefs.getString(key) ?? const Uuid().v4();
    await prefs.setString(key, request);
    try {
      final response = await _db.rpc(
        'claim_listing',
        params: {'p_listing': listingId, 'p_request': request},
      );
      if (response is! Map) {
        throw const FormatException(
          'Claim RPC returned no authoritative outcome.',
        );
      }
      final result = Map<String, dynamic>.from(response);
      final outcome = result['outcome']?.toString() ?? 'ERROR';
      final reason = result['reason_code']?.toString();
      await prefs.remove(key);
      if (!mounted) return;
      final success = outcome == 'SUCCESS' && result['claim_id'] != null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Claim committed. Claim ID: ${result['claim_id']}'
                : 'Claim $outcome${reason == null ? '' : ': $reason'}',
          ),
        ),
      );
      if (success) setState(() => _listings = _load());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No claim success was confirmed. Retry this same attempt to reuse request ID $request. Error: $error',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Eligible Listings')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _listings,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Listing discovery unavailable: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snapshot.data!;
        if (rows.isEmpty) {
          return const Center(
            child: Text(
              'No eligible listings with a validated road node are available.',
            ),
          );
        }
        return FutureBuilder<bool>(
          future: _trustedRouting,
          builder: (context, routeSnapshot) {
            final capabilityReady = routeSnapshot.data == true;
            return RefreshIndicator(
              onRefresh: () async => setState(() => _listings = _load()),
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final listing = rows[index];
                  final id = listing['listing_id'].toString();
                  final trustedNode = listing['routing_status'] == 'READY';
                  final canClaim = capabilityReady && trustedNode;
                  return Card(
                    margin: const EdgeInsets.all(10),
                    child: ListTile(
                      leading: _StoredImageThumbnail(
                        path: listing['primary_image_path']?.toString(),
                      ),
                      title: Text(
                        '${listing['title'] ?? listing['source_type']} · ${listing['listing_weight_kg']} kg',
                      ),
                      subtitle: Text(
                        '${listing['collection_path'] ?? listing['source_type']} · ${listing['routing_status'] ?? 'UNVERIFIED'}\n${canClaim ? 'Available since ${listing['listing_created_at']}' : 'Not claimable: trusted road-node readiness is not confirmed by the server.'}',
                      ),
                      isThreeLine: true,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              NgoListingDetailsPage(listing: listing),
                        ),
                      ),
                      trailing: FilledButton(
                        onPressed: canClaim ? () => _claim(id) : null,
                        child: Text(canClaim ? 'Claim' : 'Unavailable'),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    ),
  );
}

class MyClaimsPage extends StatefulWidget {
  const MyClaimsPage({super.key});
  @override
  State<MyClaimsPage> createState() => _MyClaimsPageState();
}

class RegisterHubPage extends StatefulWidget {
  const RegisterHubPage({super.key});
  @override
  State<RegisterHubPage> createState() => _RegisterHubPageState();
}

class _RegisterHubPageState extends State<RegisterHubPage> {
  final _name = TextEditingController();
  final _capacity = TextEditingController(text: '100');
  LocationResult? _location;
  bool _busy = false;
  @override
  void dispose() {
    _name.dispose();
    _capacity.dispose();
    super.dispose();
  }

  Future<void> _pickLocation() async {
    final result = await Navigator.push<LocationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          title: 'Hub Address and Location',
          initialLocation: _location,
        ),
      ),
    );
    if (result != null && mounted) setState(() => _location = result);
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final capacity = double.tryParse(_capacity.text.trim());
    if (name.isEmpty ||
        _location == null ||
        capacity == null ||
        capacity < 50 ||
        capacity > 250) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter a hub name, confirm a location, and set capacity from 50 to 250 kg.',
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      // V3's resolver is not confirmed deployed. Never send a client-guessed
      // node; the protected V3 registration RPC accepts null for this field.
      const String? roadNode = null;
      final hubId = await _db.rpc(
        'register_community_hub',
        params: {
          'p_name': name,
          'p_address': _location!.address,
          'p_lat': _location!.latitude,
          'p_lon': _location!.longitude,
          'p_capacity_kg': capacity,
          'p_road_node': roadNode,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            roadNode == null
                ? 'Hub registered ($hubId); route-node coverage is unavailable.'
                : 'Hub registration committed ($hubId).',
          ),
        ),
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hub registration was not confirmed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Register Community Hub')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Hub name'),
        ),
        TextField(
          controller: _capacity,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Total capacity (kg)',
            helperText: 'Allowed range: 50–250 kg',
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _pickLocation,
          icon: const Icon(Icons.location_on),
          label: Text(
            _location == null ? 'Select hub location' : 'Change hub location',
          ),
        ),
        if (_location != null)
          Text(
            '${_location!.address}\n${_location!.latitude.toStringAsFixed(6)}, ${_location!.longitude.toStringAsFixed(6)}',
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Registering…' : 'Register Hub'),
        ),
      ],
    ),
  );
}

class HubOperationsPage extends StatefulWidget {
  final Map<String, dynamic> hub;
  final String section;
  const HubOperationsPage({super.key, required this.hub, this.section = 'All'});
  @override
  State<HubOperationsPage> createState() => _HubOperationsPageState();
}

class _HubOperationsPageState extends State<HubOperationsPage> {
  late Future<Map<String, List<Map<String, dynamic>>>> _data = _load();
  bool _busy = false;

  Future<Map<String, List<Map<String, dynamic>>>> _load() async {
    final responses = await Future.wait([
      _db.rpc(
        'get_my_hub_reservations',
        params: {'p_hub': widget.hub['hub_id']},
      ),
      _db.rpc('get_my_hub_inventory', params: {'p_hub': widget.hub['hub_id']}),
      _db.rpc(
        'get_my_hub_batches_dashboard',
        params: {'p_hub': widget.hub['hub_id']},
      ),
      _db.rpc(
        'get_hub_donation_covers',
        params: {'p_hub': widget.hub['hub_id']},
      ),
    ]);
    if (responses.any((value) => value is! List)) {
      throw const FormatException('Hub operation RPC returned invalid data.');
    }
    final covers = <String, String>{};
    for (final row in (responses[3] as List)) {
      final cover = Map<String, dynamic>.from(row as Map);
      if (cover['primary_image_path'] != null) {
        covers[cover['donation_id'].toString()] = cover['primary_image_path']
            .toString();
      }
    }
    final reservations = (responses[0] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final inventory = (responses[1] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    for (final row in [...reservations, ...inventory]) {
      row['primary_image_path'] = covers[row['donation_id'].toString()];
    }
    return {
      'reservations': reservations,
      'inventory': inventory,
      'batches': (responses[2] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList(),
    };
  }

  Future<void> _confirmReceipt(Map<String, dynamic> reservation) async {
    final weight = TextEditingController(
      text: reservation['reserved_weight_kg'].toString(),
    );
    final entered = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm physical receipt'),
        content: TextField(
          controller: weight,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Measured received weight (kg)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(weight.text)),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    weight.dispose();
    if (entered == null) return;
    setState(() => _busy = true);
    try {
      final receipt = await _db.rpc(
        'confirm_hub_receipt',
        params: {
          'p_reservation': reservation['reservation_id'],
          'p_received_weight': entered,
        },
      );
      if (receipt == null || receipt.toString().trim().isEmpty) {
        throw const FormatException('The database did not confirm hub receipt.');
      }
      if (mounted) {
        setState(() => _data = _load());
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Hub receipt committed.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Receipt not confirmed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publishBatch(List<Map<String, dynamic>> inventory) async {
    final selected = <String>{};
    final categories = <String, String>{};
    final totals = <String, double>{};
    for (final row in inventory) {
      final id = row['donation_id'].toString();
      final rawCategories = row['category_ids'];
      final rowCategories = rawCategories is List
          ? rawCategories.map((value) => value.toString()).toList()
          : <String>[];
      categories[id] = rowCategories.join('|');
      totals[id] = double.tryParse('${row['received_weight_kg']}') ?? 0;
    }
    final chosen = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Select whole donations for batch'),
          content: SizedBox(
            width: 440,
            child: ListView(
              shrinkWrap: true,
              children: inventory.map((row) {
                final id = row['donation_id'].toString();
                return CheckboxListTile(
                  value: selected.contains(id),
                  title: Text(
                    '${row['title']} · ${row['received_weight_kg']} kg',
                  ),
                  subtitle: Text('Category ${row['category_name'] ?? '—'}'),
                  onChanged: row['inventory_status'] != 'STORED'
                      ? null
                      : (value) => setDialog(() {
                          if (value == true) {
                            selected.add(id);
                          } else {
                            selected.remove(id);
                          }
                        }),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Publish batch'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    final ids = chosen.toList();
    final categorySet = ids
        .expand(
          (id) => (categories[id] ?? '')
              .split('|')
              .where((value) => value.isNotEmpty),
        )
        .toSet();
    final total = ids.fold<double>(0, (sum, id) => sum + (totals[id] ?? 0));
    final anyMixed = ids.any(
      (id) =>
          (categories[id] ?? '')
              .split('|')
              .where((value) => value.isNotEmpty)
              .length !=
          1,
    );
    if (ids.length < 3 ||
        ids.length > 5 ||
        categorySet.length != 1 ||
        anyMixed ||
        total > 30) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'A batch requires 3–5 whole donations, one compatible category, and no more than 30 kg.',
            ),
          ),
        );
      }
      return;
    }
    setState(() => _busy = true);
    try {
      await _db.rpc(
        'publish_whole_donation_batch',
        params: {'p_hub': widget.hub['hub_id'], 'p_donation_ids': ids},
      );
      final updated = await _load();
      if (mounted) {
        setState(() => _data = Future.value(updated));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Batch publication committed.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Batch not published: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showHubAudit() async {
    try {
      final response = await _db.rpc(
        'get_authorized_audit_events',
        params: {'p_entity_type': 'HUB', 'p_entity_id': widget.hub['hub_id']},
      );
      if (response is! List) {
        throw const FormatException('Invalid hub audit response.');
      }
      if (!mounted) return;
      final rows = response
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      await showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('Hub audit timeline')),
              if (rows.isEmpty)
                const ListTile(title: Text('No audit events found.')),
              ...rows.map(
                (event) => ListTile(
                  title: Text(event['event_type']?.toString() ?? 'Event'),
                  subtitle: Text(
                    '${event['previous_state'] ?? '—'} → ${event['resulting_state'] ?? '—'} · ${event['reason_code'] ?? event['outcome']}',
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hub audit unavailable: $error')),
        );
      }
    }
  }

  Future<void> _addBatchImage(Map<String, dynamic> batch) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 1800,
      );
      if (image == null || !mounted) return;
      final ext = image.path.split('.').last.toLowerCase();
      if (!const {'jpg', 'jpeg', 'png', 'webp'}.contains(ext) ||
          await image.length() > 5 * 1024 * 1024) {
        throw StateError('Choose a JPG, PNG or WebP image up to 5 MB.');
      }
      final mime = ext == 'png'
          ? 'image/png'
          : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
      final batchId = batch['batch_id'].toString();
      final path = '$userId/batches/$batchId/${const Uuid().v4()}.$ext';
      final storage = _db.storage.from('geolock-donation-images');
      await storage.upload(
        path,
        File(image.path),
        fileOptions: FileOptions(contentType: mime, upsert: false),
      );
      try {
        await _db.rpc(
          'add_hub_batch_image',
          params: {
            'p_batch': batchId,
            'p_storage_path': path,
            'p_content_type': mime,
            'p_size_bytes': await image.length(),
          },
        );
      } catch (_) {
        try {
          await storage.remove([path]);
        } catch (_) {}
        rethrow;
      }
      if (!mounted) return;
      setState(() => _data = _load());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Batch photo attached.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(donationPhotoFailureMessage(error))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.section == 'All'
            ? widget.hub['hub_name'].toString()
            : '${widget.hub['hub_name']} · ${widget.section}',
      ),
    ),
    body: FutureBuilder<Map<String, List<Map<String, dynamic>>>>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Hub operations unavailable: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        final reservations = data['reservations']!;
        final inventory = data['inventory']!;
        final batches = data['batches']!;
        return RefreshIndicator(
          onRefresh: () async => setState(() => _data = _load()),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Text(
                'Capacity ${widget.hub['capacity_kg']} kg · ${widget.hub['address_text']}',
              ),
              OutlinedButton.icon(
                onPressed: _showHubAudit,
                icon: const Icon(Icons.history),
                label: const Text('View hub audit timeline'),
              ),
              if (widget.section == 'All' || widget.section == 'Receive') ...[
                const SizedBox(height: 16),
                Text(
                  'Pending donor drop-offs',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (reservations.where((r) => r['status'] == 'ACTIVE').isEmpty)
                  const ListTile(
                    title: Text('No active reservations awaiting receipt.'),
                  ),
                ...reservations.map(
                  (row) => Card(
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: _StoredImageThumbnail(
                            path: row['primary_image_path']?.toString(),
                          ),
                        ),
                        Expanded(
                          child: ListTile(
                            title: Text(
                              '${row['title']} · ${row['reserved_weight_kg']} kg',
                            ),
                            subtitle: Text(
                              '${row['status']} · expires ${row['expires_at']}',
                            ),
                            trailing: row['status'] == 'ACTIVE'
                                ? FilledButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _confirmReceipt(row),
                                    child: const Text('Receive'),
                                  )
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (widget.section == 'All' || widget.section == 'Inventory') ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Stored donations',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton(
                      onPressed: _busy || inventory.length < 3
                          ? null
                          : () => _publishBatch(inventory),
                      child: const Text('Publish batch'),
                    ),
                  ],
                ),
                if (inventory.isEmpty)
                  const ListTile(title: Text('No stored donations.')),
                ...inventory.map(
                  (row) => Card(
                    child: ListTile(
                      leading: _StoredImageThumbnail(
                        path: row['primary_image_path']?.toString(),
                      ),
                      title: Text(
                        '${row['title']} · ${row['received_weight_kg']} kg',
                      ),
                      subtitle: Text(
                        '${row['inventory_status']} · ${row['category_name'] ?? '—'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DonationPhotosPage(
                            donationId: row['donation_id'].toString(),
                            title: row['title'].toString(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if (widget.section == 'All' ||
                  widget.section == 'Collections') ...[
                const SizedBox(height: 16),
                Text(
                  'Published batches',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (batches.isEmpty)
                  const ListTile(title: Text('No published batches.')),
                ...batches.map(
                  (row) => Card(
                    child: ListTile(
                      leading: _StoredImageThumbnail(
                        path: row['primary_image_path']?.toString(),
                      ),
                      title: Text('Batch ${row['batch_id']}'),
                      subtitle: Text(
                        '${row['batch_status']} · ${row['batch_donation_count']} donations · ${row['batch_weight_kg']} kg',
                      ),
                      trailing: row['primary_image_path'] == null
                          ? IconButton(
                              tooltip: 'Add batch photo',
                              onPressed: _busy
                                  ? null
                                  : () => _addBatchImage(row),
                              icon: const Icon(
                                Icons.add_photo_alternate_outlined,
                              ),
                            )
                          : const Icon(Icons.photo_outlined),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => HubBatchDetailsPage(
                            batchId: row['batch_id'].toString(),
                            hubId: widget.hub['hub_id'].toString(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

class MyReconciliationCasesPage extends StatefulWidget {
  const MyReconciliationCasesPage({super.key});
  @override
  State<MyReconciliationCasesPage> createState() =>
      _MyReconciliationCasesPageState();
}

class _MyReconciliationCasesPageState extends State<MyReconciliationCasesPage> {
  late Future<List<Map<String, dynamic>>> _cases = _load();
  bool _busy = false;

  Future<List<Map<String, dynamic>>> _load() async {
    final response = await _db.rpc('get_my_reconciliation_cases');
    if (response is! List) {
      throw const FormatException('Invalid reconciliation inbox response.');
    }
    return response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> _submit(Map<String, dynamic> row, bool handoverConfirmed) async {
    final caseId = row['case_id'].toString();
    final choice = handoverConfirmed ? 'yes' : 'no';
    final prefs = await SharedPreferences.getInstance();
    final key = 'geolock_reconcile_${_db.auth.currentUser?.id}_${caseId}_$choice';
    final requestId = prefs.getString(key) ?? const Uuid().v4();
    await prefs.setString(key, requestId);
    setState(() => _busy = true);
    try {
      final response = await _db.rpc(
        'submit_claim_reconciliation',
        params: {
          'p_claim': row['claim_id'],
          'p_handover_confirmed': handoverConfirmed,
          'p_request': requestId,
        },
      );
      if (response is! Map) {
        throw const FormatException('Reconciliation outcome missing.');
      }
      final result = Map<String, dynamic>.from(response);
      if (result['outcome'] == null) {
        throw const FormatException('Reconciliation outcome is missing.');
      }
      await prefs.remove(key);
      List<Map<String, dynamic>>? refreshed;
      Object? refreshError;
      try {
        refreshed = await _load();
      } catch (error) {
        refreshError = error;
      }
      if (!mounted) return;
      if (refreshed != null) {
        setState(() => _cases = Future.value(refreshed));
      } else {
        setState(() => _cases = _load());
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${result['outcome']}: ${result['reason_code'] ?? 'Evidence recorded'}'
            '${refreshError == null ? '' : ' (case refresh failed; retry refresh)'}',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No result was confirmed. Retry will reuse request $requestId. $error',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Handover Reconciliation')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _cases,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Reconciliation cases unavailable: ${snapshot.error}'),
                TextButton(
                  onPressed: () => setState(() => _cases = _load()),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snapshot.data!;
        if (rows.isEmpty) {
          return const Center(child: Text('No handover cases require your response.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            final open = row['case_status'] == 'OPEN';
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Case ${row['case_id']}', style: Theme.of(context).textTheme.titleMedium),
                    Text('${row['source_type']} · ${row['case_status']}'),
                    Text('Claim ${row['claim_id']} · opened ${row['opened_at']}'),
                    const SizedBox(height: 8),
                    Text(open
                        ? 'Confirm whether the physical handover occurred. The NGO and donor or hub administrator must submit matching answers.'
                        : 'This case needs trusted manual review. Your response will not change the pickup or listing state.'),
                    if (open)
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: _busy ? null : () => _submit(row, true),
                            child: const Text('Handover occurred'),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : () => _submit(row, false),
                            child: const Text('No handover'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class _MyClaimsPageState extends State<MyClaimsPage> {
  late Future<List<Map<String, dynamic>>> _claims = _load();
  bool _busy = false;

  Future<List<Map<String, dynamic>>> _load() async {
    final response = await _db.rpc('get_my_claim_cards');
    if (response is! List) {
      throw const FormatException('Invalid claim history response.');
    }
    return response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> _run(String claimId, String operation) async {
    setState(() => _busy = true);
    try {
      if (operation == 'START_PICKUP') {
        await _db.rpc('start_pickup', params: {'p_claim': claimId});
      } else if (operation == 'COMPLETE_PICKUP') {
        await _db.rpc(
          'complete_pickup',
          params: {'p_claim': claimId, 'p_handover_confirmed': true},
        );
      } else {
        throw ArgumentError.value(operation, 'operation', 'Unsupported action');
      }
      final refreshed = await _load();
      if (!mounted) return;
      setState(() => _claims = Future.value(refreshed));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$operation committed by the database.')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$operation was not confirmed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelClaim(String claimId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this claim?'),
        content: const Text(
          'The database will allow cancellation only before pickup starts and while the claim lease is valid. Route activity or uncertain handover requires reconciliation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep claim'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel claim'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'geolock_cancel_claim_${_db.auth.currentUser?.id}_$claimId';
    final requestId = prefs.getString(key) ?? const Uuid().v4();
    await prefs.setString(key, requestId);
    setState(() => _busy = true);
    try {
      final response = await _db.rpc(
        'cancel_claim',
        params: {'p_claim': claimId, 'p_request': requestId},
      );
      if (response is! Map) {
        throw const FormatException('Cancellation outcome missing.');
      }
      final result = Map<String, dynamic>.from(response);
      if (result['outcome'] == null) {
        throw const FormatException('Claim cancellation outcome is missing.');
      }
      if (result['outcome'] == 'SUCCESS' || result['outcome'] == 'REJECTED') {
        await prefs.remove(key);
      }
      List<Map<String, dynamic>>? refreshed;
      Object? refreshError;
      try {
        refreshed = await _load();
      } catch (error) {
        refreshError = error;
      }
      if (!mounted) return;
      if (refreshed != null) {
        setState(() => _claims = Future.value(refreshed));
      } else {
        setState(() => _claims = _load());
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Claim ${result['outcome']}: ${result['reason_code'] ?? ''}'
            '${refreshError == null ? '' : ' (history refresh failed; pull to refresh)'}',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Claim cancellation was not confirmed. Retry will reuse request $requestId. $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitReconciliation(String claimId, bool handoverConfirmed) async {
    final choice = handoverConfirmed ? 'yes' : 'no';
    final prefs = await SharedPreferences.getInstance();
    final key = 'geolock_reconcile_${_db.auth.currentUser?.id}_${claimId}_$choice';
    final requestId = prefs.getString(key) ?? const Uuid().v4();
    await prefs.setString(key, requestId);
    setState(() => _busy = true);
    try {
      final response = await _db.rpc(
        'submit_claim_reconciliation',
        params: {
          'p_claim': claimId,
          'p_handover_confirmed': handoverConfirmed,
          'p_request': requestId,
        },
      );
      if (response is! Map) {
        throw const FormatException('Reconciliation outcome missing.');
      }
      final result = Map<String, dynamic>.from(response);
      if (result['outcome'] == null) {
        throw const FormatException('Reconciliation outcome is missing.');
      }
      await prefs.remove(key);
      List<Map<String, dynamic>>? refreshed;
      Object? refreshError;
      try {
        refreshed = await _load();
      } catch (error) {
        refreshError = error;
      }
      if (!mounted) return;
      if (refreshed != null) {
        setState(() => _claims = Future.value(refreshed));
      } else {
        setState(() => _claims = _load());
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${result['outcome']}: ${result['reason_code'] ?? ''}'
            '${refreshError == null ? '' : ' (status refresh failed; pull to refresh)'}',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reconciliation was not confirmed; retry will reuse request $requestId. $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _audit(String claimId) async {
    try {
      final rows = await _db.rpc(
        'get_authorized_audit_events',
        params: {'p_entity_type': 'CLAIM', 'p_entity_id': claimId},
      );
      if (!mounted) return;
      if (rows is! List) throw const FormatException('Invalid audit response.');
      await showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('Claim and pickup audit history')),
              ...rows.map((row) {
                final event = Map<String, dynamic>.from(row as Map);
                return ListTile(
                  title: Text(event['event_type'].toString()),
                  subtitle: Text(
                    '${event['previous_state'] ?? '—'} → ${event['resulting_state'] ?? '—'} · ${event['reason_code'] ?? event['outcome']}',
                  ),
                );
              }),
            ],
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Audit history unavailable: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('My Claims')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _claims,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Claim history unavailable: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snapshot.data!;
        if (rows.isEmpty) return const Center(child: Text('No claims yet.'));
        return RefreshIndicator(
          onRefresh: () async => setState(() => _claims = _load()),
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              final claimId = row['claim_id'].toString();
              final status = row['claim_status']?.toString();
              final task = row['task_status']?.toString();
              final active = status == 'ACTIVE';
              return Card(
                margin: const EdgeInsets.all(10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _StoredImageThumbnail(
                            path: row['primary_image_path']?.toString(),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  row['title']?.toString() ??
                                      row['source_type'].toString(),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${row['source_type']} · ${row['listing_weight_kg']} kg',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('Claim $status · lease ${row['lease_status']}'),
                      Text(
                        'Lease expiry (database): ${row['lease_expires_at'] ?? '—'}',
                      ),
                      Text('Pickup task: ${task ?? '—'}'),
                      Wrap(
                        spacing: 8,
                        children: [
                          if (active && (task == 'CONFIRMED' || task == 'PLANNED'))
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(claimId, 'START_PICKUP'),
                              child: const Text('Start Pickup'),
                            ),
                          OutlinedButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    ClaimPickupDetailPage(claimId: claimId),
                              ),
                            ),
                            icon: const Icon(Icons.location_on_outlined),
                            label: const Text('Pickup details'),
                          ),
                          if (active && task == 'DISPATCHED')
                            FilledButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(claimId, 'COMPLETE_PICKUP'),
                              child: const Text('Confirm Handover'),
                            ),
                          if (active && task == 'CONFIRMED')
                            TextButton(
                              onPressed: _busy ? null : () => _cancelClaim(claimId),
                              child: const Text('Cancel Claim'),
                            ),
                          if (status == 'RECONCILIATION_REQUIRED') ...[
                            FilledButton.tonal(
                              onPressed: _busy ? null : () => _submitReconciliation(claimId, true),
                              child: const Text('Confirm handover'),
                            ),
                            OutlinedButton(
                              onPressed: _busy ? null : () => _submitReconciliation(claimId, false),
                              child: const Text('Confirm no handover'),
                            ),
                            const Text('Both the NGO and donor or hub administrator must submit matching evidence. Some pickup-started cases remain under trusted review.'),
                          ],
                          TextButton.icon(
                            onPressed: () => _audit(claimId),
                            icon: const Icon(Icons.history),
                            label: const Text('Audit'),
                          ),
                        ],
                      ),
                      Text(
                        'Claim ID: $claimId',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    ),
  );
}

class NgoListingDetailsPage extends StatefulWidget {
  final Map<String, dynamic> listing;
  const NgoListingDetailsPage({super.key, required this.listing});

  @override
  State<NgoListingDetailsPage> createState() => _NgoListingDetailsPageState();
}

class _NgoListingDetailsPageState extends State<NgoListingDetailsPage> {
  late final Future<Map<String, dynamic>> _details = _load();

  Future<Map<String, dynamic>> _load() async {
    final row = widget.listing;
    final isBatch = row['source_type'] == 'HUB_BATCH';
    final rawImages = await _db.rpc(
      isBatch ? 'get_batch_images' : 'get_donation_images',
      params: isBatch
          ? {'p_batch': row['batch_id']}
          : {'p_donation': row['donation_id']},
    );
    final images = rawImages is List
        ? rawImages
              .map((image) => Map<String, dynamic>.from(image as Map))
              .toList()
        : <Map<String, dynamic>>[];
    List<Map<String, dynamic>> constituents = [];
    if (isBatch) {
      final rawMembers = await _db.rpc(
        'get_eligible_listing_constituents',
        params: {'p_listing': row['listing_id']},
      );
      if (rawMembers is List) {
        constituents = rawMembers
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
      }
    }
    return {'images': images, 'constituents': constituents};
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Donation Listing')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _details,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Listing details unavailable: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        final images = (data['images'] as List).cast<Map<String, dynamic>>();
        final constituents = (data['constituents'] as List)
            .cast<Map<String, dynamic>>();
        final cover = widget.listing['primary_image_path']?.toString();
        final imagePaths = images
            .map((image) => image['storage_path']?.toString() ?? '')
            .where((path) => path.isNotEmpty)
            .toList();
        if (imagePaths.isEmpty && cover != null) imagePaths.add(cover);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.listing['title']?.toString() ?? 'Community Hub Batch',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text(
              '${widget.listing['listing_weight_kg']} kg · ${widget.listing['collection_path'] ?? widget.listing['source_type']}',
            ),
            const SizedBox(height: 12),
            DonationPhotoCarousel(paths: imagePaths),
            const SizedBox(height: 12),
            Text(
              'Routing: ${widget.listing['routing_status'] ?? 'UNVERIFIED'}',
            ),
            const Text(
              'A listing appears only after backend eligibility checks. Claiming is enabled only when trusted road-node resolution is confirmed.',
            ),
            if (constituents.isNotEmpty) ...[
              const Divider(),
              const Text('Whole donations in this batch'),
              for (final donation in constituents)
                ListTile(
                  leading: _StoredImageThumbnail(
                    path: donation['primary_image_path']?.toString(),
                  ),
                  title: Text(donation['title'].toString()),
                  subtitle: Text(
                    '${donation['total_weight_kg']} kg · ${donation['donation_status']}',
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DonationPhotosPage(
                        donationId: donation['donation_id'].toString(),
                        title: donation['title'].toString(),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    ),
  );
}

class ClaimPickupDetailPage extends StatelessWidget {
  final String claimId;
  const ClaimPickupDetailPage({super.key, required this.claimId});

  Future<Map<String, dynamic>> _load() async {
    final response = await _db.rpc(
      'get_claimed_listing_detail',
      params: {'p_claim': claimId},
    );
    if (response is! Map) {
      throw const FormatException('Invalid claim detail response.');
    }
    final result = Map<String, dynamic>.from(response);
    final constituents = await _db.rpc(
      'get_claimed_listing_constituents',
      params: {'p_claim': claimId},
    );
    result['constituents'] = constituents is List
        ? constituents
              .map((row) => Map<String, dynamic>.from(row as Map))
              .toList()
        : <Map<String, dynamic>>[];
    if (result['source_type'] == 'DIRECT_DONATION' &&
        result['donation_id'] == null &&
        (result['constituents'] as List).isNotEmpty) {
      result['donation_id'] =
          (result['constituents'] as List).first['donation_id'];
    }
    if (result['source_type'] == 'DIRECT_DONATION' &&
        result['donation_id'] != null) {
      final photos = await _db.rpc(
        'get_donation_images',
        params: {'p_donation': result['donation_id']},
      );
      result['donation_images'] = photos is List
          ? photos.map((row) => Map<String, dynamic>.from(row as Map)).toList()
          : <Map<String, dynamic>>[];
    }
    return result;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Claimed Pickup Details')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _load(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Pickup details unavailable: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        final constituents = (data['constituents'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              data['source_type'].toString(),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            _claimDetailRow('Claim state', data['claim_status']),
            _claimDetailRow('Listing state', data['listing_status']),
            _claimDetailRow('Lease state', data['lease_status']),
            _claimDetailRow(
              'Lease expires (database)',
              data['lease_expires_at'],
            ),
            _claimDetailRow('Pickup address', data['pickup_address']),
            _claimDetailRow(
              'Validated pickup coordinate',
              '${data['latitude']}, ${data['longitude']}',
            ),
            _claimDetailRow('Weight', '${data['listing_weight_kg']} kg'),
            if (data['source_type'] == 'HUB_BATCH') ...[
              const Divider(),
              const Text('Whole donations in this batch'),
              DonationPhotoCarousel(
                paths:
                    constituents.isEmpty ||
                        constituents.first['batch_cover_path'] == null
                    ? (constituents.isEmpty ||
                              constituents.first['primary_image_path'] == null
                          ? const []
                          : [
                              constituents.first['primary_image_path']
                                  .toString(),
                            ])
                    : [constituents.first['batch_cover_path'].toString()],
              ),
              ...constituents.map(
                (donation) => ListTile(
                  leading: _StoredImageThumbnail(
                    path: donation['primary_image_path']?.toString(),
                  ),
                  title: Text(donation['title'].toString()),
                  subtitle: Text(
                    '${donation['weight_kg']} kg · ${donation['donation_status']}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DonationPhotosPage(
                        donationId: donation['donation_id'].toString(),
                        title: donation['title'].toString(),
                      ),
                    ),
                  ),
                ),
              ),
            ] else if (constituents.isNotEmpty)
              DonationPhotoCarousel(
                paths: [
                  for (final image
                      in (data['donation_images'] as List? ?? const []))
                    if ((image as Map)['storage_path'] != null)
                      image['storage_path'].toString(),
                ],
              ),
            const Text(
              'Exact pickup details are shown only after this NGO has a claim for the listing.',
            ),
          ],
        );
      },
    ),
  );
}

Widget _claimDetailRow(String label, Object? value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 175,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      Expanded(child: Text(value?.toString() ?? '—')),
    ],
  ),
);

class DonationItemInput {
  final name = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final weight = TextEditingController(text: '1');
  String? category;
  String condition = 'GOOD';
  void dispose() {
    name.dispose();
    quantity.dispose();
    weight.dispose();
  }
}

class DonationCategory {
  final String id;
  final String name;
  const DonationCategory(this.id, this.name);
}

class DonationPhotoSelection {
  final String id;
  final XFile file;
  const DonationPhotoSelection({required this.id, required this.file});
}

class CreateDonationPage extends StatefulWidget {
  const CreateDonationPage({super.key});
  @override
  State<CreateDonationPage> createState() => _CreateDonationPageState();
}

class _CreateDonationPageState extends State<CreateDonationPage> {
  final formKey = GlobalKey<FormState>();
  final title = TextEditingController();
  final description = TextEditingController();
  LocationResult? pickupLocation;
  final items = <DonationItemInput>[DonationItemInput()];
  late Future<List<DonationCategory>> categories = _loadCategories();
  bool busy = false;
  String progressMessage = '';
  String createRequestId = const Uuid().v4();
  final photos = <DonationPhotoSelection>[];

  Future<void> _pickDonationImages() async {
    try {
      final remaining = 3 - photos.length;
      if (remaining <= 0) return;
      final picked = await ImagePicker().pickMultiImage(
        imageQuality: 82,
        maxWidth: 1600,
        limit: remaining,
      );
      if (!mounted || picked.isEmpty) return;
      final accepted = <DonationPhotoSelection>[];
      for (final file in picked.take(remaining)) {
        final extension = file.path.split('.').last.toLowerCase();
        if (!const {'jpg', 'jpeg', 'png', 'webp'}.contains(extension)) {
          throw StateError('Choose JPG, PNG or WebP photos.');
        }
        if (await file.length() > 5 * 1024 * 1024) {
          throw StateError('Each resized photo must be 5 MB or smaller.');
        }
        accepted.add(DonationPhotoSelection(id: const Uuid().v4(), file: file));
      }
      setState(() {
        photos.addAll(accepted);
        _resetCreateRequest();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image could not be selected: $error')),
        );
      }
    }
  }

  Future<void> _replaceDonationImage(int index) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 1600,
      );
      if (picked == null || !mounted) return;
      final extension = picked.path.split('.').last.toLowerCase();
      if (!const {'jpg', 'jpeg', 'png', 'webp'}.contains(extension) ||
          await picked.length() > 5 * 1024 * 1024) {
        throw StateError('Choose a JPG, PNG or WebP photo up to 5 MB.');
      }
      setState(() {
        photos[index] = DonationPhotoSelection(
          id: const Uuid().v4(),
          file: picked,
        );
        _resetCreateRequest();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo could not be replaced: $error')),
        );
      }
    }
  }

  void _resetCreateRequest() => createRequestId = const Uuid().v4();

  void _makeCover(int index) {
    if (index == 0) return;
    final ordered = DonationPhotoRules.withCoverFirst(photos, index);
    setState(() {
      photos
        ..clear()
        ..addAll(ordered);
      _resetCreateRequest();
    });
  }

  Future<List<Map<String, dynamic>>> _uploadDonationImages() async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Your session has expired. Sign in again.');
    }
    final storage = _db.storage.from('geolock-donation-images');
    final folder = '$userId/pending/$createRequestId';
    final existing = await storage.list(path: folder);
    final existingNames = existing.map((object) => object.name).toSet();
    final imagePayload = <Map<String, dynamic>>[];
    for (var index = 0; index < photos.length; index++) {
      final selection = photos[index];
      final file = selection.file;
      final ext = file.path.split('.').last.toLowerCase();
      final mime = ext == 'png'
          ? 'image/png'
          : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
      final path = '$folder/${selection.id}.$ext';
      if (mounted) {
        setState(
          () => progressMessage =
              'Uploading photo ${index + 1} of ${photos.length}…',
        );
      }
      if (!existingNames.contains('${selection.id}.$ext')) {
        await storage.upload(
          path,
          File(file.path),
          fileOptions: FileOptions(contentType: mime, upsert: false),
        );
      }
      imagePayload.add({
        'storage_path': path,
        'content_type': mime,
        'size_bytes': await file.length(),
      });
    }
    return imagePayload;
  }

  void retryCategories() => setState(() => categories = _loadCategories());

  Future<List<DonationCategory>> _loadCategories() async {
    final response = await _db.rpc('get_active_donation_categories');
    if (response is! List) {
      throw const FormatException(
        'The categories RPC returned an invalid response.',
      );
    }
    return response.map((row) {
      final map = Map<String, dynamic>.from(row as Map);
      return DonationCategory(
        map['category_id'].toString(),
        map['category_name'].toString(),
      );
    }).toList();
  }

  Future<void> selectPickupLocation() async {
    final selected = await Navigator.push<LocationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          title: 'Donation Pickup Location',
          initialLocation: pickupLocation,
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        pickupLocation = selected;
        _resetCreateRequest();
      });
    }
  }

  Future<void> submit() async {
    if (!formKey.currentState!.validate()) return;
    if (pickupLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select and confirm the pickup location.'),
        ),
      );
      return;
    }
    if (!DonationPhotoRules.validPhotoCount(photos.length)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose between 1 and 3 donation photos.'),
        ),
      );
      return;
    }
    final payload = <Map<String, dynamic>>[];
    for (final item in items) {
      final qty = int.tryParse(item.quantity.text.trim());
      final weight = double.tryParse(item.weight.text.trim());
      if (item.category == null ||
          qty == null ||
          qty <= 0 ||
          weight == null ||
          weight <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Complete every item, category, quantity and weight.',
            ),
          ),
        );
        return;
      }
      payload.add({
        'category_id': item.category,
        'item_name': item.name.text.trim(),
        'quantity': qty,
        'unit_weight_kg': weight,
        'item_condition': item.condition,
      });
    }
    setState(() {
      busy = true;
      progressMessage = 'Preparing photo uploads…';
    });
    try {
      // No trusted road-node resolver is confirmed in the installed V3 RPCs.
      // Null is safe: claim_listing rejects listings without a valid node.
      const String? resolvedNode = null;
      final imagePayload = await _uploadDonationImages();
      if (mounted) {
        setState(() => progressMessage = 'Saving donation securely…');
      }
      final id = await _db.rpc(
        'create_donation_with_images',
        params: DonationPhotoRules.createRpcPayload(
          requestId: createRequestId,
          title: title.text,
          description: description.text,
          pickupAddress: pickupLocation!.address,
          latitude: pickupLocation!.latitude,
          longitude: pickupLocation!.longitude,
          // Never send an unverified client node. The installed V3 claim RPC
          // rejects this listing until trusted road-node support is deployed.
          pickupRoadNodeId: resolvedNode,
          items: payload,
          images: imagePayload,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Donation created with ${photos.length} photos: $id. Trusted road-node resolution is not configured, so this listing cannot be claimed yet.',
          ),
          duration: const Duration(seconds: 7),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(donationPhotoFailureMessage(e)),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    for (final item in items) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Create Donation')),
    body: FutureBuilder<List<DonationCategory>>(
      future: categories,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Cannot load categories: ${snapshot.error}'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: retryCategories,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final choices = snapshot.data!;
        if (choices.isEmpty) {
          return const Center(child: Text('No active donation categories.'));
        }
        return Form(
          key: formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: title,
                readOnly: busy,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'Donation title'),
                validator: (v) => DonationPhotoRules.titleError(v ?? ''),
                onChanged: (_) => _resetCreateRequest(),
              ),
              TextFormField(
                controller: description,
                readOnly: busy,
                maxLength: 1000,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Description'),
                validator: (v) => DonationPhotoRules.descriptionError(v ?? ''),
                onChanged: (_) => _resetCreateRequest(),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: Text('Donation photos (${photos.length}/3)')),
                  TextButton.icon(
                    onPressed: busy || photos.length >= 3
                        ? null
                        : _pickDonationImages,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('Add photos'),
                  ),
                ],
              ),
              Text(
                'Select 1–3 photos. The first is the cover; choose another photo as cover to move it first. Photos are resized before upload.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (photos.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('At least one photo is required.'),
                ),
              for (var i = 0; i < photos.length; i++)
                Card(
                  key: ValueKey(photos[i].id),
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(photos[i].file.path),
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                      ),
                    ),
                    title: Text(i == 0 ? 'Cover photo' : 'Photo ${i + 1}'),
                    subtitle: Text(photos[i].file.name),
                    trailing: Wrap(
                      spacing: 0,
                      children: [
                        if (i > 0)
                          IconButton(
                            tooltip: 'Set as cover',
                            onPressed: busy ? null : () => _makeCover(i),
                            icon: const Icon(Icons.star_outline),
                          ),
                        IconButton(
                          tooltip: 'Replace photo',
                          onPressed: busy
                              ? null
                              : () => _replaceDonationImage(i),
                          icon: const Icon(Icons.refresh),
                        ),
                        IconButton(
                          tooltip: 'Remove photo',
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  photos.removeAt(i);
                                  _resetCreateRequest();
                                }),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              const Text('Pickup location'),
              OutlinedButton.icon(
                onPressed: busy ? null : selectPickupLocation,
                icon: const Icon(Icons.location_on_outlined),
                label: Text(
                  pickupLocation == null
                      ? 'Select pickup location'
                      : 'Change pickup location',
                ),
              ),
              if (pickupLocation != null) ...[
                Text(pickupLocation!.address),
                Text(
                  '${pickupLocation!.latitude.toStringAsFixed(6)}, ${pickupLocation!.longitude.toStringAsFixed(6)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              const Divider(),
              ...items.asMap().entries.map((entry) {
                final i = entry.key;
                final item = entry.value;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text('Item ${i + 1}'),
                            const Spacer(),
                            if (items.length > 1)
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: busy
                                    ? null
                                    : () => setState(() {
                                        items.removeAt(i);
                                        item.dispose();
                                        _resetCreateRequest();
                                      }),
                              ),
                          ],
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: item.category,
                          decoration: const InputDecoration(
                            labelText: 'Category',
                          ),
                          items: choices
                              .map(
                                (c) => DropdownMenuItem(
                                  value: c.id,
                                  child: Text(c.name),
                                ),
                              )
                              .toList(),
                          onChanged: busy
                              ? null
                              : (v) => setState(() {
                                  item.category = v;
                                  _resetCreateRequest();
                                }),
                          validator: (v) =>
                              v == null ? 'Select category' : null,
                        ),
                        TextFormField(
                          controller: item.name,
                          readOnly: busy,
                          decoration: const InputDecoration(
                            labelText: 'Item name',
                          ),
                          onChanged: (_) => _resetCreateRequest(),
                          validator: (v) => (v?.trim().isEmpty ?? true)
                              ? 'Enter item name'
                              : null,
                        ),
                        TextFormField(
                          controller: item.quantity,
                          readOnly: busy,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setState(() {
                            _resetCreateRequest();
                          }),
                          decoration: const InputDecoration(
                            labelText: 'Quantity',
                          ),
                        ),
                        TextFormField(
                          controller: item.weight,
                          readOnly: busy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onChanged: (_) => setState(() {
                            _resetCreateRequest();
                          }),
                          decoration: const InputDecoration(
                            labelText: 'Unit weight (kg)',
                          ),
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: item.condition,
                          decoration: const InputDecoration(
                            labelText: 'Item condition',
                          ),
                          items: const [
                            DropdownMenuItem(value: 'NEW', child: Text('New')),
                            DropdownMenuItem(
                              value: 'GOOD',
                              child: Text('Good'),
                            ),
                            DropdownMenuItem(
                              value: 'FAIR',
                              child: Text('Fair'),
                            ),
                          ],
                          onChanged: busy
                              ? null
                              : (value) => setState(() {
                                  item.condition = value ?? 'GOOD';
                                  _resetCreateRequest();
                                }),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add another item'),
                onPressed: busy || items.length >= 30
                    ? null
                    : () => setState(() {
                        items.add(DonationItemInput());
                        _resetCreateRequest();
                      }),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Estimated total weight: ${items.fold<double>(0, (total, item) {
                    final quantity = int.tryParse(item.quantity.text) ?? 0;
                    final unitWeight = double.tryParse(item.weight.text) ?? 0;
                    return total + quantity * unitWeight;
                  }).toStringAsFixed(3)} kg',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: 16),
              if (busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(progressMessage, textAlign: TextAlign.center),
              ],
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(busy ? 'Saving...' : 'Submit Donation'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Classification: below 10 kg = hub collection; 10 kg or more = direct pickup.',
              ),
            ],
          ),
        );
      },
    ),
  );
}

class MyDonationsPage extends StatefulWidget {
  const MyDonationsPage({super.key});

  @override
  State<MyDonationsPage> createState() => _MyDonationsPageState();
}

class _MyDonationsPageState extends State<MyDonationsPage> {
  late Future<List<Map<String, dynamic>>> _donations = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final response = await _db.rpc('get_my_donation_dashboard_v2');
    if (response is! List) {
      throw const FormatException('Invalid donation history response.');
    }
    return response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('My Donations'),
      actions: [
        IconButton(
          tooltip: 'Refresh donations',
          onPressed: () => setState(() => _donations = _load()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _donations,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Unable to load donations: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snapshot.data!;
        if (rows.isEmpty) return const Center(child: Text('No donations yet.'));
        return ListView.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final d = rows[i];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: ListTile(
                leading: _StoredImageThumbnail(
                  path: d['primary_image_path']?.toString(),
                ),
                title: Text('${d['title']}'),
                subtitle: Text(
                  '${d['collection_path']} • ${d['donation_status']} • ${d['total_weight_kg'] ?? '—'} kg${d['listing_routing_status'] == null ? '' : ' • route node ${d['listing_routing_status']}'}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DonationDetailPage(
                      donationId: d['donation_id'].toString(),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class DonationDetailPage extends StatefulWidget {
  final String donationId;
  const DonationDetailPage({super.key, required this.donationId});
  @override
  State<DonationDetailPage> createState() => _DonationDetailPageState();
}

class _DonationDetailPageState extends State<DonationDetailPage> {
  late Future<Map<String, dynamic>> _detail = _load();
  bool _busy = false;
  String _cancelRequestId = const Uuid().v4();

  Future<Map<String, dynamic>> _load() async {
    final response = await _db.rpc(
      'get_my_donation_detail',
      params: {'p_donation': widget.donationId},
    );
    if (response is! Map) {
      throw StateError('Donation not found or you do not have access to it.');
    }
    final detail = Map<String, dynamic>.from(response);
    List<Map<String, dynamic>> imageRows = [];
    try {
      final rows = await _db.rpc(
        'get_donation_images',
        params: {'p_donation': widget.donationId},
      );
      if (rows is List) {
        imageRows = rows
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
      }
    } catch (_) {
      // Older deployments may have only the first-photo dashboard field.
    }
    final dashboardRows = await _db.rpc('get_my_donation_dashboard_v2');
    if (dashboardRows is List) {
      for (final row in dashboardRows) {
        final donation = Map<String, dynamic>.from(row as Map);
        if (donation['donation_id'].toString() == widget.donationId) {
          detail['primary_image_path'] = donation['primary_image_path'];
          detail['inventory_status'] = donation['inventory_status'];
          // The dashboard RPC computes reservation expiry using database time.
          // Use it for UI wording and re-selection; the reservation RPC remains
          // authoritative if a request races expiry after this read.
          detail['reservation_effective_status'] =
              donation['reservation_effective_status'];
          if (imageRows.isEmpty && donation['primary_image_path'] != null) {
            imageRows = [
              {
                'storage_path': donation['primary_image_path'],
                'display_order': 1,
              },
            ];
          }
          break;
        }
      }
    }
    detail['images'] = imageRows;
    return detail;
  }

  Future<void> _reserveHub() async {
    setState(() => _busy = true);
    try {
      final response = await _db.rpc(
        'get_eligible_hubs',
        params: {'p_donation': widget.donationId},
      );
      if (response is! List) {
        throw const FormatException('Invalid hub list response.');
      }
      final hubs = response
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      if (!mounted) return;
      if (hubs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No compatible hub has available capacity.'),
          ),
        );
        return;
      }
      final selected = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Choose a community hub')),
              ...hubs.map(
                (hub) => ListTile(
                  title: Text(hub['hub_name'].toString()),
                  subtitle: Text(
                    '${hub['address_text']}\nAvailable: ${hub['available_capacity_kg']} kg',
                  ),
                  isThreeLine: true,
                  onTap: () => Navigator.pop(context, hub),
                ),
              ),
            ],
          ),
        ),
      );
      if (selected == null || !mounted) return;
      final reservation = await _db.rpc(
        'reserve_hub_capacity',
        params: {'p_donation': widget.donationId, 'p_hub': selected['hub_id']},
      );
      final reservationId = reservation?.toString().trim() ?? '';
      if (reservationId.isEmpty) {
        throw const FormatException(
          'The database did not confirm a hub reservation.',
        );
      }
      if (!mounted) return;
      setState(() => _detail = _load());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Hub reservation committed. You may deliver to this hub.'),
        ),
      );
    } catch (error) {
      if (mounted) {
        // A failed RPC may race with expiry, cancellation, or capacity changes.
        // Refresh authoritative state before inviting the donor to retry.
        setState(() => _detail = _load());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hub reservation failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this donation?'),
        content: const Text(
          'The database will check current claims, custody and hub state. The donation is cancelled only if the backend permits it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep donation'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Request cancellation'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final response = await _db.rpc(
        'cancel_donation',
        params: {
          'p_donation': widget.donationId,
          'p_request': _cancelRequestId,
        },
      );
      if (response is! Map) {
        throw const FormatException('Cancellation outcome was not returned.');
      }
      final result = Map<String, dynamic>.from(response);
      if (result['outcome'] != 'SUCCESS') {
        _cancelRequestId = const Uuid().v4();
        throw StateError(
          'Cancellation rejected: ${result['reason_code'] ?? 'UNKNOWN_REASON'}',
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Donation cancellation committed.')),
        );
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cancellation was not confirmed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Donation Details')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _detail,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Unable to load donation: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final d = snapshot.data!;
        final reservations = (d['hub_reservations'] as List? ?? const [])
            .cast<Map>();
        final items = (d['items'] as List? ?? const []).cast<Map>();
        final latestReservation = reservations.isEmpty
            ? null
            : reservations.first;
        final latestReservationStatus = d['reservation_effective_status'] ??
            latestReservation?['effective_status'] ??
            (latestReservation?['status'] == 'ACTIVE'
                ? 'STATUS_UNVERIFIED'
                : latestReservation?['status']);
        final hasReceipt = reservations.any(
          (reservation) => reservation['receipt_status'] != null,
        );
        final hasInventory = d['inventory_status'] != null;
        final hubHistoryIsClear = reservations.every(
          (reservation) => reservation['receipt_status'] == null,
        );
        final cancellable =
            !hasReceipt &&
            !hasInventory &&
            ((d['status'] == 'SUBMITTED' && reservations.isEmpty) ||
                (d['status'] == 'VALIDATED' && reservations.isEmpty) ||
                (d['status'] == 'READY_FOR_PICKUP' &&
                    d['collection_path'] == 'DIRECT_PICKUP' &&
                    d['listing_status'] == 'AVAILABLE' &&
                    reservations.isEmpty) ||
                (d['status'] == 'HUB_ASSIGNED' &&
                    d['collection_path'] == 'HUB_COLLECTION' &&
                    hubHistoryIsClear &&
                    (latestReservationStatus == 'ACTIVE' ||
                        latestReservationStatus == 'EXPIRED')));
        final needsHub = d['collection_path'] == 'HUB_COLLECTION' &&
            (d['status'] == 'VALIDATED' ||
                (d['status'] == 'HUB_ASSIGNED' &&
                    latestReservationStatus == 'EXPIRED'));
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              d['title'].toString(),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if ((d['description']?.toString().trim().isNotEmpty ?? false))
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 10),
                child: Text(d['description'].toString()),
              ),
            DonationPhotoCarousel(
              paths: ((d['images'] as List?) ?? const [])
                  .map((image) => Map<String, dynamic>.from(image as Map))
                  .map((image) => image['storage_path']?.toString() ?? '')
                  .where((path) => path.isNotEmpty)
                  .toList(),
            ),
            const SizedBox(height: 12),
            _detailRow(
              'Current state',
              d['status'] == 'VALIDATED' &&
                      d['collection_path'] == 'HUB_COLLECTION'
                  ? 'Awaiting Hub Selection'
                  : d['status'] == 'HUB_ASSIGNED' &&
                      latestReservationStatus == 'EXPIRED'
                  ? 'Hub reservation expired — choose another hub'
                  : d['status'] == 'HUB_ASSIGNED' &&
                        latestReservationStatus == 'ACTIVE'
                  ? 'Hub assigned — awaiting drop-off'
                  : d['status'] == 'HUB_ASSIGNED'
                  ? 'Hub assignment needs review'
                  : d['status'],
            ),
            _detailRow('Collection path', d['collection_path']),
            _detailRow('Total weight', '${d['total_weight_kg']} kg'),
            if (d['collection_path'] == 'DIRECT_PICKUP')
              _detailRow(
                'Road-node availability',
                d['road_node_status'] ?? 'PENDING_NODE',
              ),
            _detailRow('Pickup address', d['pickup_address']),
            const Divider(),
            Text('Items', style: Theme.of(context).textTheme.titleMedium),
            ...items.map(
              (item) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(item['item_name'].toString()),
                subtitle: Text(
                  '${item['category']} · ${item['quantity']} × ${item['unit_weight_kg']} kg · ${item['item_condition']}',
                ),
              ),
            ),
            const Divider(),
            Text(
              'Hub reservations',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (reservations.isEmpty)
              const Text('No hub reservation recorded.'),
            ...reservations.map(
              (r) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r['hub_name'].toString()),
                subtitle: Text(
                  '${r['effective_status'] ?? r['status']} · expires ${r['expires_at']}',
                ),
              ),
            ),
            if (needsHub)
              FilledButton.icon(
                onPressed: _busy ? null : _reserveHub,
                icon: const Icon(Icons.storefront_outlined),
                label: Text(
                  d['status'] == 'HUB_ASSIGNED'
                      ? 'Choose another Community Hub'
                      : 'Reserve a Community Hub',
                ),
              ),
            if (d['collection_path'] == 'DIRECT_PICKUP' &&
                d['road_node_status'] != 'READY')
              const Text(
                'No trusted road-node resolver is configured for this V3 deployment. This direct listing remains unavailable to claims until a validated node is assigned.',
              ),
            if (cancellable)
              TextButton.icon(
                onPressed: _busy ? null : _cancel,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancel donation'),
              ),
          ],
        );
      },
    ),
  );

  Widget _detailRow(String label, Object? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(child: Text(value?.toString() ?? '—')),
      ],
    ),
  );
}

class _StoredImageThumbnail extends StatelessWidget {
  final String? path;
  const _StoredImageThumbnail({this.path});

  @override
  Widget build(BuildContext context) {
    const size = 54.0;
    Widget placeholder() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xffe4f2ed),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.inventory_2_outlined, color: Color(0xff2f806c)),
    );
    if (path == null || path!.isEmpty) return placeholder();
    return FutureBuilder<String>(
      future: _db.storage
          .from('geolock-donation-images')
          .createSignedUrl(path!, 900),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.hasError) return placeholder();
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
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

class DonationPhotoCarousel extends StatefulWidget {
  final List<String> paths;
  final Future<String> Function(String path)? urlResolver;
  const DonationPhotoCarousel({
    super.key,
    required this.paths,
    this.urlResolver,
  });

  @override
  State<DonationPhotoCarousel> createState() => _DonationPhotoCarouselState();
}

class DonationPhotosPage extends StatefulWidget {
  final String donationId;
  final String title;
  const DonationPhotosPage({
    super.key,
    required this.donationId,
    required this.title,
  });

  @override
  State<DonationPhotosPage> createState() => _DonationPhotosPageState();
}

class _DonationPhotosPageState extends State<DonationPhotosPage> {
  late final Future<List<String>> _photos = _load();

  Future<List<String>> _load() async {
    final result = await _db.rpc(
      'get_donation_images',
      params: {'p_donation': widget.donationId},
    );
    if (result is! List) throw const FormatException('Invalid photo response.');
    return result
        .map(
          (row) =>
              Map<String, dynamic>.from(
                row as Map,
              )['storage_path']?.toString() ??
              '',
        )
        .where((path) => path.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: FutureBuilder<List<String>>(
      future: _photos,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Photos unavailable: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: DonationPhotoCarousel(paths: snapshot.data!),
        );
      },
    ),
  );
}

class HubBatchDetailsPage extends StatefulWidget {
  final String batchId;
  final String hubId;
  const HubBatchDetailsPage({
    super.key,
    required this.batchId,
    required this.hubId,
  });

  @override
  State<HubBatchDetailsPage> createState() => _HubBatchDetailsPageState();
}

class _HubBatchDetailsPageState extends State<HubBatchDetailsPage> {
  late final Future<Map<String, dynamic>> _details = _load();

  Future<Map<String, dynamic>> _load() async {
    final result = await _db.rpc(
      'get_hub_batch_details',
      params: {'p_hub': widget.hubId, 'p_batch': widget.batchId},
    );
    if (result is! Map) {
      throw const FormatException('Invalid batch detail response.');
    }
    return Map<String, dynamic>.from(result);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Batch Details')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _details,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Batch details unavailable: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        final donations = (data['donations'] as List? ?? const []).map(
          (row) => Map<String, dynamic>.from(row as Map),
        );
        final cover = data['batch_cover_path']?.toString();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Batch ${data['batch_id']}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              '${data['batch_status']} · ${data['batch_weight_kg'] ?? ''} kg',
            ),
            const SizedBox(height: 12),
            DonationPhotoCarousel(paths: cover == null ? const [] : [cover]),
            const SizedBox(height: 16),
            Text(
              'Constituent donations',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final donation in donations)
              Card(
                child: ListTile(
                  leading: _StoredImageThumbnail(
                    path: donation['primary_image_path']?.toString(),
                  ),
                  title: Text(donation['title'].toString()),
                  subtitle: Text(
                    '${donation['weight_kg']} kg · ${donation['donation_status']}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DonationPhotosPage(
                        donationId: donation['donation_id'].toString(),
                        title: donation['title'].toString(),
                      ),
                    ),
                  ),
                ),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'A constituent donation image is a visual fallback only; it does not prove that the batch is physically assembled.',
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _DonationPhotoCarouselState extends State<DonationPhotoCarousel> {
  late final PageController _controller = PageController();
  final _signedUrls = <String, Future<String>>{};
  int _index = 0;

  @override
  void didUpdateWidget(covariant DonationPhotoCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paths != widget.paths) _index = 0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.paths.length;
    if (count == 0) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: const Color(0xffe4f2ed),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.volunteer_activism_outlined, size: 42),
              SizedBox(height: 8),
              Text('No donation photos'),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: 240,
          child: Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: count,
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (context, index) => FutureBuilder<String>(
                  future: _signedUrls.putIfAbsent(
                    widget.paths[index],
                    () =>
                        widget.urlResolver?.call(widget.paths[index]) ??
                        _db.storage
                            .from('geolock-donation-images')
                            .createSignedUrl(widget.paths[index], 900),
                  ),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.hasError) {
                      return _photoPlaceholder();
                    }
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(
                        snapshot.data!,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _photoPlaceholder(),
                      ),
                    );
                  },
                ),
              ),
              if (count > 1 && _index > 0)
                Positioned(
                  left: 8,
                  top: 96,
                  child: IconButton.filledTonal(
                    tooltip: 'Previous photo',
                    onPressed: () => _controller.previousPage(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                    ),
                    icon: const Icon(Icons.chevron_left),
                  ),
                ),
              if (count > 1 && _index < count - 1)
                Positioned(
                  right: 8,
                  top: 96,
                  child: IconButton.filledTonal(
                    tooltip: 'Next photo',
                    onPressed: () => _controller.nextPage(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                    ),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('${_index + 1} / $count'),
        ),
      ],
    );
  }

  Widget _photoPlaceholder() => Container(
    color: const Color(0xffe4f2ed),
    child: const Center(
      child: Icon(Icons.image_not_supported_outlined, size: 42),
    ),
  );
}
