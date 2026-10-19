import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

import 'location/location_picker_page.dart';
import 'location/location_result.dart';
import 'donation_photo_rules.dart';
import 'donation_photo_errors.dart';
import 'donation_status.dart';
import 'status_timeline.dart';

final _db = Supabase.instance.client;

String _safePhotoDiagnostic(Object error) => error
    .toString()
    .replaceAll(RegExp(r'https?://[^\s)\]}>]+'), '[URL redacted]')
    .replaceAll(
      RegExp(r'Bearer\s+\S+', caseSensitive: false),
      'Bearer [redacted]',
    )
    .replaceAll(
      RegExp(
        r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
      ),
      '[JWT redacted]',
    )
    .replaceAll(
      RegExp(r'\bsb_(?:publishable|secret)_[A-Za-z0-9_-]+\b'),
      '[Supabase key redacted]',
    )
    .replaceAll(
      RegExp(
        r'\b[0-9a-fA-F-]{36}/(?:pending/)?[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}\.(?:jpg|jpeg|png|webp)\b',
      ),
      '[Storage path redacted]',
    );

void _photoDebug(String message) {
  if (kDebugMode) debugPrint('[GeoLock photo] $message');
}

Future<String> createDonationPhotoSignedUrl(
  SupabaseClient client,
  String path, {
  required String surface,
}) async {
  try {
    final url = await client.storage
        .from('geolock-donation-images')
        .createSignedUrl(path, 900);
    _photoDebug('$surface signed URL created (URL omitted)');
    return url;
  } catch (error, stackTrace) {
    _photoDebug('$surface signed URL failed: ${_safePhotoDiagnostic(error)}');
    if (kDebugMode) debugPrint('$stackTrace');
    rethrow;
  }
}

