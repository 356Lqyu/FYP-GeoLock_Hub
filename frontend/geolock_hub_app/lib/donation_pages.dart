import 'routing/claim_coordination.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

import 'async_request_gate.dart';
import 'claim_card.dart';
import 'claim_request.dart';
import 'claim_cards_controller.dart';
import 'routing/ngo_routes_page.dart';
import 'routing/route_resolution_page.dart';
import 'routing/route_resolution_repository.dart';
import 'routing/ngo_routing_repository.dart' show routingObject, routingRows;
import 'location/location_picker_page.dart';
import 'location/location_result.dart';
import 'location/road_routing.dart';
import 'donation_collection_path.dart';
import 'ui/donation_card_content.dart';
import 'donation_photo_rules.dart';
import 'donation_photo_errors.dart';
import 'donation_status.dart';
import 'hub_admin/hub_chooser_page.dart';
import 'hub_admin/hub_dropoff_pass.dart';
import 'hub_admin/hub_service.dart' as hub;
import 'status_timeline.dart';
import 'donor_claim_history.dart';
import 'claim_pickup_detail_reader.dart';
import 'ui/geolock_role_style.dart';

final _db = Supabase.instance.client;

String claimDetailsErrorMessage(Object error) {
  if (error is SocketException || error is TimeoutException) {
    return 'Claim details could not be loaded. Check your connection and retry.';
  }
  if (error is PostgrestException && error.code == 'P0001') {
    return 'We could not verify access to this claim. Refresh My Claims or return to your claim history.';
  }
  if (error is PostgrestException && error.code == 'PGRST202') {
    return 'This claim detail is temporarily unavailable. The secure history reader may not be deployed yet.';
  }
  return 'Claim details are temporarily unavailable. Refresh and try again.';
}

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
  final int refreshSignal;
  final Future<Object?> Function()? listingsLoader;
  final Future<bool> Function()? routingLoader;
  final Widget Function(Map<String, dynamic>)? detailsBuilder;
  const EligibleListingsPage({
    super.key,
    this.refreshSignal = 0,
    this.listingsLoader,
    this.routingLoader,
    this.detailsBuilder,
  });
  @override
  State<EligibleListingsPage> createState() => _EligibleListingsPageState();
}

class _EligibleListingsPageState extends State<EligibleListingsPage> {
  bool _detailOpen = false;
  final _listingsGate = AsyncRequestGate();
  final _routingGate = AsyncRequestGate();
  late Future<List<Map<String, dynamic>>> _listings;
  late Future<bool> _trustedRouting;

  @override
  void initState() {
    super.initState();
    _assignRefreshFutures();
  }

  @override
  void didUpdateWidget(covariant EligibleListingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) _refresh();
  }

  void _assignRefreshFutures() {
    _listings = _listingsGate.run(_load);
    _trustedRouting = _routingGate.run(_loadTrustedRouting);
  }

  void _refresh() {
    _assignRefreshFutures();
    if (mounted) setState(() {});
  }

  Future<void> _refreshAndWait() async {
    _refresh();
    await Future.wait([_listings, _trustedRouting]);
  }

  Future<bool> _loadTrustedRouting() async {
    try {
      final response = widget.routingLoader == null
          ? await _db.rpc('geolock_app_capabilities')
          : await widget.routingLoader!();
      return response is Map && response['road_node_resolution'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final response = widget.listingsLoader == null
        ? await _db.rpc('discover_eligible_listing_cards_v2')
        : await widget.listingsLoader!();
    if (response is! List) {
      throw const FormatException('Invalid listing response.');
    }
    return response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  @override
  Widget build(BuildContext context) =>
      GeoRoleTheme(child: _buildRolePage(context));

  Widget _buildRolePage(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Eligible Listings'),
      actions: [
        IconButton(
          tooltip: 'Saved claim attempts',
          icon: const Icon(Icons.history),
          onPressed: () async {
            final actor = _db.auth.currentUser?.id;
            if (actor == null) return;
            await Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => _SavedClaimAttemptsPage(actor)),
            );
            if (mounted) _refresh();
          },
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            "Listings are based on your NGO's verified location and road-distance eligibility. Eligibility is checked again when you claim.",
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(child: _buildListings()),
      ],
    ),
  );

  Widget _buildListings() => FutureBuilder<List<Map<String, dynamic>>>(
    future: _listings,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: Text('Listing discovery unavailable: ${snapshot.error}'),
        );
      }
      if (snapshot.connectionState != ConnectionState.done ||
          !snapshot.hasData) {
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
          final bool? capabilityReady =
              routeSnapshot.connectionState == ConnectionState.done
              ? routeSnapshot.data == true
              : null;
          return RefreshIndicator(
            onRefresh: _refreshAndWait,
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final listing = rows[index];
                return EligibleListingCard(
                  listing: listing,
                  capabilityReady: capabilityReady,
                  onOpen: () async {
                    if (_detailOpen) return;
                    _detailOpen = true;
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            widget.detailsBuilder?.call(listing) ??
                            NgoListingDetailsPage(
                              listing: listing,
                              onClaimConfirmed: () {
                                if (mounted) _refresh();
                              },
                            ),
                      ),
                    );
                    if (mounted) {
                      _refresh();
                      _detailOpen = false;
                    }
                  },
                );
              },
            ),
          );
        },
      );
    },
  );
}

/// Why a discovered listing cannot be claimed, or null when it can.
/// [capabilityReady] is null while the capability check is still loading.
String? listingClaimBlockReason({
  required bool? capabilityReady,
  required Object? routingStatus,
}) {
  if (capabilityReady == null) return 'Checking the road network…';
  if (!capabilityReady) return 'Road network is not active on the server';
  if (routingStatus != 'READY') return roadStatusLine(routingStatus);
  return null;
}

String? _ngoListingRoadDistance(Object? distanceMeters) {
  if (distanceMeters == null) return null;
  final meters = double.tryParse('$distanceMeters') ?? 0;
  return '${(meters / 1000).toStringAsFixed(1)} km by road';
}

class NgoCollectionPathBadge extends StatelessWidget {
  final Map<String, dynamic> listing;
  const NgoCollectionPathBadge({super.key, required this.listing});

  @override
  Widget build(BuildContext context) {
    final label = collectionPathBadgeLabel(
      listing['collection_path'],
      listingSourceType: listing['source_type'],
    );
    if (label == null) return const SizedBox.shrink();
    final isHub = label == 'Hub Collection';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: isHub ? const Color(0xfffff5df) : const Color(0xffe4f2ed),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: isHub ? const Color(0xff795000) : const Color(0xff215b47),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class NgoListingCardContent extends StatelessWidget {
  final Map<String, dynamic> listing;
  final String title;
  final TextStyle? titleStyle;
  final Widget thumbnail;
  final bool showChevron;
  final Widget? warning;

  const NgoListingCardContent({
    super.key,
    required this.listing,
    required this.title,
    this.titleStyle,
    required this.thumbnail,
    this.showChevron = true,
    this.warning,
  });

  @override
  Widget build(BuildContext context) {
    final distance = _ngoListingRoadDistance(listing['distance_m']);
    return DonationCardContent(
      title: title,
      titleStyle: titleStyle,
      badge: NgoCollectionPathBadge(listing: listing),
      thumbnail: thumbnail,
      facts: {
        'Weight': '${listing['listing_weight_kg'] ?? '—'} kg',
        'Road distance': ?distance,
        if (listing['listing_total_item_quantity'] case final int quantity)
          (listing['source_type'] == 'HUB_BATCH'
                  ? 'Batch total quantity'
                  : 'Total quantity'):
              '$quantity',
        'Listing created': donationCardDate(listing['listing_created_at']),
      },
      trailing: showChevron ? const Icon(Icons.chevron_right) : null,
      footer: warning,
    );
  }
}

class _NgoListingMetric extends StatelessWidget {
  final String label;
  const _NgoListingMetric(this.label);

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xfff1f3f2),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: const Color(0xff36423d)),
      ),
    ),
  );
}

class EligibleListingCard extends StatelessWidget {
  final Map<String, dynamic> listing;
  final bool? capabilityReady;
  final VoidCallback onOpen;
  const EligibleListingCard({
    super.key,
    required this.listing,
    required this.capabilityReady,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final blockReason = listingClaimBlockReason(
      capabilityReady: capabilityReady,
      routingStatus: listing['routing_status'],
    );
    return Card(
      margin: const EdgeInsets.all(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: NgoListingCardContent(
            listing: listing,
            title: '${listing['title'] ?? listing['source_type']}',
            titleStyle: Theme.of(context).textTheme.bodyLarge,
            thumbnail: _StoredImageThumbnail(
              path: listing['primary_image_path']?.toString(),
            ),
            warning: blockReason == null
                ? null
                : Text(
                    'Details may be viewed; claiming unavailable: $blockReason',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
          ),
        ),
      ),
    );
  }
}

class MyClaimsPage extends StatefulWidget {
  final int refreshSignal;
  final Future<Object?> Function()? claimsLoader;
  final Future<Object?> Function(
    String operation,
    String claimId,
    String? requestId,
  )?
  actionRunner;
  final Widget Function(String claimId)? detailBuilder;
  final Widget Function()? routesBuilder;

  /// Test seam for the reconciliation page; defaults to the live v2 panel.
  final Widget Function(ClaimCard card)? reconciliationBuilder;

  /// Repository for the default reconciliation page (live when null).
  final ClaimCoordinationRepository? coordinationRepository;
  const MyClaimsPage({
    super.key,
    this.refreshSignal = 0,
    this.claimsLoader,
    this.actionRunner,
    this.detailBuilder,
    this.routesBuilder,
    this.reconciliationBuilder,
    this.coordinationRepository,
  });
  @override
  State<MyClaimsPage> createState() => _MyClaimsPageState();
}

const hubLocationHint =
    'Choose the hub entrance on or next to a road where vehicles can stop';

/// Hub location picker: the entrance must be within reach of a drivable road.
LocationPickerPage buildHubLocationPicker({
  LocationResult? initialLocation,
  RoadAccessCheck? roadAccessCheck,
}) => LocationPickerPage(
  title: 'Hub Address and Location',
  initialLocation: initialLocation,
  roadAccess: RoadAccessRequirement.required,
  roadAccessCheck: roadAccessCheck,
  hint: hubLocationHint,
);

class RegisterHubPage extends StatefulWidget {
  final Map<String, dynamic>? initialHub;
  final Future<void> Function()? onRegistered;
  const RegisterHubPage({super.key, this.initialHub, this.onRegistered});
  @override
  State<RegisterHubPage> createState() => _RegisterHubPageState();
}

class _RegisterHubPageState extends State<RegisterHubPage> {
  final _name = TextEditingController();
  final _capacity = TextEditingController(text: '100');
  LocationResult? _location;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    final hub = widget.initialHub;
    if (hub != null) {
      _name.text = '${hub['hub_name'] ?? ''}';
      _capacity.text = '${hub['capacity_kg'] ?? 100}';
      final latitude = double.tryParse('${hub['latitude']}');
      final longitude = double.tryParse('${hub['longitude']}');
      if (latitude != null && longitude != null) {
        _location = LocationResult(
          address: '${hub['address_text'] ?? ''}',
          latitude: latitude,
          longitude: longitude,
          method: LocationSelectionMethod.mapPin,
        );
      }
    }
  }

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
        builder: (_) => buildHubLocationPicker(initialLocation: _location),
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
      if (widget.initialHub == null) {
        await _db.rpc(
          'register_community_hub',
          params: {
            'p_name': name,
            'p_address': _location!.address,
            'p_lat': _location!.latitude,
            'p_lon': _location!.longitude,
            'p_capacity_kg': capacity,
            // The backend resolves and validates its own trusted road node.
            'p_road_node': null,
          },
        );
      } else {
        await _db.rpc(
          'update_my_hub',
          params: {
            'p_hub': widget.initialHub!['hub_id'],
            'p_name': name,
            'p_address': _location!.address,
            'p_lat': _location!.latitude,
            'p_lon': _location!.longitude,
            'p_capacity_kg': capacity,
          },
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.initialHub == null
                ? 'Hub registered and its road location was validated.'
                : 'Hub details saved and validated.',
          ),
        ),
      );
      final callback = widget.onRegistered;
      if (callback != null) {
        await callback();
      } else {
        Navigator.pop(context, true);
      }
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
    appBar: AppBar(
      title: Text(
        widget.initialHub == null
            ? 'Register Community Hub'
            : 'Edit Community Hub',
      ),
    ),
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
          child: Text(
            _busy
                ? 'Saving…'
                : widget.initialHub == null
                ? 'Register Hub'
                : 'Save Hub Details',
          ),
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
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
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
                if (widget.section == 'Collections')
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const MyReconciliationCasesPage(role: 'HUB_ADMIN'),
                      ),
                    ),
                    icon: const Icon(Icons.rule_folder_outlined),
                    label: const Text('Handover cases'),
                  ),
                if (widget.section == 'Collections') const SizedBox(height: 8),
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
  final String role;
  const MyReconciliationCasesPage({super.key, required this.role});
  @override
  State<MyReconciliationCasesPage> createState() =>
      _MyReconciliationCasesPageState();
}