void logDonationPhotoNetworkFailure({
  required String surface,
  required Object error,
  StackTrace? stackTrace,
}) {
  _photoDebug('$surface image request failed: ${_safePhotoDiagnostic(error)}');
  if (kDebugMode && stackTrace != null) debugPrint('$stackTrace');
}

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
                        '${friendlyWorkflowStatus(listing['collection_path'] ?? listing['source_type'])} · ${friendlyWorkflowStatus(listing['routing_status'] ?? 'UNVERIFIED')}\n${canClaim ? 'Eligible in discovery; the database rechecks when claimed.' : 'Claim unavailable: trusted road-node readiness is not confirmed by the server.'}',
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
        throw const FormatException(
          'The database did not confirm hub receipt.',
        );
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
                              '${row['status'] == 'ACTIVE' ? 'Recorded as Active · validity depends on database expiry' : friendlyWorkflowStatus(row['status'])} · deadline ${statusTimestampText(context, row['expires_at']) ?? '—'}',
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => HubDonationDetailsPage(
                                  hub: widget.hub,
                                  donationId: row['donation_id'].toString(),
                                ),
                              ),
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
                        '${friendlyWorkflowStatus(row['inventory_status'])} · ${row['category_name'] ?? '—'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => HubDonationDetailsPage(
                            hub: widget.hub,
                            donationId: row['donation_id'].toString(),
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
                        '${friendlyWorkflowStatus(row['batch_status'])} · ${row['batch_donation_count']} donations · ${row['batch_weight_kg']} kg',
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
    final key =
        'geolock_reconcile_${_db.auth.currentUser?.id}_${caseId}_$choice';
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
          return const Center(
            child: Text('No handover cases require your response.'),
          );
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
                    Text(
                      'Case ${row['case_id']}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text('${row['source_type']} · ${row['case_status']}'),
                    Text(
                      'Claim ${row['claim_id']} · opened ${row['opened_at']}',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      open
                          ? 'Confirm whether the physical handover occurred. The NGO and donor or hub administrator must submit matching answers.'
                          : 'This case needs trusted manual review. Your response will not change the pickup or listing state.',
                    ),
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
          SnackBar(
            content: Text(
              'Claim cancellation was not confirmed. Retry will reuse request $requestId. $error',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitReconciliation(
    String claimId,
    bool handoverConfirmed,
  ) async {
    final choice = handoverConfirmed ? 'yes' : 'no';
    final prefs = await SharedPreferences.getInstance();
    final key =
        'geolock_reconcile_${_db.auth.currentUser?.id}_${claimId}_$choice';
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
          SnackBar(
            content: Text(
              'Reconciliation was not confirmed; retry will reuse request $requestId. $error',
            ),
          ),
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
      final events = recordedAuditEvents(
        rows.map((row) => Map<String, dynamic>.from(row as Map)),
        allowedEventTypes: const {
          'CANCEL_CLAIM',
          'START_PICKUP',
          'COMPLETE_PICKUP',
          'LEASE_RECOVERY',
          'CLAIM_RECONCILIATION_EVIDENCE',
        },
      );
      await showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('Claim and pickup audit history')),
              if (events.isEmpty)
                const ListTile(
                  title: Text('No supported claim events are recorded.'),
                ),
              ...events.map((event) {
                return ListTile(
                  title: Text(event.title),
                  subtitle: event.occurredAt == null
                      ? (event.detail == null ? null : Text(event.detail!))
                      : Text(
                          '${statusTimestampText(context, event.occurredAt)}'
                          '${event.detail == null ? '' : ' · ${event.detail}'}',
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
                      Text('Claim · ${friendlyWorkflowStatus(status)}'),
                      Text(
                        'Lease · ${friendlyWorkflowStatus(row['lease_status'])}',
                      ),
                      Text(
                        'Lease expiry (database): ${statusTimestampText(context, row['lease_expires_at']) ?? '—'}',
                      ),
                      Text('Pickup task · ${friendlyWorkflowStatus(task)}'),
                      if (status == 'RECONCILIATION_REQUIRED' ||
                          row['lease_status'] == 'RECONCILIATION_REQUIRED')
                        const Text(
                          'Needs reconciliation · the listing is not available while handover remains unresolved.',
                          style: TextStyle(color: Colors.deepOrange),
                        ),
                      Wrap(
                        spacing: 8,
                        children: [
                          if (active &&
                              (task == 'CONFIRMED' || task == 'PLANNED'))
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
                              onPressed: _busy
                                  ? null
                                  : () => _cancelClaim(claimId),
                              child: const Text('Cancel Claim'),
                            ),
                          if (status == 'RECONCILIATION_REQUIRED') ...[
                            FilledButton.tonal(
                              onPressed: _busy
                                  ? null
                                  : () => _submitReconciliation(claimId, true),
                              child: const Text('Confirm handover'),
                            ),
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _submitReconciliation(claimId, false),
                              child: const Text('Confirm no handover'),
                            ),
                            const Text(
                              'Both the NGO and donor or hub administrator must submit matching evidence. Some pickup-started cases remain under trusted review.',
                            ),
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
    return {
      'images': images,
      'constituents': constituents,
      // discover_eligible_listings() returned this row only while it was
      // available and eligible. The claim RPC rechecks that state atomically.
      'listing_discovered_available': true,
      'progress_status': isBatch ? 'PUBLISHED' : 'READY_FOR_PICKUP',
    };
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
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Listing availability'),
                subtitle: const Text(
                  'Eligible in the latest discovery response. Availability and claim eligibility are rechecked by the database when you claim.',
                ),
              ),
            ),
            GeoStatusTimeline(
              title: widget.listing['source_type'] == 'HUB_BATCH'
                  ? 'Batch Progress'
                  : 'Donation Progress',
              currentStatus: friendlyWorkflowStatus(data['progress_status']),
              pendingMilestones: data['progress_status'] == 'READY_FOR_PICKUP'
                  ? pendingDonationMilestones(
                      collectionPath: 'DIRECT_PICKUP',
                      currentStatus: 'READY_FOR_PICKUP',
                    )
                  : const [],
              emptyMessage:
                  'This state is present in the eligible discovery response. Historical status timestamps are not provided on this screen.',
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
                    '${donation['total_weight_kg']} kg · ${friendlyWorkflowStatus(donation['donation_status'])}',
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
    final cards = await _db.rpc('get_my_claim_cards');
    if (cards is List) {
      for (final row in cards) {
        final card = Map<String, dynamic>.from(row as Map);
        if (card['claim_id']?.toString() == claimId) {
          result['claim_card'] = card;
          break;
        }
      }
    }
    var auditRows = <Map<String, dynamic>>[];
    String? auditError;
    try {
      final audit = await _db.rpc(
        'get_authorized_audit_events',
        params: {'p_entity_type': 'CLAIM', 'p_entity_id': claimId},
      );
      if (audit is List) {
        auditRows = audit
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
      } else {
        auditError = 'Claim event history is unavailable.';
      }
    } catch (_) {
      auditError = 'Claim event history could not be loaded.';
    }
    result['audit_events'] = auditRows;
    result['audit_error'] = auditError;
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
        final card = data['claim_card'] as Map<String, dynamic>?;
        final auditRows = (data['audit_events'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final claimEvents = recordedAuditEvents(
          auditRows,
          allowedEventTypes: const {
            'CANCEL_CLAIM',
            'START_PICKUP',
            'COMPLETE_PICKUP',
            'LEASE_RECOVERY',
            'CLAIM_RECONCILIATION_EVIDENCE',
          },
        );
        final claimedAt = card?['claimed_at']?.toString();
        if (claimedAt != null && DateTime.tryParse(claimedAt) != null) {
          claimEvents.insert(
            0,
            StatusTimelineEvent(
              title: 'Claim created',
              occurredAt: DateTime.parse(claimedAt),
            ),
          );
        }
        final claimStatus = data['claim_status']?.toString();
        final leaseStatus = data['lease_status']?.toString();
        final taskStatus = card?['task_status']?.toString();
        final isReconciliationRequired =
            claimStatus == 'RECONCILIATION_REQUIRED' ||
            leaseStatus == 'RECONCILIATION_REQUIRED';
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              data['source_type'].toString(),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              'My Claim Status',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _claimDetailRow('Claim', friendlyWorkflowStatus(claimStatus)),
            _claimDetailRow(
              'Listing availability',
              friendlyWorkflowStatus(data['listing_status']),
            ),
            _claimDetailRow(
              'Claim created',
              statusTimestampText(context, card?['claimed_at']) ?? '—',
            ),
            Text(
              'Claim Lease Status',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _claimDetailRow('Lease', friendlyWorkflowStatus(leaseStatus)),
            _claimDetailRow(
              'Lease expiration (database)',
              statusTimestampText(context, data['lease_expires_at']) ?? '—',
            ),
            const Text(
              'The database decides whether a lease is active. Elapsed time alone does not reopen a listing.',
            ),
            Text(
              'Pickup Task Status',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _claimDetailRow('Pickup task', friendlyWorkflowStatus(taskStatus)),
            if (isReconciliationRequired)
              const Card(
                color: Color(0xfffff0e8),
                child: ListTile(
                  leading: Icon(Icons.warning_amber_rounded),
                  title: Text('Handover requires reconciliation'),
                  subtitle: Text(
                    'This claim is unresolved. Do not treat the listing as available.',
                  ),
                ),
              ),
            GeoStatusTimeline(
              title: 'Claim and Pickup History',
              currentStatus: friendlyWorkflowStatus(claimStatus),
              events: claimEvents,
              errorMessage: data['audit_error']?.toString(),
              emptyMessage: 'No recorded claim or pickup events are available.',
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
                    '${donation['weight_kg']} kg · ${friendlyWorkflowStatus(donation['donation_status'])}',
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
            for (final donation in constituents)
              GeoStatusTimeline(
                title: 'Donation Progress · ${donation['title'] ?? 'Donation'}',
                currentStatus: friendlyWorkflowStatus(
                  donation['donation_status'],
                ),
                pendingMilestones: pendingDonationMilestones(
                  collectionPath: data['source_type'] == 'HUB_BATCH'
                      ? 'HUB_COLLECTION'
                      : 'DIRECT_PICKUP',
                  currentStatus: donation['donation_status']?.toString(),
                ),
                emptyMessage:
                    'No earlier donation events are available in this claim read.',
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
                  '${d['collection_path']} • ${donationStatusLabel(status: d['donation_status']?.toString(), collectionPath: d['collection_path']?.toString())} • ${d['total_weight_kg'] ?? '—'} kg${d['listing_routing_status'] == null ? '' : ' • route node ${d['listing_routing_status']}'}',
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
    var auditEvents = <Map<String, dynamic>>[];
    String? auditError;
    try {
      final audit = await _db.rpc(
        'get_authorized_audit_events',
        params: {'p_entity_type': 'DONATION', 'p_entity_id': widget.donationId},
      );
      if (audit is List) {
        auditEvents = audit
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
      } else {
        auditError = 'Recorded progress history is unavailable.';
      }
    } catch (_) {
      // The current donation state remains usable if a legacy deployment lacks
      // the role-scoped audit read or an older row has incomplete history.
      auditError = 'Recorded progress history could not be loaded.';
    }
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
        _photoDebug(
          'DonationDetailPage get_donation_images succeeded: '
          '${imageRows.length} row(s)',
        );
        for (var index = 0; index < imageRows.length; index++) {
          final path = imageRows[index]['storage_path']?.toString();
          _photoDebug(
            'DonationDetailPage image row #${index + 1}: '
            'storage_path_present=${path?.isNotEmpty == true}',
          );
        }
      } else {
        _photoDebug(
          'DonationDetailPage get_donation_images returned a non-list response',
        );
      }
    } catch (error, stackTrace) {
      // Older deployments may have only the first-photo dashboard field.
      _photoDebug(
        'DonationDetailPage get_donation_images failed: '
        '${_safePhotoDiagnostic(error)}',
      );
      if (kDebugMode) debugPrint('$stackTrace');
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
    detail['audit_events'] = auditEvents;
    detail['audit_error'] = auditError;
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
          content: Text(
            'Hub reservation committed. You may deliver to this hub.',
          ),
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
    backgroundColor: const Color(0xfff5f8f6),
    appBar: AppBar(
      title: const Text('Donation details'),
      backgroundColor: const Color(0xfff5f8f6),
      surfaceTintColor: Colors.transparent,
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _detail,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _DonorDetailMessage(
            icon: Icons.cloud_off_outlined,
            title: 'Could not load this donation',
            message: 'Check your connection and try again.',
            actionLabel: 'Try again',
            onPressed: () => setState(() => _detail = _load()),
          );
        }
        if (!snapshot.hasData) {
          return const Center(
            child: SizedBox(
              width: 220,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading donation details…'),
                ],
              ),
            ),
          );
        }

        final d = snapshot.data!;
        final reservations = (d['hub_reservations'] as List? ?? const [])
            .cast<Map>();
        final items = (d['items'] as List? ?? const []).cast<Map>();
        final latestReservation = reservations.isEmpty
            ? null
            : reservations.first;
        final latestReservationStatus =
            d['reservation_effective_status'] ??
            latestReservation?['effective_status'] ??
            (latestReservation?['status'] == 'ACTIVE'
                ? 'STATUS_UNVERIFIED'
                : latestReservation?['status']);
        final hasReceipt = reservations.any(
          (reservation) => reservation['receipt_status'] != null,
        );
        final hasInventory = d['inventory_status'] != null;
        final isHubCollection = shouldShowHubReservationSection(
          d['collection_path']?.toString(),
        );
        final auditEvents = (d['audit_events'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final donationEvents = recordedAuditEvents(
          auditEvents,
          allowedEventTypes: const {
            'CREATE_VALIDATE',
            'CONFIRM_HUB_RECEIPT',
            'CANCEL_DONATION',
          },
        );
        final reservationEvents = recordedAuditEvents(
          auditEvents,
          allowedEventTypes: const {'RESERVE_HUB', 'EXPIRE_HUB_RESERVATION'},
        );
        final hubHistoryIsClear = reservations.every(
          (reservation) => reservation['receipt_status'] == null,
        );
        final cancellable =
            !hasReceipt &&
            !hasInventory &&
            ((d['status'] == 'SUBMITTED' && reservations.isEmpty) ||
                (d['status'] == 'READY_FOR_PICKUP' &&
                    d['collection_path'] == 'DIRECT_PICKUP' &&
                    d['listing_status'] == 'AVAILABLE' &&
                    reservations.isEmpty) ||
                (d['status'] == 'HUB_ASSIGNED' &&
                    d['collection_path'] == 'HUB_COLLECTION' &&
                    hubHistoryIsClear &&
                    (latestReservationStatus == 'ACTIVE' ||
                        latestReservationStatus == 'EXPIRED')));
        final needsHub =
            d['collection_path'] == 'HUB_COLLECTION' &&
            (d['status'] == 'SUBMITTED' ||
                (d['status'] == 'HUB_ASSIGNED' &&
                    latestReservationStatus == 'EXPIRED'));
        final statusLabel =
            d['status'] == 'HUB_ASSIGNED' &&
                latestReservationStatus == 'EXPIRED'
            ? 'Hub reservation expired'
            : donationStatusLabel(
                status: d['status']?.toString(),
                collectionPath: d['collection_path']?.toString(),
                reservationStatus: latestReservationStatus?.toString(),
                inventoryStatus: d['inventory_status']?.toString(),
                listingStatus: d['listing_status']?.toString(),
              );
        final statusColor = _donorStatusColor(d['status']?.toString());
        final photos = ((d['images'] as List?) ?? const [])
            .map((image) => Map<String, dynamic>.from(image as Map))
            .map((image) => image['storage_path']?.toString() ?? '')
            .where((path) => path.isNotEmpty)
            .toList();

        return Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      DonationPhotoCarousel(paths: photos),
                      const SizedBox(height: 20),
                      Text(
                        d['title']?.toString() ?? 'Donation',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if ((d['description']?.toString().trim().isNotEmpty ??
                          false)) ...[
                        const SizedBox(height: 6),
                        Text(
                          d['description'].toString(),
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: const Color(0xff52645d),
                                height: 1.4,
                              ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _DonorStatusBadge(
                            label: statusLabel,
                            color: statusColor,
                          ),
                          _DonorInfoChip(
                            icon: Icons.scale_outlined,
                            label: '${d['total_weight_kg'] ?? '—'} kg',
                          ),
                          _DonorInfoChip(
                            icon: isHubCollection
                                ? Icons.storefront_outlined
                                : Icons.local_shipping_outlined,
                            label: isHubCollection
                                ? 'Community Hub collection'
                                : 'Direct pickup',
                          ),
                        ],
                      ),
                      if (d['pickup_address']?.toString().isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: _DonorSectionCard(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.location_on_outlined,
                                  color: Color(0xff287764),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        isHubCollection
                                            ? 'Pickup location'
                                            : 'Collection location',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge
                                            ?.copyWith(
                                              color: const Color(0xff52645d),
                                            ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(d['pickup_address'].toString()),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 22),
                      _DonorProgressTimeline(
                        currentStatus: d['status']?.toString(),
                        collectionPath: d['collection_path']?.toString(),
                        events: donationEvents,
                        auditError: d['audit_error']?.toString(),
                      ),
                      if (isHubCollection) ...[
                        const SizedBox(height: 18),
                        _DonorHubReservationSection(
                          reservations: reservations,
                          effectiveStatus: latestReservationStatus,
                          events: reservationEvents,
                        ),
                      ],
                      const SizedBox(height: 18),
                      _DonorSectionCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Donation items',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                Text(
                                  '${items.length}',
                                  style: Theme.of(context).textTheme.labelLarge
                                      ?.copyWith(
                                        color: const Color(0xff687a73),
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (items.isEmpty)
                              const Text('No item details are available.'),
                            for (var index = 0; index < items.length; index++)
                              _DonorItemRow(
                                item: items[index],
                                isLast: index == items.length - 1,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (needsHub || cancellable)
              _DonorDetailActions(
                isBusy: _busy,
                needsHub: needsHub,
                canCancel: cancellable,
                onChooseHub: _reserveHub,
                onCancel: _cancel,
              ),
          ],
        );
      },
    ),
  );
}

Color _donorStatusColor(String? status) => switch (status) {
  'CANCELLED' => const Color(0xffad3f42),
  'COLLECTED' => const Color(0xff277764),
  'PICKUP_IN_PROGRESS' => const Color(0xff28659a),
  'HUB_ASSIGNED' || 'AT_HUB' || 'BATCHED' => const Color(0xff89651b),
  _ => const Color(0xff287764),
};

class _DonorDetailMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onPressed;

  const _DonorDetailMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: const Color(0xff287764)),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center),
          if (actionLabel != null && onPressed != null) ...[
            const SizedBox(height: 18),
            FilledButton(onPressed: onPressed, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}

class _DonorStatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _DonorStatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: .25)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 9, color: color),
        const SizedBox(width: 7),
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _DonorInfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DonorInfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: const Color(0xffdce8e2)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: const Color(0xff287764)),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelLarge),
      ],
    ),
  );
}

class _DonorSectionCard extends StatelessWidget {
  final Widget child;

  const _DonorSectionCard({required this.child});

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    color: Colors.white,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Color(0xffe2ebe6)),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class _DonorProgressTimeline extends StatelessWidget {
  final String? currentStatus;
  final String? collectionPath;
  final List<StatusTimelineEvent> events;
  final String? auditError;

  const _DonorProgressTimeline({
    required this.currentStatus,
    required this.collectionPath,
    required this.events,
    this.auditError,
  });

  @override
  Widget build(BuildContext context) {
    final currentLabel = donationStatusLabel(
      status: currentStatus,
      collectionPath: collectionPath,
    );
    final pending = pendingDonationMilestones(
      collectionPath: collectionPath,
      currentStatus: currentStatus,
    );
    final cancellationIsRecorded =
        currentStatus == 'CANCELLED' &&
        events.any((event) => event.title == 'Donation cancelled');
    return _DonorSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Donation progress',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          for (final event in events)
            _DonorTimelineRow(
              title: event.title,
              detail: event.detail,
              timestamp: event.occurredAt,
              state: event.title == 'Donation cancelled'
                  ? _DonorTimelineState.terminal
                  : _DonorTimelineState.complete,
              isLast:
                  cancellationIsRecorded &&
                  identical(event, events.last) &&
                  pending.isEmpty,
            ),
          if (!cancellationIsRecorded)
            _DonorTimelineRow(
              title: currentLabel,
              detail: currentStatus == 'CANCELLED'
                  ? 'This donation is closed.'
                  : 'Current status',
              state: currentStatus == 'CANCELLED'
                  ? _DonorTimelineState.terminal
                  : _DonorTimelineState.current,
              isLast: pending.isEmpty,
            ),
          for (var index = 0; index < pending.length; index++)
            _DonorTimelineRow(
              title: pending[index],
              detail: 'Pending',
              state: _DonorTimelineState.pending,
              isLast: index == pending.length - 1,
            ),
          if (events.isEmpty && currentStatus == null)
            const Text('No donation history is available yet.'),
        ],
      ),
    );
  }
}

enum _DonorTimelineState { complete, current, pending, terminal }

class _DonorTimelineRow extends StatelessWidget {
  final String title;
  final String? detail;
  final DateTime? timestamp;
  final _DonorTimelineState state;
  final bool isLast;

  const _DonorTimelineRow({
    required this.title,
    required this.state,
    required this.isLast,
    this.detail,
    this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _DonorTimelineState.complete => const Color(0xff287764),
      _DonorTimelineState.current => const Color(0xff176957),
      _DonorTimelineState.pending => const Color(0xffa8b6af),
      _DonorTimelineState.terminal => const Color(0xffad3f42),
    };
    final icon = switch (state) {
      _DonorTimelineState.complete => Icons.check_circle,
      _DonorTimelineState.current => Icons.radio_button_checked,
      _DonorTimelineState.pending => Icons.radio_button_unchecked,
      _DonorTimelineState.terminal => Icons.cancel,
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Icon(icon, color: color, size: 18),
                if (!isLast)
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      width: 2,
                      color: color.withValues(alpha: .24),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: state == _DonorTimelineState.current
                          ? FontWeight.w700
                          : FontWeight.w600,
                      color: state == _DonorTimelineState.pending
                          ? const Color(0xff75857d)
                          : null,
                    ),
                  ),
                  if (detail != null && state != _DonorTimelineState.pending)
                    Text(
                      detail!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xff697a72),
                      ),
                    ),
                  if (timestamp != null)
                    Text(
                      statusTimestampText(context, timestamp) ?? '',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xff697a72),
                      ),
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