class _MyReconciliationCasesPageState extends State<MyReconciliationCasesPage> {
  late Future<List<Map<String, dynamic>>> _cases = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final response = await _db.rpc('get_my_reconciliation_cases');
    if (response is! List) {
      throw const FormatException('Invalid reconciliation inbox response.');
    }
    return response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Handover Reconciliation'),
      actions: [
        if (const bool.fromEnvironment('GEOLOCK_ROUTE_RESOLUTION_ENABLED'))
          IconButton(
            tooltip: 'Route resolution cases',
            icon: const Icon(Icons.assignment_late_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const RouteResolutionInboxPage(),
              ),
            ),
          ),
      ],
    ),
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
                    ClaimCoordinationPanel(
                      claimId: row['claim_id'] as String,
                      viewerRole: widget.role,
                      sourceType: row['source_type'] as String?,
                      onChanged: () async {
                        if (mounted) setState(() => _cases = _load());
                      },
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

class _MyClaimsPageState extends State<MyClaimsPage>
    with WidgetsBindingObserver {
  late final ClaimCardsController _reader;
  StreamSubscription<AuthState>? _authSubscription;
  ClaimTab _selectedTab = ClaimTab.active;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reader = ClaimCardsController(
      load: () =>
          widget.claimsLoader?.call() ?? _db.rpc('get_my_claim_cards_v2'),
      identity: () =>
          widget.claimsLoader != null ? 'injected' : _db.auth.currentUser?.id,
    )..addListener(_changed);
    if (widget.claimsLoader == null) {
      _authSubscription = _db.auth.onAuthStateChange.listen((_) {
        _reader.invalidate();
        unawaited(_reader.refresh());
      });
    }
    unawaited(_reader.refresh());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant MyClaimsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      unawaited(_reader.refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_reader.refresh());
    } else {
      _reader.invalidate();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    _reader.dispose();
    super.dispose();
  }

  bool _allowed(ClaimCard card, String operation) =>
      _reader.fresh &&
      _reader.cards.contains(card) &&
      !_busy &&
      switch (operation) {
        // Injected runners are test transports. Production pickups use the
        // route-detail screen and its fresh protected backend authorization.
        'START_PICKUP' => widget.actionRunner != null && card.canStart,
        'COMPLETE_PICKUP' => widget.actionRunner != null && card.canComplete,
        'CANCEL_CLAIM' => card.canCancel,
        _ => false,
      };

  Future<Object?> _callAction(
    String operation,
    String claimId, [
    String? requestId,
  ]) {
    if (widget.actionRunner != null) {
      return widget.actionRunner!(operation, claimId, requestId);
    }
    return switch (operation) {
      'START_PICKUP' || 'COMPLETE_PICKUP' => throw StateError(
        'Open an authorized route to perform pickup actions.',
      ),
      'CANCEL_CLAIM' => _db.rpc(
        'cancel_claim',
        params: {'p_claim': claimId, 'p_request': requestId},
      ),
      _ => throw ArgumentError.value(operation),
    };
  }

  Future<void> _run(ClaimCard card, String operation) async {
    if (!_allowed(card, operation)) return;
    setState(() => _busy = true);
    try {
      await _callAction(operation, card.claimId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$operation committed by the database.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$operation was not confirmed: $error')),
        );
      }
    } finally {
      if (mounted) {
        await _reader.refresh();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _cancelClaim(ClaimCard card) async {
    if (!_allowed(card, 'CANCEL_CLAIM')) return;
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
    if (confirmed != true || !mounted || !_allowed(card, 'CANCEL_CLAIM')) {
      return;
    }
    // Preserve the persisted request key for safe retries after uncertain outcomes.
    setState(() => _busy = true);
    String? requestId;
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = widget.claimsLoader != null
          ? 'injected'
          : _db.auth.currentUser?.id;
      final key = 'geolock_cancel_claim_${userId}_${card.claimId}';
      requestId = prefs.getString(key) ?? const Uuid().v4();
      await prefs.setString(key, requestId);
      // A refresh, deadline or account change while preferences loaded invalidates this card.
      if (!mounted || !_reader.fresh || !_reader.cards.contains(card)) return;
      final response = await _callAction(
        'CANCEL_CLAIM',
        card.claimId,
        requestId,
      );
      if (response is! Map || response['outcome'] == null) {
        throw const FormatException('Cancellation outcome missing.');
      }
      if (response['outcome'] == 'SUCCESS' ||
          response['outcome'] == 'REJECTED') {
        await prefs.remove(key);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Claim ${response['outcome']}: ${response['reason_code'] ?? ''}",
            ),
          ),
        );
      }
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
      if (mounted) {
        await _reader.refresh();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _openReconciliation(ClaimCard card) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            widget.reconciliationBuilder?.call(card) ??
            ClaimReconciliationPage(
              claimId: card.claimId,
              title: card.title ?? 'Handover reconciliation',
              viewerRole: 'NGO',
              sourceType: card.sourceType,
              routeNotice: card.taskStatus == 'DISPATCHED'
                  ? 'While this pickup is unresolved, the next pickup on its route stays blocked.'
                  : null,
              repository: widget.coordinationRepository,
            ),
      ),
    );
    if (mounted) await _reader.refresh();
  }

  Future<void> _openDetails(ClaimCard card) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            widget.detailBuilder?.call(card.claimId) ??
            ClaimPickupDetailPage(
              claimId: card.claimId,
              coordinationRepository: widget.coordinationRepository,
            ),
      ),
    );
    if (mounted) await _reader.refresh();
  }

  Future<void> _openRoutes() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => widget.routesBuilder?.call() ?? const NgoRoutesPage(),
      ),
    );
    if (mounted) await _reader.refresh();
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
  Widget build(BuildContext context) =>
      GeoRoleTheme(child: _buildRolePage(context));

  Widget _buildRolePage(BuildContext context) {
    const labels = {
      ClaimTab.active: 'Active',
      ClaimTab.reconciliation: 'Reconciliation',
      ClaimTab.expired: 'Expired',
      ClaimTab.history: 'History',
      ClaimTab.all: 'All',
    };
    final byTab = {
      for (final tab in ClaimTab.values)
        tab: _reader.cards
            .where((card) => tab == ClaimTab.all || card.tab == tab)
            .toList(),
    };
    final rows = byTab[_selectedTab]!;
    return Scaffold(
      appBar: AppBar(title: const Text('My Claims')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final tab in ClaimTab.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ValueKey('claims-tab-${tab.name}'),
                      shape: geoFilterChipShape,
                      label: Text(
                        _reader.loading || _reader.error != null
                            ? labels[tab]!
                            : '${labels[tab]} (${byTab[tab]!.length})',
                      ),
                      selected: tab == _selectedTab,
                      onSelected: (_) => setState(() => _selectedTab = tab),
                    ),
                  ),
              ],
            ),
          ),
          if (_reader.loading) const LinearProgressIndicator(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reader.refresh,
              child: ListView(
                key: PageStorageKey('claims-${_selectedTab.name}'),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (_reader.error != null)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          const Text(
                            'Claim history unavailable. Check your connection and refresh. Actions are disabled.',
                          ),
                          TextButton(
                            onPressed: _reader.refresh,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  else if (!_reader.loading && rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _reader.cards.isEmpty
                            ? 'No claims yet.'
                            : 'No ${_selectedTab.name} claims.',
                      ),
                    ),
                  for (final card in rows) _card(card),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(ClaimCard card) {
    final collectionPath = collectionPathBadgeLabel(
      card.raw['collection_path'],
      listingSourceType: card.sourceType,
    );
    final created = statusTimestampText(context, card.raw['claimed_at']);
    final expiry = statusTimestampText(context, card.raw['lease_expires_at']);
    final pickupStatus = switch (card.taskStatus) {
      'CONFIRMED' => 'Waiting for route setup',
      'PLANNED' => 'Route planned',
      'DISPATCHED' => 'Pickup in progress',
      _ => null,
    };
    final reconciling = card.displayStatus == ClaimDisplayStatus.reconciliation;
    final expired = card.tab == ClaimTab.expired;
    final details = {
      'Claim created': ?created,
      if (card.isValidActive || expired) 'Lease expires': ?expiry,
      if (card.isValidActive) 'Pickup status': ?pickupStatus,
      if (reconciling) ...{
        'Issue': 'Handover unresolved',
        'Current step': 'Review reconciliation',
        if (card.taskStatus == 'DISPATCHED')
          'Route impact': 'Next pickup blocked',
      },
      if (expired) 'Recovery': 'The database controls recovery.',
      if (expired && card.taskStatus == 'DISPATCHED')
        'Pickup status': 'Started. Custody requires review.',
    };
    return Card(
      key: ValueKey('claim-${card.claimId}'),
      margin: const EdgeInsets.all(10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      card.title ??
                          (card.sourceType == 'HUB_BATCH'
                              ? 'Hub batch'
                              : 'Claim'),
                      style: geoTitleStyle(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * .56,
                    ),
                    child: GeoStatusChip(
                      card.badge,
                      tone: switch (card.tab) {
                        ClaimTab.reconciliation => GeoTone.warning,
                        ClaimTab.history => GeoTone.neutral,
                        _ => null,
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _StoredImageThumbnail(path: card.primaryImagePath),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (collectionPath != null)
                        GeoStatusChip(collectionPath, tone: GeoTone.neutral),
                      if (card.listingWeightKg != null)
                        _NgoListingMetric('${card.listingWeightKg} kg'),
                    ],
                  ),
                ),
              ],
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    for (final detail in details.entries)
                      SizedBox(
                        width: (constraints.maxWidth - 12) / 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              detail.key,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            Text(detail.value),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (card.displayStatus == ClaimDisplayStatus.needsReview)
              const Text(
                'Refresh to verify this claim before attempting pickup.',
              ),
            if (!_reader.fresh)
              const Text('Refresh required before claim actions.'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (reconciling)
                  FilledButton.icon(
                    key: ValueKey('claim-reconciliation-${card.claimId}'),
                    onPressed: () => _openReconciliation(card),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('View reconciliation'),
                  ),
                if (widget.actionRunner == null && card.isValidActive)
                  FilledButton.icon(
                    key: ValueKey('claim-routes-${card.claimId}'),
                    onPressed: _reader.fresh && !_busy ? _openRoutes : null,
                    icon: const Icon(Icons.route),
                    label: const Text('Pickup routes'),
                  ),
                if (card.claimStatus == 'ACTIVE' &&
                    widget.actionRunner != null &&
                    const {'CONFIRMED', 'PLANNED'}.contains(card.taskStatus))
                  OutlinedButton(
                    onPressed: _allowed(card, 'START_PICKUP')
                        ? () => _run(card, 'START_PICKUP')
                        : null,
                    child: const Text('Start Pickup'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _openDetails(card),
                  icon: const Icon(Icons.location_on_outlined),
                  label: const Text('Claim details'),
                ),
                if (card.claimStatus == 'ACTIVE' &&
                    widget.actionRunner != null &&
                    card.taskStatus == 'DISPATCHED')
                  FilledButton(
                    onPressed: _allowed(card, 'COMPLETE_PICKUP')
                        ? () => _run(card, 'COMPLETE_PICKUP')
                        : null,
                    child: const Text('Confirm Handover'),
                  ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => _audit(card.claimId),
                  icon: const Icon(Icons.history),
                  label: const Text('Audit'),
                ),
                if (_allowed(card, 'CANCEL_CLAIM'))
                  TextButton(
                    onPressed: () => _cancelClaim(card),
                    child: const Text('Cancel Claim'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedClaimAttemptsPage extends StatefulWidget {
  const _SavedClaimAttemptsPage(this.actor);

  final String actor;

  @override
  State<_SavedClaimAttemptsPage> createState() =>
      _SavedClaimAttemptsPageState();
}

class _SavedClaimAttemptsPageState extends State<_SavedClaimAttemptsPage> {
  late Future<List<MapEntry<String, String>>> _attempts = _load();

  Future<List<MapEntry<String, String>>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_db.auth.currentUser?.id != widget.actor) return [];
    final prefix = claimRequestPrefix(widget.actor);
    final keys = prefs.getKeys().where((key) => key.startsWith(prefix)).toList()
      ..sort();
    return [
      for (final key in keys)
        if (prefs.get(key) case final String request when request.isNotEmpty)
          MapEntry(key.substring(prefix.length), request),
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Saved claim attempts')),
    body: FutureBuilder<List<MapEntry<String, String>>>(
      future: _attempts,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text('Saved attempts could not be loaded.'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final attempts = snapshot.data!;
        if (attempts.isEmpty || _db.auth.currentUser?.id != widget.actor) {
          return const Center(child: Text('No saved claim attempts.'));
        }
        return ListView(
          children: [
            for (final attempt in attempts)
              ListTile(
                title: const Text('Saved claim attempt'),
                subtitle: Text('Listing ${attempt.key}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => NgoListingDetailsPage(
                        listing: {'listing_id': attempt.key},
                        savedRequestId: attempt.value,
                      ),
                    ),
                  );
                  if (mounted) setState(() => _attempts = _load());
                },
              ),
          ],
        );
      },
    ),
  );
}

class NgoListingDetailsPage extends StatefulWidget {
  final Map<String, dynamic> listing;
  final VoidCallback? onClaimConfirmed;
  final Future<Object?> Function()? listingsLoader;
  final Future<Map<String, dynamic>> Function()? detailsLoader;
  final Future<bool> Function()? routingLoader;
  final Future<Object?> Function(String listing, String request)? claimSender;
  final String? Function()? identity;
  final VoidCallback? onSuccess;
  final String? savedRequestId;
  const NgoListingDetailsPage({
    super.key,
    required this.listing,
    this.onClaimConfirmed,
    this.listingsLoader,
    this.detailsLoader,
    this.routingLoader,
    this.claimSender,
    this.identity,
    this.onSuccess,
    this.savedRequestId,
  });

  @override
  State<NgoListingDetailsPage> createState() => _NgoListingDetailsPageState();
}

class _NgoListingDetailsPageState extends State<NgoListingDetailsPage> {
  bool _availabilityExitScheduled = false;
  bool _savedAttemptFinished = false;
  String? _rejectionMessage;
  int _availabilityGeneration = 0;
  StreamSubscription<AuthState>? _authSubscription;

  bool _leaveUnavailableListing() {
    if (!mounted || _availabilityExitScheduled) return true;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return false;
    _availabilityExitScheduled = true;
    _availabilityVerified = false;
    final messenger = ScaffoldMessenger.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || route?.isCurrent != true) return;
      navigator.pop();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _rejectionMessage ??
                'Donation availability changed\nThis donation is no longer available to claim.',
          ),
          duration: Duration(seconds: 8),
        ),
      );
    });
    return true;
  }

  late Future<Map<String, dynamic>> _details = _verifyAvailability();
  late Future<bool> _trustedRouting = _loadTrustedRouting();
  late Map<String, dynamic> _currentListing = widget.listing;
  bool _claimBusy = false;
  bool _availabilityVerified = false;
  bool _refreshing = true;
  bool _verificationFailed = false;
  bool _conflict = false;

  String? get _identity =>
      widget.identity?.call() ??
      (widget.identity == null ? _db.auth.currentUser?.id : null);

  String? get _verificationIdentity =>
      widget.listingsLoader != null && widget.identity == null
      ? null
      : _identity;

  @override
  void initState() {
    super.initState();
    if (widget.savedRequestId != null ||
        widget.identity != null ||
        widget.listingsLoader != null) {
      return;
    }
    var observedIdentity = _identity;
    _authSubscription = _db.auth.onAuthStateChange.listen((_) {
      final identity = _identity;
      if (!mounted || identity == observedIdentity) return;
      observedIdentity = identity;
      _refreshAvailability(identityChanged: true);
    });
  }

  @override
  void dispose() {
    _availabilityGeneration++;
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _verifyAvailability() async {
    final generation = ++_availabilityGeneration;
    final userId = _verificationIdentity;
    try {
      final data = await _load(generation, userId);
      if (userId != _verificationIdentity) throw StateError('Account changed.');
      if (mounted && generation == _availabilityGeneration) {
        setState(() {
          _availabilityVerified = data['listing_discovered_available'] == true;
          if (_availabilityVerified) _conflict = false;
          _refreshing = false;
          _verificationFailed = false;
        });
        if (!_availabilityVerified) _leaveUnavailableListing();
      }
      return data;
    } catch (_) {
      if (mounted && generation == _availabilityGeneration) {
        setState(() {
          _availabilityVerified = false;
          _refreshing = false;
          _verificationFailed = true;
        });
      }
      // Never retain previously authorized photos/details after a failed read.
      return {
        'images': <Map<String, dynamic>>[],
        'constituents': <Map<String, dynamic>>[],
        'listing_discovered_available': false,
      };
    }
  }

  void _refreshAvailability({bool identityChanged = false}) {
    if (!identityChanged && (_refreshing || _claimBusy)) return;
    setState(() {
      _availabilityVerified = false;
      _refreshing = true;
      _details = _verifyAvailability();
      _trustedRouting = _loadTrustedRouting();
    });
  }

  Future<bool> _loadTrustedRouting() async {
    try {
      if (widget.routingLoader != null) return await widget.routingLoader!();
      final response = await _db.rpc('geolock_app_capabilities');
      return response is Map && response['road_node_resolution'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _claim() async {
    final savedRequest = widget.savedRequestId;
    if (_claimBusy ||
        _savedAttemptFinished ||
        (savedRequest == null &&
            (!_availabilityVerified ||
                _refreshing ||
                _availabilityExitScheduled))) {
      return;
    }
    final userId = _identity;
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in with an NGO account to claim.')),
      );
      return;
    }
    final listingId = widget.listing['listing_id']?.toString();
    if (listingId == null || listingId.isEmpty) return;

    String? request;
    SharedPreferences? prefs;
    Map<String, dynamic>? result;
    var rpcStarted = false;
    setState(() => _claimBusy = true);
    try {
      prefs = await SharedPreferences.getInstance();
      final key = '${claimRequestPrefix(userId)}$listingId';
      final storage = prefs;
      final response = await sendPersistedClaim<Object?>(
        readRequest: () => storage.getString(key),
        writeRequest: (id) => storage.setString(key, id),
        newRequest: () => const Uuid().v4(),
        expectedRequest: savedRequest,
        send: (id) async {
          request = id;
          if (_identity != userId) {
            throw StateError('Your sign-in changed. No claim was sent.');
          }
          rpcStarted = true;
          if (widget.claimSender != null) {
            return widget.claimSender!(listingId, id);
          }
          return _db.rpc(
            'claim_listing',
            params: {'p_listing': listingId, 'p_request': id},
          );
        },
      );
      if (response is! Map) {
        throw const FormatException(
          'Claim RPC returned no authoritative outcome.',
        );
      }
      result = Map<String, dynamic>.from(response);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Claim transport/preparation error: ${error.runtimeType}');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is PostgrestException &&
                      error.code == 'P0001' &&
                      const {
                        'UNAUTHENTICATED',
                        'ACTIVE_NGO_ONLY',
                        'REQUEST_AND_LISTING_REQUIRED',
                      }.contains(error.message)
                  ? claimRejectionMessage(error.message)
                  : rpcStarted
                  ? 'Claim outcome is unconfirmed. Retry this same attempt; your saved request will be reused.'
                  : 'The claim could not be prepared safely. No claim request was sent. Please try again.',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      if (mounted) setState(() => _claimBusy = false);
      return;
    }

    if (_identity != userId) {
      if (mounted) setState(() => _claimBusy = false);
      return;
    }
    final outcome = result['outcome']?.toString();
    final reason = result['reason_code']?.toString();
    final claimId = result['claim_id']?.toString();
    if (isConfirmedClaimFailure(result)) {
      if (mounted) {
        setState(() => _claimBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(confirmedClaimFailureMessage(result))),
        );
      }
      return; // Preserve the request UUID; never report an uncertain RPC as failed.
    }
    final confirmedSuccess =
        outcome == 'SUCCESS' && claimId != null && claimId.isNotEmpty;
    final confirmedRejection =
        (outcome == 'CONFLICT' || outcome == 'INELIGIBLE') &&
        reason != null &&
        reason.isNotEmpty;
    if (!confirmedSuccess && !confirmedRejection) {
      if (mounted) {
        setState(() => _claimBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Claim outcome is unconfirmed. Retry this same attempt; your saved request will be reused.',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      return;
    }

    // The database returned a complete terminal result. Removing the stored
    // key is best-effort; if it fails, replaying it remains idempotent.
    if (mounted) {
      setState(() {
        _availabilityVerified = false;
        if (!confirmedSuccess) _conflict = true;
      });
    }
    try {
      final key = '${claimRequestPrefix(userId)}$listingId';
      if (_identity == userId && prefs.getString(key) == request) {
        await prefs.remove(key);
      }
    } catch (_) {}
    if (!mounted) return;
    if (!confirmedSuccess) {
      _rejectionMessage = claimRejectionMessage(reason);
      if (kDebugMode) {
        debugPrint('Claim rejected: $outcome / $reason / $request');
      }
      if (savedRequest == null &&
          outcome == 'CONFLICT' &&
          const {
            'CLAIM_CONFLICT',
            'LISTING_EXPIRED',
            'LISTING_NOT_FOUND',
          }.contains(reason) &&
          _leaveUnavailableListing()) {
        return;
      }
      setState(() {
        _claimBusy = false;
        _availabilityVerified = false;
        _conflict = true;
        _savedAttemptFinished = savedRequest != null;
      });
      if (savedRequest == null) _refreshAvailability();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_rejectionMessage!)));
      return;
    }

    // Backend confirmation is complete before this UI transition. Refresh the
    // underlying Discover results, then load My Claims from its protected RPC.
    try {
      widget.onClaimConfirmed?.call();
    } catch (_) {
      // A presentation refresh failure must not misreport the committed claim.
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Claim confirmed. Open Pickup routes in My Claims to plan an authorized pickup.',
        ),
      ),
    );
    if (widget.onSuccess != null) {
      setState(() {
        _claimBusy = false;
        _availabilityVerified = false;
        _savedAttemptFinished = savedRequest != null;
      });
      widget.onSuccess!();
      return;
    }
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const MyClaimsPage()));
  }

  Future<Map<String, dynamic>> _load(int generation, String? userId) async {
    final response = widget.listingsLoader != null
        ? await widget.listingsLoader!()
        : await _db.rpc('discover_eligible_listing_cards');
    if (!mounted ||
        generation != _availabilityGeneration ||
        userId != _verificationIdentity) {
      throw StateError('Listing verification superseded.');
    }
    if (response is! List) {
      throw const FormatException('Invalid discovery response');
    }
    final matches = response.whereType<Map>().where(
      (row) => row['listing_id'] == widget.listing['listing_id'],
    );
    if (matches.length > 1 ||
        response.any((row) => row is! Map || row['listing_id'] == null)) {
      throw const FormatException('Ambiguous discovery response');
    }
    if (matches.isEmpty) {
      return {
        'images': <Map<String, dynamic>>[],
        'constituents': <Map<String, dynamic>>[],
        'listing_discovered_available': false,
      };
    }
    _currentListing = Map<String, dynamic>.from(matches.single);
    if (widget.detailsLoader != null) return widget.detailsLoader!();
    final row = _currentListing;
    final isBatch = row['source_type'] == 'HUB_BATCH';
    // This protected read revalidates availability and exact road eligibility
    // before details or any image references are shown, for either source type.
    final rawMembers = await _db.rpc(
      'get_eligible_listing_constituents_v2',
      params: {'p_listing': row['listing_id']},
    );
    if (!mounted ||
        generation != _availabilityGeneration ||
        userId != _verificationIdentity) {
      throw StateError('Listing verification superseded.');
    }
    if (rawMembers is! List) {
      throw const FormatException('Invalid eligible listing detail response.');
    }
    final constituents = rawMembers
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    // Photos are optional. A missing record or a Storage/photo-read failure
    // must not hide details that the protected listing RPC authorized.
    final images = await _loadOptionalListingImages(
      isBatch ? 'get_batch_images' : 'get_donation_images',
      isBatch
          ? {'p_batch': row['batch_id']}
          : {'p_donation': row['donation_id']},
    );
    // Items with their own photos. The reader authorizes exactly the
    // donations of get_eligible_listing_constituents_v2 and, like the photo
    // reads above, is optional.
    final items = await _loadOptionalListingImages(
      'get_eligible_listing_items',
      {'p_listing': row['listing_id']},
    );
    return {
      'images': images,
      'items': items,
      'constituents': constituents,
      // discover_eligible_listings() returned this row only while it was
      // available and eligible. The claim RPC rechecks that state atomically.
      'listing_discovered_available': true,
      'progress_status': isBatch ? 'PUBLISHED' : 'AVAILABLE',
    };
  }

  Future<List<Map<String, dynamic>>> _loadOptionalListingImages(
    String rpc,
    Map<String, dynamic> params,
  ) async {
    try {
      final response = await _db.rpc(rpc, params: params);
      if (response is! List) return [];
      return response
          .map((image) => Map<String, dynamic>.from(image as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) =>
      GeoRoleTheme(child: _buildRolePage(context));

  Widget _buildRolePage(BuildContext context) => widget.savedRequestId != null
      ? _buildSavedAttempt()
      : _buildListing(context);

  Widget _buildSavedAttempt() => Scaffold(
    appBar: AppBar(title: const Text('Saved claim attempt')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Retry using the original request. The server will return a saved result or check whether this attempt can still be completed.',
        ),
        if (_rejectionMessage case final String message) Text(message),
        FilledButton(
          onPressed: _claimBusy || _savedAttemptFinished ? null : _claim,
          child: Text(_claimBusy ? 'Checking claim…' : 'Retry saved claim'),
        ),
      ],
    ),
  );

  Widget _buildListing(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Donation Listing')),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: FutureBuilder<Map<String, dynamic>>(
        future: _details,
        builder: (context, detailSnapshot) => FutureBuilder<bool>(
          future: _trustedRouting,
          builder: (context, routeSnapshot) {
            final routeReady =
                routeSnapshot.connectionState == ConnectionState.done &&
                routeSnapshot.data == true &&
                _currentListing['routing_status'] == 'READY';
            return FilledButton.icon(
              onPressed:
                  detailSnapshot.connectionState == ConnectionState.done &&
                      detailSnapshot.hasData &&
                      routeReady &&
                      !_claimBusy &&
                      _availabilityVerified &&
                      !_refreshing
                  ? _claim
                  : null,
              icon: _claimBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.volunteer_activism_outlined),
              label: Text(
                _claimBusy
                    ? 'Confirming claim…'
                    : routeReady
                    ? 'Claim listing'
                    : 'Claim unavailable',
              ),
            );
          },
        ),
      ),
    ),
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
        final images = _availabilityVerified
            ? (data['images'] as List).cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
        final constituents = _availabilityVerified
            ? (data['constituents'] as List).cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
        final listingItems = _availabilityVerified
            ? (data['items'] as List? ?? const []).cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
        final cover = _availabilityVerified
            ? _currentListing['primary_image_path']?.toString()
            : null;
        final imagePaths = images
            .map((image) => image['storage_path']?.toString() ?? '')
            .where((path) => path.isNotEmpty)
            .toList();
        if (cover != null && cover.isNotEmpty) imagePaths.insert(0, cover);
        for (final constituent in constituents) {
          final path = constituent['primary_image_path']?.toString();
          if (path != null && path.isNotEmpty) imagePaths.add(path);
        }
        final uniqueImagePaths = imagePaths.toSet().toList();
        // Item photos are shown beside their items, not again in the gallery.
        final galleryPaths = DonationItemPhotoRules.legacyGalleryPaths(
          uniqueImagePaths,
          listingItems,
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_conflict ||
                (!_availabilityVerified &&
                    !_verificationFailed &&
                    !_refreshing)) ...[
              const Text(
                'Donation availability changed',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text(
                'This donation is no longer available to claim. Please refresh the donation list.',
              ),
            ],
            if (_refreshing) const Text('Checking availability…'),
            if (_verificationFailed)
              const Text('Unable to verify availability'),
            Text(
              widget.listing['title']?.toString() ?? 'Community Hub Batch',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text('${widget.listing['listing_weight_kg']} kg'),
            const SizedBox(height: 4),
            Text(
              collectionPathBadgeLabel(
                    _currentListing['collection_path'],
                    listingSourceType: _currentListing['source_type'],
                  ) ??
                  'Collection path unavailable',
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Listing availability'),
                subtitle: Text(
                  _verificationFailed
                      ? 'Unable to verify availability'
                      : _refreshing
                      ? 'Checking availability…'
                      : !_availabilityVerified
                      ? 'Unavailable for your account in the latest authorized discovery response.'
                      : 'Eligible in the latest discovery response. Availability and claim eligibility are rechecked by the database when you claim.',
                ),
              ),
            ),
            GeoStatusTimeline(
              title: widget.listing['source_type'] == 'HUB_BATCH'
                  ? 'Batch Progress'
                  : 'Donation Progress',
              currentStatus: !_availabilityVerified
                  ? (_verificationFailed
                        ? 'Unable to verify availability'
                        : _refreshing
                        ? 'Checking availability'
                        : 'Unavailable to claim')
                  : friendlyWorkflowStatus(data['progress_status']),
              pendingMilestones:
                  _availabilityVerified &&
                      data['progress_status'] == 'AVAILABLE'
                  ? pendingDonationMilestones(
                      collectionPath: 'DIRECT_PICKUP',
                      currentStatus: 'AVAILABLE',
                    )
                  : const [],
              emptyMessage:
                  'This state is present in the eligible discovery response. Historical status timestamps are not provided on this screen.',
            ),
            const SizedBox(height: 12),
            if (galleryPaths != null) ...[
              DonationPhotoCarousel(paths: galleryPaths),
              const SizedBox(height: 12),
            ],
            Text(
              'Routing: ${roadStatusLine(widget.listing['routing_status'])}',
            ),
            const Text(
              'A listing appears only after backend eligibility checks. The database rechecks the road distance (20 km or less) when you claim.',
            ),
            if (constituents.isNotEmpty) ...[
              const Divider(),
              Text(
                widget.listing['source_type'] == 'HUB_BATCH'
                    ? 'Donations in this batch'
                    : 'Donation overview',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final donation in constituents)
                ListTile(
                  leading: _StoredImageThumbnail(
                    path: donation['primary_image_path']?.toString(),
                  ),
                  title: Text(donation['title'].toString()),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${donation['total_weight_kg']} kg · ${friendlyWorkflowStatus(donation['donation_status'])}',
                      ),
                      if (snapshot.connectionState == ConnectionState.done)
                        if (_donationDescription(donation)
                            case final String text)
                          _DonationDescription(text),
                    ],
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
            if (listingItems.isNotEmpty) ...[
              const Divider(),
              Text(
                'Items (${listingItems.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              _DonationItemList(
                items: listingItems,
                donationTitles: {
                  for (final donation in constituents)
                    '${donation['donation_id']}': '${donation['title']}',
                },
              ),
            ],
            const SizedBox(height: 8),
          ],
        );
      },
    ),
  );
}