class _DonorHubReservationSection extends StatelessWidget {
  final List<Map> reservations;
  final Object? effectiveStatus;
  final List<StatusTimelineEvent> events;

  const _DonorHubReservationSection({
    required this.reservations,
    required this.effectiveStatus,
    required this.events,
  });

  Widget _reservationTile(
    BuildContext context,
    Map reservation, {
    required bool latest,
  }) {
    final status = reservationStatusLabel(
      recordedStatus: reservation['status'],
      effectiveStatus: effectiveStatus,
      isLatest: latest,
    );
    final receivedAt = statusTimestampText(context, reservation['received_at']);
    final reservedAt = statusTimestampText(context, reservation['reserved_at']);
    final expiresAt = statusTimestampText(context, reservation['expires_at']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.storefront_outlined, color: Color(0xff287764)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reservation['hub_name']?.toString() ?? 'Community Hub',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(status),
                if (reservedAt != null) Text('Reserved · $reservedAt'),
                if (expiresAt != null) Text('Reservation expires · $expiresAt'),
                if (reservation['receipt_status'] != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Physical receipt · ${friendlyWorkflowStatus(reservation['receipt_status'])}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (receivedAt != null) Text('Received · $receivedAt'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _DonorSectionCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Community hub',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'A reservation holds capacity. It is not confirmation that the hub has received your donation.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: const Color(0xff687a73)),
        ),
        const SizedBox(height: 8),
        if (reservations.isEmpty)
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.store_mall_directory_outlined),
            title: Text('No hub selected yet'),
            subtitle: Text('Choose a community hub when you are ready.'),
          )
        else ...[
          _reservationTile(context, reservations.first, latest: true),
          if (reservations.length > 1)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text('Previous reservations (${reservations.length - 1})'),
              children: [
                for (final reservation in reservations.skip(1))
                  _reservationTile(context, reservation, latest: false),
              ],
            ),
        ],
        if (events.isNotEmpty) ...[
          const SizedBox(height: 4),
          for (final event in events)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const Icon(Icons.history, size: 16, color: Color(0xff687a73)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(event.title)),
                  if (event.occurredAt != null)
                    Text(
                      statusTimestampText(context, event.occurredAt) ?? '',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
        ],
      ],
    ),
  );
}