String _claimPhotoReadError(Object error) {
  final denied =
      (error is StorageException &&
          const {'401', '403'}.contains(error.statusCode)) ||
      (error is PostgrestException &&
          const {'42501', 'PGRST301'}.contains(error.code)) ||
      (error is NetworkImageLoadException &&
          const {401, 403}.contains(error.statusCode));
  return denied
      ? 'Donation photos are inaccessible with your current permissions.'
      : 'Donation photos could not be loaded. Check your connection and refresh.';
}

class ClaimPickupDetailPage extends StatefulWidget {
  final String claimId;
  final ClaimPickupDetailReader? reader;
  final Future<String> Function(String path)? photoUrlResolver;

  /// Reconciliation reads/submissions for the linked reconciliation page.
  /// Defaults to the live participant-scoped repository; injected by tests.
  final ClaimCoordinationRepository? coordinationRepository;
  const ClaimPickupDetailPage({
    super.key,
    required this.claimId,
    this.reader,
    this.photoUrlResolver,
    this.coordinationRepository,
  });

  @override
  State<ClaimPickupDetailPage> createState() => _ClaimPickupDetailPageState();
}

class _ClaimPickupDetailPageState extends State<ClaimPickupDetailPage>
    with WidgetsBindingObserver {
  late Future<Map<String, dynamic>> _detail = _load();
  Timer? _leaseRefresh;
  int _generation = 0;
  StreamSubscription<AuthState>? _authSubscription;
  ClaimPickupDetailReader get _reader =>
      widget.reader ?? SupabaseClaimPickupDetailReader(_db);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.reader == null) {
      _authSubscription = _db.auth.onAuthStateChange.listen(
        (_) => _refreshDetail(),
      );
    }
  }

  void _refreshDetail() {
    _leaseRefresh?.cancel();
    if (mounted) {
      setState(() {
        _detail = _load();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _leaseRefresh?.cancel();
    if (state == AppLifecycleState.resumed) _refreshDetail();
  }

  @override
  void dispose() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    _leaseRefresh?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _load() async {
    final generation = ++_generation;
    final userId = _reader.identity;
    final elapsed = Stopwatch()..start();
    final cards = await _reader.rpc('get_my_claim_cards_v2');
    if (cards is! List || cards.any((row) => row is! Map)) {
      throw const FormatException('Invalid claim history response.');
    }
    Map<String, dynamic>? claimCard;
    for (final row in cards) {
      final card = Map<String, dynamic>.from(row as Map);
      if (card['claim_id']?.toString() == widget.claimId) {
        claimCard = card;
        break;
      }
    }
    if (claimCard == null) {
      throw StateError('Claim details could not be verified for this account.');
    }
    final presentation = ClaimCard.fromJson(claimCard);
    // Basic claim history is available from the owned card and audit stream.
    // Do not fetch operational detail or historical constituents for this view.
    final cardOnly =
        const {
          'RELEASED',
          'EXPIRED',
          'COMPLETED',
          'CANCELLED',
        }.contains(presentation.claimStatus) ||
        // Reconciliation claims moved to their own My Claims section but
        // still need the operational detail that carries their actions.
        !const {
          ClaimTab.active,
          ClaimTab.reconciliation,
        }.contains(presentation.tab) ||
        presentation.displayStatus == ClaimDisplayStatus.needsReview ||
        (presentation.claimStatus == 'ACTIVE' && !presentation.isValidActive);

    late final Map<String, dynamic> result;
    if (cardOnly) {
      result = <String, dynamic>{};
    } else {
      final response = await _reader.rpc(
        'get_claimed_listing_detail',
        params: {'p_claim': widget.claimId},
      );
      if (response is! Map) {
        throw const FormatException('Invalid claim detail response.');
      }
      result = Map<String, dynamic>.from(response);
      final constituents = await _reader.rpc(
        'get_claimed_listing_constituents_v2',
        params: {'p_claim': widget.claimId},
      );
      if (constituents is! List || constituents.any((row) => row is! Map)) {
        throw const FormatException('Invalid claim constituents response.');
      }
      result['constituents'] = constituents
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      // Claim detail returns donation_ids rather than a singular donation_id.
      // Use the claim-authorized constituents before requesting photo metadata.
      final donationIds = (result['constituents'] as List)
          .map((row) => row['donation_id']?.toString())
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet();
      final images = <Map<String, dynamic>>[];
      for (final donationId in donationIds) {
        try {
          final photos = await _reader.rpc(
            'get_donation_images',
            params: {'p_donation': donationId},
          );
          if (photos is! List || photos.any((row) => row is! Map)) {
            throw const FormatException('Invalid photo metadata');
          }
          images.addAll(
            photos.map((row) => Map<String, dynamic>.from(row as Map)),
          );
        } catch (error) {
          // Optional media must never hide claim details or custody actions.
          result['photo_error'] = _claimPhotoReadError(error);
        }
      }
      result['donation_images'] = images;
      // Items with their own photos. The reader authorizes exactly the
      // donations of get_claimed_listing_constituents_v2 for this claim.
      try {
        final itemRows = await _reader.rpc(
          'get_claimed_listing_items',
          params: {'p_claim': widget.claimId},
        );
        result['items'] = itemRows is List
            ? itemRows
                  .whereType<Map>()
                  .map((row) => Map<String, dynamic>.from(row))
                  .toList()
            : <Map<String, dynamic>>[];
      } catch (_) {
        // Optional item photos must never hide claim details or custody actions.
        result['items'] = <Map<String, dynamic>>[];
      }
    }
    result['claim_card'] = claimCard;
    result['presentation'] = presentation;
    result['card_only'] = cardOnly;
    result['constituents'] ??= <Map<String, dynamic>>[];
    if (result['source_type'] == 'DIRECT_DONATION' &&
        result['donation_id'] == null &&
        (result['constituents'] as List).isNotEmpty) {
      result['donation_id'] =
          (result['constituents'] as List).first['donation_id'];
    }
    var auditRows = <Map<String, dynamic>>[];
    String? auditError;
    try {
      final audit = await _reader.rpc(
        'get_authorized_audit_events',
        params: {'p_entity_type': 'CLAIM', 'p_entity_id': widget.claimId},
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
    if (userId != _reader.identity) {
      throw StateError('Account changed. Refresh details.');
    }
    if (mounted && generation == _generation && presentation.isValidActive) {
      final delay =
          presentation.leaseExpiresAt!.difference(presentation.serverNow!) -
          elapsed.elapsed;
      _leaseRefresh?.cancel();
      _leaseRefresh = Timer(
        delay > Duration.zero ? delay : const Duration(seconds: 1),
        _refreshDetail,
      );
    }
    return result;
  }

  /// Opens the single reconciliation interface (v2 panel) for this claim and
  /// re-reads the claim when the NGO returns.
  Future<void> _openReconciliation({
    required String? title,
    required String? sourceType,
    required String? taskStatus,
  }) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ClaimReconciliationPage(
          claimId: widget.claimId,
          title: title ?? 'Handover reconciliation',
          viewerRole: 'NGO',
          sourceType: sourceType,
          routeNotice: taskStatus == 'DISPATCHED'
              ? 'While this pickup is unresolved, the next pickup on its route stays blocked.'
              : null,
          repository: widget.coordinationRepository,
        ),
      ),
    );
    if (mounted) _refreshDetail();
  }

  Widget _section(BuildContext context, String title, List<Widget> children) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) =>
      GeoRoleTheme(child: _buildRolePage(context));

  Widget _buildRolePage(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Claimed Pickup Details')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _detail,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(claimDetailsErrorMessage(snapshot.error!)),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _refreshDetail,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        final constituents = (data['constituents'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final claimItems = (data['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final claimGalleryPaths = DonationItemPhotoRules.legacyGalleryPaths({
          for (final donation in constituents) ...[
            if (donation['batch_cover_path'] is String)
              donation['batch_cover_path'] as String,
            if (donation['primary_image_path'] is String)
              donation['primary_image_path'] as String,
          ],
          for (final image in (data['donation_images'] as List? ?? const []))
            if (image['storage_path'] is String)
              image['storage_path'] as String,
        }, claimItems);
        final presentation = data['presentation'] as ClaimCard;
        final card = data['claim_card'] as Map<String, dynamic>;
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
        final claimedAt = card['claimed_at']?.toString();
        if (claimedAt != null && DateTime.tryParse(claimedAt) != null) {
          claimEvents.insert(
            0,
            StatusTimelineEvent(
              title: 'Claim created',
              occurredAt: DateTime.parse(claimedAt),
            ),
          );
        }
        final cardOnly = data['card_only'] == true;
        final claimStatus = data['claim_status']?.toString();
        final taskStatus = presentation.taskStatus;
        final title =
            presentation.title ?? data['title']?.toString() ?? 'Claimed pickup';
        final collectionMethod = collectionPathBadgeLabel(
          data['collection_path'] ?? card['collection_path'],
          listingSourceType: data['source_type'] ?? presentation.sourceType,
        );
        final weight =
            data['listing_weight_kg'] ?? presentation.listingWeightKg;
        final cover = presentation.primaryImagePath;
        final showHistoricalCover =
            cardOnly &&
            cover != null &&
            cover.isNotEmpty &&
            (presentation.displayStatus == ClaimDisplayStatus.collected ||
                presentation.displayStatus == ClaimDisplayStatus.completed);
        final isReconciliationRequired =
            !cardOnly && claimStatus == 'RECONCILIATION_REQUIRED';
        final privateDonorLocationAllowed =
            claimStatus == 'ACTIVE' && presentation.isValidActive;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            LayoutBuilder(
              builder: (context, constraints) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(title, style: geoTitleStyle(context))),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * .58,
                    ),
                    child: GeoStatusChip(
                      presentation.badge,
                      tone: switch (presentation.tab) {
                        ClaimTab.reconciliation => GeoTone.warning,
                        ClaimTab.history => GeoTone.neutral,
                        _ => null,
                      },
                    ),
                  ),
                ],
              ),
            ),
            if (collectionMethod != null || weight != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (collectionMethod != null)
                    _NgoListingMetric(collectionMethod),
                  if (weight != null) _NgoListingMetric('$weight kg'),
                ],
              ),
            ],
            const SizedBox(height: 12),
            if (presentation.displayStatus == ClaimDisplayStatus.expiredPending)
              const GeoNoticeCard(
                tone: GeoTone.warning,
                child: Text(
                  'The lease elapsed. The database still controls recovery.',
                ),
              ),
            if (presentation.displayStatus == ClaimDisplayStatus.needsReview)
              const GeoNoticeCard(
                tone: GeoTone.warning,
                child: Text(
                  'Refresh to verify this claim before attempting pickup.',
                ),
              ),
            if (isReconciliationRequired)
              GeoNoticeCard(
                key: const Key('claim-reconciliation-notice'),
                tone: GeoTone.warning,
                padding: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.warning_amber_rounded),
                        title: Text('Handover requires reconciliation'),
                        subtitle: Text(
                          'The listing stays unavailable while handover is unresolved. Review the case and submit your statement.',
                        ),
                      ),
                      if (taskStatus == 'DISPATCHED')
                        const Text(
                          'Pickup was dispatched. The next pickup on its route stays blocked until this is resolved.',
                        ),
                      const SizedBox(height: 6),
                      FilledButton.tonalIcon(
                        key: const Key('claim-detail-view-reconciliation'),
                        onPressed: () => _openReconciliation(
                          title: presentation.title,
                          sourceType: data['source_type']?.toString(),
                          taskStatus: taskStatus,
                        ),
                        icon: const Icon(Icons.fact_check_outlined),
                        label: const Text('View Reconciliation'),
                      ),
                    ],
                  ),
                ),
              ),
            _section(context, 'Claim summary', [
              _claimDetailRow('Claim ID', widget.claimId),
              _claimDetailRow(
                'Created',
                statusTimestampText(context, claimedAt),
              ),
              _claimDetailRow(
                'Lease expiry',
                statusTimestampText(
                  context,
                  data['lease_expires_at'] ?? card['lease_expires_at'],
                ),
              ),
              _claimDetailRow(
                'Pickup task',
                friendlyWorkflowStatus(taskStatus),
              ),
              if (presentation.releaseReason != null)
                _claimDetailRow('Release reason', presentation.releaseReason),
            ]),
            if (showHistoricalCover)
              _section(context, 'Donation photo', [
                _CollectedClaimCover(
                  key: ValueKey((_generation, cover)),
                  path: cover,
                  resolver: widget.photoUrlResolver,
                ),
              ]),
            if (!cardOnly) ...[
              _section(context, 'Pickup location', [
                if (data['source_type'] == 'DIRECT_DONATION' &&
                    !privateDonorLocationAllowed)
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.location_off_outlined),
                    title: Text('Private donor pickup location hidden'),
                    subtitle: Text(
                      'A valid active claim lease is required to view the donor address, coordinates, or navigation.',
                    ),
                  )
                else ...[
                  _claimDetailRow('Pickup address', data['pickup_address']),
                  if (data['latitude'] != null && data['longitude'] != null)
                    _claimDetailRow(
                      'Validated pickup coordinate',
                      '${data['latitude']}, ${data['longitude']}',
                    ),
                ],
              ]),
              _section(context, 'Donation photos and summary', [
                if (data['photo_error'] != null)
                  Text(data['photo_error'].toString()),
                // Item photos are shown beside their items, not again here.
                if (claimGalleryPaths != null)
                  DonationPhotoCarousel(
                    paths: claimGalleryPaths,
                    urlResolver: widget.photoUrlResolver,
                    showLoadErrors: true,
                    emptyMessage: data['photo_error'] == null
                        ? 'No donation photos available to your account'
                        : 'Donation photos could not be loaded',
                  ),
                if (claimItems.isNotEmpty) ...[
                  const Divider(),
                  Text('Items (${claimItems.length})'),
                  _DonationItemList(
                    items: claimItems,
                    donationTitles: {
                      for (final donation in constituents)
                        '${donation['donation_id']}': '${donation['title']}',
                    },
                    urlResolver: widget.photoUrlResolver,
                  ),
                ],
                if (data['source_type'] == 'HUB_BATCH') ...[
                  const Divider(),
                  const Text('Whole donations in this batch'),
                  for (final donation in constituents)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: _StoredImageThumbnail(
                        path: donation['primary_image_path']?.toString(),
                        urlResolver: widget.photoUrlResolver,
                      ),
                      title: Text(donation['title'].toString()),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${donation['total_weight_kg'] ?? donation['weight_kg'] ?? '—'} kg · ${friendlyWorkflowStatus(donation['donation_status'])}',
                          ),
                          if (privateDonorLocationAllowed)
                            if (_donationDescription(donation)
                                case final String text)
                              _DonationDescription(text),
                        ],
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
                ] else if (privateDonorLocationAllowed)
                  for (final donation in constituents)
                    if (_donationDescription(donation) case final String text)
                      _DonationDescription(text),
              ]),
            ],
            GeoStatusTimeline(
              title: 'Claim and Pickup History',
              events: claimEvents,
              errorMessage: data['audit_error']?.toString(),
              emptyMessage: 'No recorded claim or pickup events are available.',
            ),
          ],
        );
      },
    ),
  );
}

String? _donationDescription(Map<String, dynamic> donation) {
  final value = donation['donation_description'];
  return value is String && value.trim().isNotEmpty ? value : null;
}

class _DonationDescription extends StatelessWidget {
  const _DonationDescription(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Description', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(text),
      ],
    ),
  );
}

class _CollectedClaimCover extends StatefulWidget {
  const _CollectedClaimCover({super.key, required this.path, this.resolver});

  final String path;
  final Future<String> Function(String path)? resolver;

  @override
  State<_CollectedClaimCover> createState() => _CollectedClaimCoverState();
}

class _CollectedClaimCoverState extends State<_CollectedClaimCover> {
  late final Future<String> _url = Future.sync(
    () =>
        widget.resolver?.call(widget.path) ??
        createDonationPhotoSignedUrl(
          _db,
          widget.path,
          surface: 'Collected claim',
        ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _url,
    builder: (context, snapshot) {
      final url = snapshot.data;
      if (url == null || url.isEmpty) return const SizedBox.shrink();
      return Image.network(
        url,
        key: const Key('collected-claim-cover'),
        height: 160,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    },
  );
}

Widget _claimDetailRow(String label, Object? value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        flex: 2,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      const SizedBox(width: 12),
      Expanded(flex: 3, child: Text(value?.toString() ?? '—')),
    ],
  ),
);