class _DonorItemRow extends StatelessWidget {
  final Map item;
  final bool isLast;

  const _DonorItemRow({required this.item, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final condition = switch (item['item_condition']?.toString()) {
      'NEW' => 'New',
      'GOOD' => 'Good condition',
      'FAIR' => 'Fair condition',
      'POOR' => 'Needs repair',
      final value? => value.replaceAll('_', ' ').toLowerCase(),
      _ => null,
    };
    return Column(
      children: [
        if (!isLast) const Divider(height: 1, color: Color(0xffedf1ee)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xffe9f4ef),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.volunteer_activism_outlined,
                  size: 20,
                  color: Color(0xff287764),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['item_name']?.toString() ?? 'Donation item',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${item['category'] ?? 'Item'} · ${item['quantity'] ?? '—'} × ${item['unit_weight_kg'] ?? '—'} kg',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xff687a73),
                      ),
                    ),
                    if (condition != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          condition,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: const Color(0xff287764)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DonorDetailActions extends StatelessWidget {
  final bool isBusy;
  final bool needsHub;
  final bool canCancel;
  final VoidCallback onChooseHub;
  final VoidCallback onCancel;

  const _DonorDetailActions({
    required this.isBusy,
    required this.needsHub,
    required this.canCancel,
    required this.onChooseHub,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xffe2ebe6))),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (needsHub)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: isBusy ? null : onChooseHub,
                    icon: const Icon(Icons.storefront_outlined),
                    label: Text(
                      isBusy ? 'Please wait…' : 'Choose a community hub',
                    ),
                  ),
                ),
              if (canCancel)
                SizedBox(
                  width: double.infinity,
                  child: needsHub
                      ? TextButton.icon(
                          onPressed: isBusy ? null : onCancel,
                          icon: const Icon(Icons.close),
                          label: const Text('Cancel donation'),
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                        )
                      : OutlinedButton.icon(
                          onPressed: isBusy ? null : onCancel,
                          icon: const Icon(Icons.close),
                          label: const Text('Cancel donation'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
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

class HubDonationDetailsPage extends StatefulWidget {
  final Map<String, dynamic> hub;
  final String donationId;

  const HubDonationDetailsPage({
    super.key,
    required this.hub,
    required this.donationId,
  });

  @override
  State<HubDonationDetailsPage> createState() => _HubDonationDetailsPageState();
}

class _HubDonationDetailsPageState extends State<HubDonationDetailsPage> {
  late final Future<Map<String, dynamic>> _details = _load();

  Future<Map<String, dynamic>> _load() async {
    final responses = await Future.wait([
      _db.rpc('get_my_hub_inventory', params: {'p_hub': widget.hub['hub_id']}),
      _db.rpc(
        'get_my_hub_reservations',
        params: {'p_hub': widget.hub['hub_id']},
      ),
    ]);
    if (responses.any((response) => response is! List)) {
      throw const FormatException('Hub donation details are unavailable.');
    }
    final inventory = (responses[0] as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .where((row) => row['donation_id']?.toString() == widget.donationId)
        .toList();
    final reservations = (responses[1] as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .where((row) => row['donation_id']?.toString() == widget.donationId)
        .toList();
    if (inventory.isEmpty && reservations.isEmpty) {
      throw const FormatException('Donation not found for this hub.');
    }
    var audit = <Map<String, dynamic>>[];
    String? auditError;
    try {
      final result = await _db.rpc(
        'get_authorized_audit_events',
        params: {'p_entity_type': 'DONATION', 'p_entity_id': widget.donationId},
      );
      if (result is List) {
        audit = result
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
      }
    } catch (_) {
      auditError = 'Recorded event history is not available for this donation.';
    }
    return {
      'inventory': inventory.isEmpty ? null : inventory.first,
      'reservations': reservations,
      'audit': audit,
      'audit_error': auditError,
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Hub Donation Details')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _details,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text('Donation details unavailable: ${snapshot.error}'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        final inventory = data['inventory'] as Map<String, dynamic>?;
        final reservations = (data['reservations'] as List)
            .cast<Map<String, dynamic>>();
        final donationStatus = inventory?['donation_status']?.toString();
        final path =
            inventory?['collection_path']?.toString() ?? 'HUB_COLLECTION';
        final auditRows = (data['audit'] as List).cast<Map<String, dynamic>>();
        final donationEvents = recordedAuditEvents(
          auditRows,
          allowedEventTypes: const {'CONFIRM_HUB_RECEIPT', 'CANCEL_DONATION'},
        );
        final reservationEvents = recordedAuditEvents(
          auditRows,
          allowedEventTypes: const {'RESERVE_HUB', 'EXPIRE_HUB_RESERVATION'},
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              inventory?['title']?.toString() ?? 'Reserved donation',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (donationStatus != null)
              Text('Donation · ${friendlyWorkflowStatus(donationStatus)}'),
            if (inventory?['received_weight_kg'] != null)
              Text('Received weight · ${inventory!['received_weight_kg']} kg'),
            GeoStatusTimeline(
              title: 'Donation Progress',
              currentStatus: donationStatus == null
                  ? null
                  : friendlyWorkflowStatus(donationStatus),
              events: donationEvents,
              pendingMilestones: pendingDonationMilestones(
                collectionPath: path,
                currentStatus: donationStatus,
              ),
              errorMessage: data['audit_error']?.toString(),
              emptyMessage:
                  'No recorded donation progress events are available.',
            ),
            const SizedBox(height: 12),
            Text(
              'Hub Reservation',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (reservations.isEmpty)
              const Text('No reservation history is available.'),
            if (inventory == null)
              const Text(
                'The hub reservation read does not include pre-receipt donation progress.',
              ),
            for (final reservation in reservations)
              Card(
                child: ListTile(
                  title: Text(
                    widget.hub['hub_name']?.toString() ?? 'Community Hub',
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reservation · ${reservationStatusLabel(recordedStatus: reservation['status'], effectiveStatus: null, isLatest: false)}',
                      ),
                      Text(
                        'Expiry · ${statusTimestampText(context, reservation['expires_at']) ?? '—'}',
                      ),
                      Text(
                        'Reserved weight · ${reservation['reserved_weight_kg']} kg',
                      ),
                    ],
                  ),
                ),
              ),
            const Text(
              'The hub reservation list omits reservation creation and receipt timestamps. Audit timestamps are shown when available. Reservation expiry is a deadline, not proof of receipt.',
            ),
            GeoStatusTimeline(
              title: 'Reservation History',
              events: reservationEvents,
              errorMessage: data['audit_error']?.toString(),
              emptyMessage:
                  'No separate reservation change events are available from the current read.',
            ),
            const SizedBox(height: 12),
            Text('Inventory', style: Theme.of(context).textTheme.titleMedium),
            Text(
              inventory == null
                  ? 'No received inventory record is available.'
                  : friendlyWorkflowStatus(inventory['inventory_status']),
            ),
            if (inventory?['inventory_status'] == 'BATCHED')
              const Text(
                'This donation is recorded as part of a batch. The current inventory read does not return its batch ID.',
              ),
          ],
        );
      },
    ),
  );
}

class _HubBatchDetailsPageState extends State<HubBatchDetailsPage> {
  late final Future<Map<String, dynamic>> _details = _load();

  Future<Map<String, dynamic>> _load() async {
    final responses = await Future.wait([
      _db.rpc(
        'get_hub_batch_details',
        params: {'p_hub': widget.hubId, 'p_batch': widget.batchId},
      ),
      _db.rpc('get_my_hub_batches_dashboard', params: {'p_hub': widget.hubId}),
    ]);
    if (responses[0] is! Map) {
      throw const FormatException('Invalid batch detail response.');
    }
    final result = Map<String, dynamic>.from(responses[0] as Map);
    final dashboardRows = responses[1] is List
        ? (responses[1] as List).map(
            (row) => Map<String, dynamic>.from(row as Map),
          )
        : const <Map<String, dynamic>>[];
    for (final row in dashboardRows) {
      if (row['batch_id']?.toString() == widget.batchId) {
        result['published_at'] = row['published_at'];
        break;
      }
    }
    return result;
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
        final donations = (data['donations'] as List? ?? const [])
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        final cover = data['batch_cover_path']?.toString();
        final batchStatus = data['batch_status']?.toString();
        final publishedAt = data['published_at'];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Batch ${data['batch_id']}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              '${friendlyWorkflowStatus(batchStatus)} · ${data['batch_weight_kg'] ?? ''} kg',
            ),
            if (statusTimestampText(context, publishedAt) != null)
              Text(
                'Batch published · ${statusTimestampText(context, publishedAt)}',
              ),
            const Text(
              'This page shows batch status. The current hub batch reads do not expose separate listing availability, NGO claim, lease, or pickup task history.',
            ),
            GeoStatusTimeline(
              title: 'Batch Progress',
              currentStatus: friendlyWorkflowStatus(batchStatus),
              events: statusTimestampText(context, publishedAt) == null
                  ? const []
                  : [
                      StatusTimelineEvent(
                        title: 'Batch published',
                        occurredAt: DateTime.tryParse(publishedAt.toString()),
                      ),
                    ],
              emptyMessage:
                  'No historical batch events are available from the current hub reads.',
            ),
            if (batchStatus == 'PUBLISHED')
              const ListTile(
                leading: Icon(Icons.check_circle_outline),
                title: Text('Batch listing availability'),
                subtitle: Text(
                  'This batch was published. Current listing availability is not included in the hub detail read.',
                ),
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
                    '${donation['weight_kg']} kg · ${friendlyWorkflowStatus(donation['donation_status'])}',
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
            for (final donation in donations)
              GeoStatusTimeline(
                title: 'Donation · ${donation['title'] ?? 'Constituent'}',
                currentStatus: friendlyWorkflowStatus(
                  donation['donation_status'],
                ),
                pendingMilestones: pendingDonationMilestones(
                  collectionPath: 'HUB_COLLECTION',
                  currentStatus: donation['donation_status']?.toString(),
                ),
                emptyMessage:
                    'The hub batch detail read provides current donation state, but no earlier donation timestamps.',
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
                        createDonationPhotoSignedUrl(
                          _db,
                          widget.paths[index],
                          surface: 'DonationPhotoCarousel image #${index + 1}',
                        ),
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
                        errorBuilder: (_, error, stackTrace) {
                          logDonationPhotoNetworkFailure(
                            surface:
                                'DonationPhotoCarousel image #${index + 1}',
                            error: error,
                            stackTrace: stackTrace,
                          );
                          return _photoPlaceholder();
                        },
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