class DonationItemInput {
  final name = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final weight = TextEditingController(text: '1');
  String? category;
  String condition = 'GOOD';

  /// The item's own photo (optional). At least one item needs one.
  DonationPhotoSelection? photo;

  String? nameError(String value) =>
      value.trim().isEmpty ? 'Enter item name' : null;
  String? quantityError(String value) => parseDonationQuantity(value) == null
      ? 'Enter a positive whole number'
      : null;
  String? categoryError(String? value, List<DonationCategory> choices) =>
      choices.any((choice) => choice.id == value) ? null : 'Select category';

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

/// The optional photo of one item in the Create Donation form.
class _ItemPhotoField extends StatelessWidget {
  final DonationPhotoSelection? photo;
  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  const _ItemPhotoField({
    required this.photo,
    required this.enabled,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final selected = photo;
    if (selected == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: enabled ? onPick : null,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('Add item photo'),
        ),
      );
    }
    return ListTile(
      key: ValueKey(selected.id),
      contentPadding: EdgeInsets.zero,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(selected.file.path),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
        ),
      ),
      title: const Text('Item photo'),
      subtitle: Text(selected.file.name),
      trailing: Wrap(
        children: [
          IconButton(
            tooltip: 'Replace item photo',
            onPressed: enabled ? onPick : null,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Remove item photo',
            onPressed: enabled ? onRemove : null,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class CreateDonationPage extends StatefulWidget {
  /// A cancelled donation (get_my_donation_detail; each item carries its
  /// 'photo_path' when it has its own photo) to copy into the form for
  /// "Donate again". The donor checks it and submits a new donation.
  final Map<String, dynamic>? copyFrom;
  final Future<List<DonationPhotoSelection>> Function(List<String>)?
  photoCopier;

  const CreateDonationPage({super.key, this.copyFrom, this.photoCopier});
  @override
  State<CreateDonationPage> createState() => _CreateDonationPageState();
}

class _CreateDonationPageState extends State<CreateDonationPage> {
  final title = TextEditingController();
  final description = TextEditingController();
  LocationResult? pickupLocation;
  final items = <DonationItemInput>[DonationItemInput()];
  late Future<List<DonationCategory>> categories = _loadCategories();
  bool busy = false;
  String progressMessage = '';
  String createRequestId = const Uuid().v4();
  bool copiedFromCancelled = false;
  bool copyingPhotos = false;

  /// Donate Again from a donation without item photos: its donation-level
  /// photos belong to no item, so the donor chooses item photos again.
  bool earlierPhotosNotCopied = false;

  @override
  void initState() {
    super.initState();
    final source = widget.copyFrom;
    if (source != null) _copyFrom(source);
  }

  /// Fills the form from a cancelled donation. The old donation stays cancelled;
  /// this always creates a new donation with a new request ID.
  void _copyFrom(Map<String, dynamic> source) {
    copiedFromCancelled = true;
    title.text = source['title']?.toString() ?? '';
    description.text = source['description']?.toString() ?? '';
    final lat = double.tryParse('${source['latitude']}');
    final lon = double.tryParse('${source['longitude']}');
    final address = source['pickup_address']?.toString() ?? '';
    if (lat != null && lon != null && address.isNotEmpty) {
      pickupLocation = LocationResult(
        address: address,
        latitude: lat,
        longitude: lon,
        method: LocationSelectionMethod.mapPin,
      );
    }
    final rows = (source['items'] as List? ?? const []).whereType<Map>();
    final photoCopies = <(DonationItemInput, String)>[];
    if (rows.isNotEmpty) {
      for (final item in items) {
        item.dispose();
      }
      items.clear();
      for (final row in rows) {
        final input = DonationItemInput();
        input.name.text = row['item_name']?.toString() ?? '';
        input.quantity.text = '${row['quantity'] ?? 1}';
        input.weight.text = row['unit_weight_kg']?.toString() ?? '';
        input.category = row['category_id']?.toString();
        final condition = row['item_condition']?.toString();
        if (const {'NEW', 'GOOD', 'FAIR'}.contains(condition)) {
          input.condition = condition!;
        }
        final photoPath = row['photo_path']?.toString().trim() ?? '';
        if (photoPath.isNotEmpty) photoCopies.add((input, photoPath));
        items.add(input);
      }
    }
    if (photoCopies.isNotEmpty) {
      copyingPhotos = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _copyItemPhotos(photoCopies);
      });
    } else {
      earlierPhotosNotCopied = true;
    }
  }

  /// Downloads each item photo of the cancelled donation to a temporary file,
  /// so it uploads as a new photo of the same item in the new donation.
  Future<void> _copyItemPhotos(List<(DonationItemInput, String)> copies) async {
    final copier = widget.photoCopier ?? _downloadCopiedPhotos;
    final copied = <(DonationItemInput, DonationPhotoSelection)>[];
    var failed = 0;
    for (final (item, path) in copies) {
      try {
        final result = await copier([path]);
        if (result.isEmpty) {
          failed++;
        } else {
          copied.add((item, result.first));
        }
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      copyingPhotos = false;
      for (final (item, photo) in copied) {
        if (items.contains(item) && item.photo == null) item.photo = photo;
      }
      _resetCreateRequest();
    });
    if (failed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$failed item photo${failed == 1 ? '' : 's'} could not be copied. '
            'Add ${failed == 1 ? 'it' : 'them'} again before submitting.',
          ),
        ),
      );
    }
  }

  Future<List<DonationPhotoSelection>> _downloadCopiedPhotos(
    List<String> paths,
  ) async {
    final storage = _db.storage.from('geolock-donation-images');
    final folder = await Directory.systemTemp.createTemp(
      'geolock_donate_again_',
    );
    final copied = <DonationPhotoSelection>[];
    for (final path in paths) {
      final ext = path.split('.').last.toLowerCase();
      if (!const {'jpg', 'jpeg', 'png', 'webp'}.contains(ext)) continue;
      try {
        final bytes = await storage.download(path);
        final id = const Uuid().v4();
        final file = File('${folder.path}/$id.$ext');
        await file.writeAsBytes(bytes, flush: true);
        copied.add(DonationPhotoSelection(id: id, file: XFile(file.path)));
      } catch (_) {
        // Report failures together while keeping the successfully copied photos.
      }
    }
    return copied;
  }

  /// Picks (or replaces) the one photo of [item], with the same type and size
  /// checks as before. Photos are resized before upload.
  Future<void> _pickItemPhoto(DonationItemInput item) async {
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
      if (!mounted || busy || !items.contains(item)) return;
      setState(() {
        item.photo = DonationPhotoSelection(
          id: const Uuid().v4(),
          file: picked,
        );
        _resetCreateRequest();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo could not be selected: $error')),
        );
      }
    }
  }

  void _removeItemPhoto(DonationItemInput item) => setState(() {
    item.photo = null;
    _resetCreateRequest();
  });

  void _resetCreateRequest() => createRequestId = const Uuid().v4();
  void _onInputChanged(String _) => setState(_resetCreateRequest);

  /// Uploads each item's photo to this request's private pending folder and
  /// returns its photo metadata, one entry per item in form order (null for
  /// an item without a photo). A retry with the same request ID skips photos
  /// that are already uploaded.
  Future<List<Map<String, dynamic>?>> _uploadItemPhotos() async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Your session has expired. Sign in again.');
    }
    final storage = _db.storage.from('geolock-donation-images');
    final folder = '$userId/pending/$createRequestId';
    final existing = await storage.list(path: folder);
    final existingNames = existing.map((object) => object.name).toSet();
    final total = items.where((item) => item.photo != null).length;
    final photoPayload = <Map<String, dynamic>?>[];
    var uploaded = 0;
    for (final item in items) {
      final selection = item.photo;
      if (selection == null) {
        photoPayload.add(null);
        continue;
      }
      final file = selection.file;
      final ext = file.path.split('.').last.toLowerCase();
      final mime = ext == 'png'
          ? 'image/png'
          : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
      final path = '$folder/${selection.id}.$ext';
      uploaded++;
      if (mounted) {
        setState(
          () => progressMessage = 'Uploading photo $uploaded of $total…',
        );
      }
      if (!existingNames.contains('${selection.id}.$ext')) {
        await storage.upload(
          path,
          File(file.path),
          fileOptions: FileOptions(contentType: mime, upsert: false),
        );
      }
      photoPayload.add({
        'storage_path': path,
        'content_type': mime,
        'size_bytes': await file.length(),
      });
    }
    return photoPayload;
  }

  void retryCategories() => setState(() => categories = _loadCategories());

  Future<List<DonationCategory>> _loadCategories() async {
    final response = await _db.rpc('get_active_donation_categories');
    if (response is! List) {
      throw const FormatException(
        'The categories RPC returned an invalid response.',
      );
    }
    final choices = response.map((row) {
      final map = Map<String, dynamic>.from(row as Map);
      return DonationCategory(
        map['category_id'].toString(),
        map['category_name'].toString(),
      );
    }).toList();
    if (mounted) {
      final activeIds = choices.map((choice) => choice.id).toSet();
      for (final item in items) {
        if (!activeIds.contains(item.category)) item.category = null;
      }
    }
    return choices;
  }

  static const _directPickupHint =
      'Choose a spot where a vehicle can stop (roadside, gate or lobby)';

  double? _validatedItemTotal(List<DonationCategory> choices) {
    if (items.any(
      (item) =>
          item.nameError(item.name.text) != null ||
          item.categoryError(item.category, choices) != null,
    )) {
      return null;
    }
    return donationTotalWeightKg(
      items.map(
        (item) => (
          quantity: parseDonationQuantity(item.quantity.text),
          unitWeightGrams: parseDonationUnitWeight(item.weight.text).grams,
        ),
      ),
    );
  }

  bool _canSubmit(double? itemTotal) {
    final location = pickupLocation;
    return !busy &&
        !copyingPhotos &&
        itemTotal != null &&
        DonationPhotoRules.titleError(title.text) == null &&
        DonationPhotoRules.descriptionError(description.text) == null &&
        DonationItemPhotoRules.validItemPhotos([
          for (final item in items) item.photo != null,
        ]) &&
        location != null &&
        location.address.trim().isNotEmpty &&
        location.roadAccess?.routable == true;
  }

  Future<void> selectPickupLocation(bool directPickupPreview) async {
    final selected = await Navigator.push<LocationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          title: 'Pickup location',
          initialLocation: pickupLocation,
          roadAccess: RoadAccessRequirement.required,
          hint: directPickupPreview ? _directPickupHint : null,
        ),
      ),
    );
    if (selected != null && mounted && !busy) {
      setState(() {
        pickupLocation = selected;
        _resetCreateRequest();
      });
    }
  }

  Future<void> submit(List<DonationCategory> choices) async {
    if (!_canSubmit(_validatedItemTotal(choices))) return;
    final payload = <Map<String, dynamic>>[];
    for (final item in items) {
      payload.add({
        'category_id': item.category,
        'item_name': item.name.text.trim(),
        'quantity': parseDonationQuantity(item.quantity.text)!,
        'unit_weight_kg':
            parseDonationUnitWeight(item.weight.text).grams! / 1000,
        'item_condition': item.condition,
      });
    }
    setState(() {
      busy = true;
      progressMessage = 'Preparing photo uploads…';
    });
    try {
      final photoPayload = await _uploadItemPhotos();
      for (var index = 0; index < payload.length; index++) {
        final photo = photoPayload[index];
        if (photo != null) payload[index]['photo'] = photo;
      }
      if (mounted) {
        setState(() => progressMessage = 'Saving donation securely…');
      }
      final id = await _db.rpc(
        'create_donation_with_item_photos',
        params: DonationItemPhotoRules.createRpcPayload(
          requestId: createRequestId,
          title: title.text,
          description: description.text,
          pickupAddress: pickupLocation!.address,
          latitude: pickupLocation!.latitude,
          longitude: pickupLocation!.longitude,
          // Never send a client node: trg_donation_road_node snaps the stored
          // pickup point to the nearest drivable road node in the database.
          pickupRoadNodeId: null,
          // Items keep their form order; positions 1..n come from it.
          items: payload,
        ),
      );
      final donationId = id?.toString().trim() ?? '';
      if (donationId.isEmpty) {
        throw const FormatException('The database did not return a donation.');
      }
      if (mounted) {
        setState(() => progressMessage = 'Reading the saved donation…');
      }
      // Show only committed state: re-read the donation the RPC just created.
      Map<String, dynamic>? detail;
      try {
        final response = await _db.rpc(
          'get_my_donation_detail',
          params: {'p_donation': donationId},
        );
        if (response is Map) detail = Map<String, dynamic>.from(response);
      } catch (_) {
        detail = null;
      }
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (detail == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Donation saved (id $donationId). Open My Donations to see its status.',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
        navigator.pop();
        return;
      }
      final committed = detail;
      final chooseHub = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DonationResultDialog(detail: committed),
      );
      if (!mounted) return;
      if (chooseHub == true) {
        navigator.pushReplacement(
          MaterialPageRoute(
            builder: (_) => DonationDetailPage(
              donationId: donationId,
              openHubSelection: true,
            ),
          ),
        );
      } else {
        navigator.pop();
      }
    } catch (e) {
      if (e is PostgrestException &&
          donationServerErrorCode(e) ==
              'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD') {
        _resetCreateRequest();
      }
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
  Widget build(BuildContext context) =>
      GeoRoleTheme(child: _buildRolePage(context));

  Widget _buildRolePage(BuildContext context) => Scaffold(
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
        final total = _validatedItemTotal(choices);
        final directPickupPreview =
            total != null && previewCollectionPath(total) == 'DIRECT_PICKUP';
        return Form(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (copiedFromCancelled)
                Card(
                  color: const Color(0xffe4f2ed),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      copyingPhotos
                          ? 'Copied from your cancelled donation. Copying item photos…'
                          : earlierPhotosNotCopied
                          ? 'Copied from your cancelled donation. Its photos are not '
                                'copied: add a photo to at least one item. Confirm the '
                                'pickup location again, check the items, then submit. '
                                'This creates a new donation; you choose a hub and day '
                                'after it is saved.'
                          : 'Copied from your cancelled donation. Confirm the pickup '
                                'location again, check the items and their photos, then '
                                'submit. This creates a new donation; you choose a hub '
                                'and day after it is saved.',
                    ),
                  ),
                ),
              TextFormField(
                controller: title,
                readOnly: busy,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'Donation title'),
                validator: (v) => DonationPhotoRules.titleError(v ?? ''),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                onChanged: _onInputChanged,
              ),
              TextFormField(
                controller: description,
                readOnly: busy,
                maxLength: 1000,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Description'),
                validator: (v) => DonationPhotoRules.descriptionError(v ?? ''),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                onChanged: _onInputChanged,
              ),
              const SizedBox(height: 10),
              Text(
                'Pickup location',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (directPickupPreview)
                Text(
                  _directPickupHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => selectPickupLocation(directPickupPreview),
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
                if (pickupLocation!.roadAccess != null)
                  Text(
                    'Road access: ${pickupLocation!.roadAccess!.summary}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              const SizedBox(height: 12),
              const Divider(),
              Text('Items', style: Theme.of(context).textTheme.titleSmall),
              Text(
                'Each item can have one photo. Add a photo to at least one '
                'item; the first photographed item is the donation cover. '
                'Photos are resized before upload.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!copyingPhotos && !items.any((item) => item.photo != null))
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('At least one item photo is required.'),
                ),
              ...items.asMap().entries.map((entry) {
                final i = entry.key;
                final item = entry.value;
                return Card(
                  key: ObjectKey(item),
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
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          validator: (v) => item.categoryError(v, choices),
                        ),
                        TextFormField(
                          controller: item.name,
                          readOnly: busy,
                          decoration: const InputDecoration(
                            labelText: 'Item name',
                          ),
                          onChanged: _onInputChanged,
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          validator: (v) => item.nameError(v ?? ''),
                        ),
                        TextFormField(
                          controller: item.quantity,
                          readOnly: busy,
                          keyboardType: TextInputType.number,
                          onChanged: _onInputChanged,
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          validator: (v) => item.quantityError(v ?? ''),
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
                          onChanged: _onInputChanged,
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          validator: (v) =>
                              parseDonationUnitWeight(v ?? '').error,
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
                        const SizedBox(height: 8),
                        _ItemPhotoField(
                          photo: item.photo,
                          enabled: !busy && !copyingPhotos,
                          onPick: () => _pickItemPhoto(item),
                          onRemove: () => _removeItemPhoto(item),
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
              CollectionPathPreviewCard(totalKg: total),
              const SizedBox(height: 16),
              if (busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(progressMessage, textAlign: TextAlign.center),
              ],
              FilledButton(
                onPressed: _canSubmit(total) ? () => submit(choices) : null,
                child: Text(busy ? 'Saving...' : 'Submit Donation'),
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
                  '${collectionPathLabel(d['collection_path']?.toString())} • ${donationStatusLabel(status: d['donation_status']?.toString(), collectionPath: d['collection_path']?.toString())} • ${d['total_weight_kg'] ?? '—'} kg${d['listing_routing_status'] == null ? '' : ' • route node ${d['listing_routing_status']}'}',
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

class CollectionPathPreviewCard extends StatelessWidget {
  final double? totalKg;
  const CollectionPathPreviewCard({super.key, required this.totalKg});

  @override
  Widget build(BuildContext context) {
    final total = totalKg;
    final direct =
        total != null && previewCollectionPath(total) == 'DIRECT_PICKUP';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ListTile(
        leading: Icon(
          direct ? Icons.local_shipping_outlined : Icons.store_outlined,
        ),
        title: Text(
          total == null || total <= 0
              ? 'Complete every item to preview the collection path'
              : collectionPathPreviewText(total),
        ),
        subtitle: Text(
          'Preview: ${donationDirectMinKgPreview.toStringAsFixed(0)} kg or more '
          'is collected directly. The server confirms the path when you submit.',
        ),
      ),
    );
  }
}

/// Result of a committed donation, built only from get_my_donation_detail.
/// Pops `true` when the donor chooses to reserve a community hub.
class DonationResultDialog extends StatelessWidget {
  final Map<String, dynamic> detail;
  const DonationResultDialog({super.key, required this.detail});

  @override
  Widget build(BuildContext context) {
    final status = detail['donation_status']?.toString();
    final path = detail['collection_path']?.toString();
    final road = detail['road_node_status']?.toString();
    final hub = path == 'HUB_COLLECTION';
    return AlertDialog(
      title: const Text('Donation submitted'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _detailLine(
            'Status',
            donationStatusLabel(status: status, collectionPath: path),
          ),
          _detailLine('Collection path', collectionPathLabel(path)),
          if (detail['total_weight_kg'] != null)
            _detailLine('Total weight', '${detail['total_weight_kg']} kg'),
          _detailLine('Road status', routingStatusExplanation(road)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(hub ? 'Later' : 'Done'),
        ),
        if (hub)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Choose a community hub'),
          ),
      ],
    );
  }

  Widget _detailLine(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: value),
        ],
      ),
    ),
  );
}

class DonationDetailPage extends StatefulWidget {
  final String donationId;
  final Future<Map<String, dynamic>> Function()? detailLoader;
  final RouteResolutionRepository? outcomeRepository;

  /// Reconciliation reads for the status link / reconciliation page.
  /// Defaults to the live participant-scoped repository; injected by tests.
  final ClaimCoordinationRepository? coordinationRepository;

  /// Opens the hub chooser once the page appears (after a new hub donation).
  final bool openHubSelection;
  const DonationDetailPage({
    super.key,
    required this.donationId,
    this.openHubSelection = false,
    this.detailLoader,
    this.outcomeRepository,
    this.coordinationRepository,
  });
  @override
  State<DonationDetailPage> createState() => _DonationDetailPageState();
}

class _DonationDetailPageState extends State<DonationDetailPage> {
  late Future<Map<String, dynamic>> _detail = _load();
  bool _busy = false;
  String _cancelRequestId = const Uuid().v4();

  Future<void> _refreshAfterConfirmedDonationAction() async {
    final next = _load();
    if (mounted) {
      setState(() {
        _detail = next;
      });
    }
    await next;
  }

  @override
  void initState() {
    super.initState();
    if (widget.openHubSelection) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reserveHub();
      });
    }
  }

  Future<Map<String, dynamic>> _load() async {
    if (widget.detailLoader != null) return widget.detailLoader!();
    final response = await _db.rpc(
      'get_my_donation_detail',
      params: {'p_donation': widget.donationId},
    );
    if (response is! Map) {
      throw StateError('Donation not found or you do not have access to it.');
    }
    final detail = Map<String, dynamic>.from(response);
    // Hub bookings: read the booked day and the hub's opening hours, so the app can
    // close cancelling while the hub is open on the drop-off day.
    if (detail['status'] == 'HUB_ASSIGNED') {
      try {
        detail['hub_pass'] = await hub.HubService.dropOffPass(
          widget.donationId,
        );
      } catch (_) {
        // The page stays usable; cancel_donation still checks custody and state.
      }
    }
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
    // Each item's own photo, matched to the items above. Donations made before
    // item photos have none; a failed read keeps the items without photos.
    try {
      final itemRows = await _db.rpc(
        'get_my_donation_items',
        params: {'p_donation': widget.donationId},
      );
      if (itemRows is List) {
        detail['items'] = DonationItemPhotoRules.attachPhotos(
          (detail['items'] as List? ?? const []).whereType<Map>(),
          itemRows.whereType<Map>(),
        );
      }
    } catch (error) {
      _photoDebug(
        'DonationDetailPage get_my_donation_items failed: '
        '${_safePhotoDiagnostic(error)}',
      );
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
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final booked = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => HubChoosePage(donationId: widget.donationId),
        ),
      );

      if (!mounted) return;

      if (booked == true) {
        setState(() => _detail = _load());
      }
    } catch (error) {
      if (!mounted) return;

      setState(() => _detail = _load());

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to open hub selection: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A cancelled donation cannot come back. "Donate again" opens a new donation
  /// form filled with the same items, photos and pickup location.
  Future<void> _donateAgain(Map<String, dynamic> donation) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => CreateDonationPage(copyFrom: donation)),
    );
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
    // Check the drop-off window again just before cancelling: the hub may have
    // opened since this page was loaded.
    try {
      final pass = await hub.HubService.dropOffPass(widget.donationId);
      if (pass.reservation?.dropOffWindowOpen == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Your drop-off day has started, so the donation cannot be '
                'cancelled now. You can cancel or choose again after the '
                'booking expires.',
              ),
            ),
          );
          setState(() => _detail = _load());
        }
        return;
      }
    } catch (_) {
      // Not a hub booking, or the read failed: cancel_donation still decides.
    }
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
  Widget build(BuildContext context) =>
      GeoRoleTheme(child: _buildRolePage(context));

  Widget _buildRolePage(BuildContext context) => Scaffold(
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
        final description = d['description'];
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
        final pathLabel = collectionPathBadgeLabel(d['collection_path']);
        final auditEvents = (d['audit_events'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final donationEvents = recordedAuditEvents(
          auditEvents,
          allowedEventTypes: const {
            'CREATE_VALIDATE',
            'CREATE_DONATION',
            'DONATION_STATUS_CHANGED',
            'DONATION_STATUS_BACKFILL',
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
        final hubPass = d['hub_pass'] as hub.HubDropOffPass?;
        final dropOffWindowOpen =
            hubPass?.reservation?.dropOffWindowOpen ?? false;
        final cancellable =
            !dropOffWindowOpen &&
            !hasReceipt &&
            !hasInventory &&
            // SUBMITTED may carry old bookings that expired or were released
            // (an expired booking returns the donation to SUBMITTED).
            ((d['status'] == 'SUBMITTED' &&
                    reservations.every(
                      (reservation) =>
                          reservation['status'] == 'EXPIRED' ||
                          reservation['status'] == 'RELEASED',
                    )) ||
                (d['status'] == 'AVAILABLE' &&
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
            ? 'Awaiting hub selection · last booking expired'
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
        // Item photos are shown beside their items, not again in the gallery.
        final galleryPaths = DonationItemPhotoRules.legacyGalleryPaths(
          photos,
          items,
        );

        return Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      if (galleryPaths != null) ...[
                        DonationPhotoCarousel(paths: galleryPaths),
                        const SizedBox(height: 20),
                      ],
                      Text(
                        d['title']?.toString() ?? 'Donation',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (description is String &&
                          description.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Donation description',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          description,
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
                          if (pathLabel != null)
                            _DonorInfoChip(
                              icon: pathLabel == 'Hub Collection'
                                  ? Icons.storefront_outlined
                                  : Icons.local_shipping_outlined,
                              label: pathLabel,
                            ),
                        ],
                      ),
                      if (d['collection_path'] == 'DIRECT_PICKUP')
                        if (widget.outcomeRepository != null)
                          DonorPickupOutcomeNotice(
                            donationId: widget.donationId,
                            repository: widget.outcomeRepository,
                            onConfirmed: _refreshAfterConfirmedDonationAction,
                          )
                        else
                          // Status + link only; statements are submitted in
                          // the single reconciliation interface.
                          ReconciliationLink(
                            donationId: widget.donationId,
                            viewerRole: 'DONOR',
                            sourceType: 'DIRECT_DONATION',
                            repository: widget.coordinationRepository,
                            onReturn: _refreshAfterConfirmedDonationAction,
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
                        const SizedBox(height: 14),
                        HubDropOffCard(
                          key: ObjectKey(_detail),
                          donationId: widget.donationId,
                          onChanged: () {
                            if (mounted) {
                              setState(() => _detail = _load());
                            }
                          },
                        ),
                      ],
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
            if (dropOffWindowOpen)
              _DropOffWindowNotice(reopensAt: hubPass?.reservation?.expiresAt),
            if (needsHub || cancellable)
              _DonorDetailActions(
                isBusy: _busy,
                needsHub: needsHub,
                canCancel: cancellable,
                onChooseHub: _reserveHub,
                onCancel: _cancel,
              ),
            if (d['status'] == 'CANCELLED')
              _DonateAgainAction(onPressed: () => _donateAgain(d)),
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

/// All evidence targets come from the donor-scoped protected reader.
class DonorPickupOutcomeNotice extends StatefulWidget {
  const DonorPickupOutcomeNotice({
    super.key,
    this.donationId,
    this.repository,
    this.onConfirmed,
  });
  final String? donationId;
  final RouteResolutionRepository? repository;

  /// Runs only after the protected reconciliation RPC returns a receipt.
  /// The parent reloads the donation through its protected detail reader.
  final Future<void> Function()? onConfirmed;
  @override
  State<DonorPickupOutcomeNotice> createState() =>
      _DonorPickupOutcomeNoticeState();
}

class _DonorPickupOutcomeNoticeState extends State<DonorPickupOutcomeNotice> {
  RouteResolutionRepository? _repo;
  late Future<Map<String, dynamic>> _value = _load();
  bool _claimSending = false;
  bool _claimConfirming = false;
  String? _claimError;
  String? _claimNotice;

  @override
  void didUpdateWidget(covariant DonorPickupOutcomeNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.donationId != widget.donationId ||
        oldWidget.repository != widget.repository) {
      _repo = widget.repository;
      _value = _load();
    }
  }

  Future<Map<String, dynamic>> _load() async {
    if (widget.donationId == null) {
      return {'enabled': false, 'contexts': <dynamic>[]};
    }
    final repo = _repo ??=
        widget.repository ?? RouteResolutionRepository.live();
    final viewer = repo.identity;
    final value = await repo.donorContext(widget.donationId!);
    final active = actionableDonorContext(value);
    final pending =
        active != null &&
        (await repo.pending(active['route_id'] as String)).isNotEmpty;
    Map<String, dynamic>? claimContext;
    Map<String, dynamic>? savedClaim;
    Object? claimReadError;
    try {
      claimContext = await repo.donorClaimContext(widget.donationId!);
      savedClaim = await repo.reconcileDonorClaimRequest(widget.donationId!);
    } catch (error) {
      claimReadError = error;
    }
    if (repo.identity != viewer) throw StateError('Account changed.');
    return {
      ...value,
      'pending': pending,
      'viewer': viewer,
      'claim_context': claimContext,
      'saved_claim': savedClaim,
      'claim_read_error': claimReadError,
    };
  }

  Future<void> _submitClaim(Map<String, dynamic> row, String assertion) async {
    final repo = _repo;
    final donation = widget.donationId;
    if (repo == null || donation == null || _claimSending || _claimConfirming) {
      return;
    }
    setState(() {
      _claimConfirming = true;
      _claimError = null;
      _claimNotice = null;
    });
    final label = assertion == 'COLLECTED'
        ? 'Collected — Goods were handed over to the NGO.'
        : 'Not Collected — Goods remain with you.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm your statement'),
        content: Text('For ${row['title'] ?? 'this donation'}: $label'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Submit statement'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _claimConfirming = false);
    if (confirmed != true) return;
    setState(() {
      _claimSending = true;
      _claimError = null;
    });
    try {
      final result = await repo.submitDonorClaimReconciliation(
        donation,
        row,
        assertion,
      );
      await widget.onConfirmed?.call();
      if (mounted) {
        final message =
            'Statement recorded: ${result['outcome'] ?? 'awaiting counterpart'}'
            '${result['reason_code'] is String ? ' — ${result['reason_code']}' : ''}.';
        setState(() => _claimNotice = message);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (error) {
      if (mounted) setState(() => _claimError = resolutionError(error));
    } finally {
      if (mounted) {
        _refresh();
        setState(() => _claimSending = false);
      }
    }
  }

  Future<void> _retryClaim(Map<String, dynamic> saved) async {
    final repo = _repo;
    final donation = widget.donationId;
    final request = saved['request'];
    if (repo == null ||
        donation == null ||
        request is! Map ||
        _claimSending ||
        _claimConfirming) {
      return;
    }
    setState(() {
      _claimSending = true;
      _claimError = null;
      _claimNotice = null;
    });
    try {
      final row = actionableDonorClaimContext(
        await repo.donorClaimContext(donation),
      );
      if (row == null) {
        final receipt = await repo.reconcileDonorClaimRequest(donation);
        if (receipt?['found'] != true) {
          throw StateError(
            'The saved statement is not currently actionable. Request authorized review.',
          );
        }
      } else {
        final result = await repo.submitDonorClaimReconciliation(
          donation,
          row,
          request['handover_confirmed'] == true ? 'COLLECTED' : 'NOT_COLLECTED',
        );
        await widget.onConfirmed?.call();
        if (mounted) {
          final message =
              'Saved statement confirmed: ${result['outcome'] ?? 'recorded'}.';
          setState(() => _claimNotice = message);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      }
    } catch (error) {
      if (mounted) setState(() => _claimError = resolutionError(error));
    } finally {
      if (mounted) {
        _refresh();
        setState(() => _claimSending = false);
      }
    }
  }

  Future<void> _open(Map<String, dynamic> binding, String viewer) async {
    if (_repo?.identity != viewer) {
      _refresh();
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RouteResolutionPage(
          routeId: binding['route_id'] as String,
          donorDonationId: widget.donationId!,
          repository: _repo,
        ),
      ),
    );
    if (mounted) _refresh();
  }

  void _refresh() {
    final next = _load();
    setState(() {
      _value = next;
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: _value,
    builder: (context, snapshot) {
      final value = snapshot.data;
      final active =
          value == null ||
              snapshot.connectionState != ConnectionState.done ||
              snapshot.hasError
          ? null
          : actionableDonorContext(value);
      final claimContext = value?['claim_context'] is Map
          ? routingObject(value!['claim_context'])
          : null;
      final claimRows = routingRows(claimContext?['contexts'] ?? []);
      final claimHistory = donorClaimHistory(claimContext?['contexts']);
      final claimAction = claimContext == null
          ? null
          : actionableDonorClaimContext(claimContext);
      final savedClaim = value?['saved_claim'] is Map
          ? routingObject(value!['saved_claim'])
          : null;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Pickup outcome confirmation'),
              if (_claimNotice != null)
                Semantics(liveRegion: true, child: Text(_claimNotice!)),
              if (claimAction != null) ...[
                const Divider(),
                const Text('Donation-level reconciliation'),
                Text(
                  'Donation: ${claimAction['title'] ?? value?['title'] ?? 'Donation'}',
                ),
                const Text('Confirm what happened to these goods:'),
                FilledButton.tonal(
                  onPressed: _claimSending || _claimConfirming
                      ? null
                      : () => _submitClaim(claimAction, 'COLLECTED'),
                  child: const Text('Collected — Goods handed over to the NGO'),
                ),
                OutlinedButton(
                  onPressed: _claimSending || _claimConfirming
                      ? null
                      : () => _submitClaim(claimAction, 'NOT_COLLECTED'),
                  child: const Text('Not Collected — Goods remain with you'),
                ),
                if (_claimSending) const LinearProgressIndicator(),
              ],
              if (claimContext?['status'] == 'WAITING_FOR_EXPIRY_RECOVERY' ||
                  claimRows.any(
                    (row) =>
                        row['blocker'] == 'WAITING_FOR_EXPIRY_RECOVERY' ||
                        row['blocking_reason'] == 'WAITING_FOR_EXPIRY_RECOVERY',
                  ))
                const Text(
                  'This expired claim is waiting for the protected backend expiry recovery process. No custody statement can be submitted until recovery opens an individual reconciliation case.',
                ),
              if (claimRows.any(
                (row) =>
                    row['case_status'] == 'MANUAL_REVIEW' ||
                    row['blocking_reason'] == 'MANUAL_REVIEW',
              ))
                const Text(
                  'This donation is under manual review. Submit no replacement statement; an authorized reviewer must resolve it.',
                ),
              if (claimHistory.isNotEmpty) ...[
                const Divider(),
                if (claimContext?['history_truncated'] == true)
                  const Text(
                    'The backend returned a truncated claim history. Not all previous claims may be shown.',
                  ),
                if (claimContext?['association_conflict'] == true)
                  const Text(
                    'The backend reported conflicting donation-to-claim associations. Review is required before relying on this history.',
                  ),
                Text(
                  'Latest claim outcome',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                _DonorClaimHistoryCard(entry: claimHistory.first),
                if (claimHistory.length > 1)
                  ExpansionTile(
                    key: const Key('donor-claim-history'),
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      'Claim History (${claimHistory.length - 1} previous)',
                    ),
                    children: [
                      for (final entry in claimHistory.skip(1))
                        _DonorClaimHistoryCard(entry: entry),
                    ],
                  ),
              ],
              if (value?['claim_read_error'] != null)
                const Text(
                  'Donation-specific reconciliation could not be read. Refresh before submitting.',
                ),
              if (savedClaim?['found'] == false)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'A saved donor statement has no committed receipt yet. Retry submits only that same statement with its original request ID.',
                    ),
                    OutlinedButton(
                      onPressed: _claimSending
                          ? null
                          : () => _retryClaim(savedClaim!),
                      child: const Text('Retry saved statement'),
                    ),
                  ],
                ),
              if (savedClaim?['found'] == true)
                Text(
                  'Saved statement confirmed: ${savedClaim!['result']?['outcome'] ?? 'recorded'}.',
                ),
              if (_claimError != null) Text(_claimError!),
              if (claimAction == null &&
                  claimContext != null &&
                  claimRows.isEmpty &&
                  claimContext['status'] != 'WAITING_FOR_EXPIRY_RECOVERY')
                const Text(
                  'No uniquely actionable donor-owned claim reconciliation is available for this donation.',
                ),
              if (snapshot.connectionState == ConnectionState.waiting)
                const LinearProgressIndicator(),
              if (snapshot.hasError) Text(resolutionError(snapshot.error!)),
              const Text(
                'Lease expiry alone does not establish whether goods were handed over. Custody statements are recorded against the individual claim.',
              ),
              if (active != null) ...[
                const Text('Legacy route case'),
                OutlinedButton(
                  onPressed: value?['pending'] != true
                      ? () => _open(active, value!['viewer'] as String)
                      : null,
                  child: const Text('Open legacy route case'),
                ),
              ],
              if (value?['enabled'] == false)
                const Text(
                  'Reconciliation reporting is disabled or unavailable. Existing holds remain protected.',
                ),
              if (value?['history_truncated'] == true ||
                  value?['association_conflict'] == true)
                const Text(
                  'History requires authorized review. No submission is permitted.',
                ),
              if (value?['pending'] == true)
                const Text(
                  'An earlier submission needs receipt reconciliation. No replacement statement will be sent.',
                ),
              if (active != null && value?['pending'] == true)
                TextButton(
                  onPressed: () => _open(active, value!['viewer'] as String),
                  child: const Text('Review saved submission (read only)'),
                ),
              for (final row
                  in (value?['contexts'] as List? ?? const [])
                      .cast<Map<String, dynamic>>()
                      .where((row) => row['case_id'] is String)) ...[
                Text(
                  'Resolution: ${row['resolution_status'] ?? 'Awaiting NGO interruption report'}',
                ),
                Text(
                  'My statement: ${custodyLabel((row['donor_evidence'] as Map?)?['assertion'])}',
                ),
                Text(
                  'NGO statement: ${custodyLabel((row['ngo_evidence'] as Map?)?['assertion'])}',
                ),
                Text(
                  'Claim reconciliation outcome: ${row['claim_reconciliation_status'] ?? 'Not recorded'}',
                ),
                if (row['disposition'] != null)
                  Text('Recorded disposition: ${row['disposition']}'),
                if (row['blocking_reason'] != null)
                  Text('Submission status: ${row['blocking_reason']}'),
              ],
              const Text(
                'Collected: the NGO received the goods from you. Not Collected: the goods remain with you. No answer is preselected. If neither is accurate, do not submit; request authorized review.',
              ),
              TextButton(
                onPressed: _refresh,
                child: const Text('Refresh pickup outcome'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _DonorClaimHistoryCard extends StatelessWidget {
  const _DonorClaimHistoryCard({required this.entry});

  final DonorClaimHistoryEntry entry;

  bool _contradicts(Map<String, dynamic> row) {
    final donor = (row['donor_evidence'] as Map?)?['handover_confirmed'];
    final ngo = (row['ngo_evidence'] as Map?)?['handover_confirmed'];
    return donor is bool && ngo is bool && donor != ngo;
  }

  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey('claim-history-${entry.claimId}'),
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Claim outcome: ${donorClaimOutcomeLabel(entry.outcome)}'),
          if (entry.occurredAt != null)
            Text('Updated: ${entry.occurredAt!.toUtc().toIso8601String()}'),
          if (entry.hasConflictingRows)
            const Text(
              'Conflicting records were returned for this claim. Review is required; all distinct statements are shown below.',
            ),
          for (final row in entry.contexts) ...[
            if (row['case_status'] == 'OPEN')
              const Text(
                'Reconciliation is unresolved. Do not infer a final handover outcome.',
              ),
            if (row['case_status'] == 'MANUAL_REVIEW' ||
                row['blocking_reason'] == 'MANUAL_REVIEW')
              const Text(
                'This claim is under manual review. An authorized reviewer must resolve it.',
              ),
            if (row['blocking_reason'] == 'DONOR_EVIDENCE_ALREADY_RECORDED')
              const Text(
                'Your statement is already recorded for this claim. The NGO still needs to submit its own statement; do not submit another donor statement.',
              ),
            if (_contradicts(row))
              const Text(
                'The donor and NGO statements conflict. This claim remains visible for authorized review.',
              ),
            Text(
              'Your statement: ${donorCustodyEvidenceLabel((row['donor_evidence'] as Map?)?['handover_confirmed'])}',
            ),
            Text(
              'NGO statement: ${donorCustodyEvidenceLabel((row['ngo_evidence'] as Map?)?['handover_confirmed'])}',
            ),
          ],
        ],
      ),
    ),
  );
}

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
    final condition = _itemConditionLabel(item['item_condition']);
    return Column(
      children: [
        if (!isLast) const Divider(height: 1, color: Color(0xffedf1ee)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (DonationItemPhotoRules.photoPath(item) case final String path)
                _ItemPhotoThumbnail(path: path)
              else
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

String? _itemConditionLabel(Object? value) => switch (value?.toString()) {
  'NEW' => 'New',
  'GOOD' => 'Good condition',
  'FAIR' => 'Fair condition',
  'POOR' => 'Needs repair',
  final text? => text.replaceAll('_', ' ').toLowerCase(),
  _ => null,
};

/// An item's own photo beside the item; tap to view it larger.
class _ItemPhotoThumbnail extends StatelessWidget {
  final String path;
  final Future<String> Function(String path)? urlResolver;
  const _ItemPhotoThumbnail({required this.path, this.urlResolver});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'View item photo',
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Item photo')),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: DonationPhotoCarousel(
                paths: [path],
                urlResolver: urlResolver,
              ),
            ),
          ),
        ),
      ),
      child: _StoredImageThumbnail(path: path, urlResolver: urlResolver),
    ),
  );
}

/// Authorized items with their own photos, for NGO listing and claim details:
/// name, category, quantity, condition and photo. The NGO item readers return
/// no donor identity and no item description.
class _DonationItemList extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final Map<String, String> donationTitles;
  final Future<String> Function(String path)? urlResolver;
  const _DonationItemList({
    required this.items,
    this.donationTitles = const {},
    this.urlResolver,
  });

  @override
  Widget build(BuildContext context) {
    final donationIds = <String>[
      ...{for (final item in items) '${item['donation_id']}'},
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final donationId in donationIds) ...[
          if (donationIds.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                donationTitles[donationId] ?? 'Donation',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          for (final item in items)
            if ('${item['donation_id']}' == donationId)
              ListTile(
                key: ValueKey('donation-item-${item['item_id']}'),
                contentPadding: EdgeInsets.zero,
                leading: switch (DonationItemPhotoRules.photoPath(item)) {
                  final String path => _ItemPhotoThumbnail(
                    path: path,
                    urlResolver: urlResolver,
                  ),
                  _ => const _StoredImageThumbnail(),
                },
                title: Text(item['item_name']?.toString() ?? 'Donation item'),
                subtitle: Text(
                  [
                    item['category_name']?.toString() ?? 'Item',
                    'Qty ${item['quantity'] ?? '—'}',
                    if (_itemConditionLabel(item['item_condition'])
                        case final String condition)
                      condition,
                  ].join(' · '),
                ),
              ),
        ],
      ],
    );
  }
}

class _DonateAgainAction extends StatelessWidget {
  final VoidCallback onPressed;

  const _DonateAgainAction({required this.onPressed});

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
              const Text(
                'This donation is cancelled and cannot be booked again. To give '
                'these items, start a new donation with the same details.',
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onPressed,
                  icon: const Icon(Icons.replay),
                  label: const Text('Donate again'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Shown instead of the cancel button while the hub is open on the drop-off day.
class _DropOffWindowNotice extends StatelessWidget {
  final DateTime? reopensAt;

  const _DropOffWindowNotice({required this.reopensAt});

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xffe2ebe6))),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_clock_outlined, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Your drop-off day has started, so this donation cannot be '
                  'cancelled in the app right now. Your items may already be with '
                  'the hub before the staff record them. If you are not coming, '
                  'you can cancel or choose again after the booking expires'
                  '${reopensAt == null ? '' : ' at ${hub.hubCloseLabel(reopensAt)}'}.',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
  final Future<String> Function(String path)? urlResolver;
  const _StoredImageThumbnail({this.path, this.urlResolver});

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
      future:
          urlResolver?.call(path!) ??
          _db.storage
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
  final bool showLoadErrors;
  final String emptyMessage;
  const DonationPhotoCarousel({
    super.key,
    required this.paths,
    this.urlResolver,
    this.showLoadErrors = false,
    this.emptyMessage = 'No donation photos',
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
          allowedEventTypes: const {
            'CONFIRM_HUB_RECEIPT',
            'CANCEL_DONATION',
            'DONATION_STATUS_CHANGED',
            'DONATION_STATUS_BACKFILL',
          },
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
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.volunteer_activism_outlined, size: 42),
              const SizedBox(height: 8),
              Text(widget.emptyMessage),
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
                    if (snapshot.hasError) {
                      return _photoPlaceholder(
                        widget.showLoadErrors
                            ? _claimPhotoReadError(snapshot.error!)
                            : null,
                      );
                    }
                    if (!snapshot.hasData) {
                      return widget.showLoadErrors
                          ? const Center(child: CircularProgressIndicator())
                          : _photoPlaceholder();
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
                          return _photoPlaceholder(
                            widget.showLoadErrors
                                ? _claimPhotoReadError(error)
                                : null,
                          );
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

  Widget _photoPlaceholder([String? message]) => Container(
    color: const Color(0xffe4f2ed),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_not_supported_outlined, size: 42),
          if (message != null) Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
