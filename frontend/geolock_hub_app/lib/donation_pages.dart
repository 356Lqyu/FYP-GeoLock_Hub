import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

import 'async_request_gate.dart';
import 'claim_card.dart';
import 'claim_cards_controller.dart';
import 'location/location_picker_page.dart';
import 'location/location_result.dart';
import 'location/road_routing.dart';
import 'donation_collection_path.dart';
import 'donation_photo_rules.dart';
import 'donation_photo_errors.dart';
import 'donation_status.dart';
import 'hub_admin/hub_service.dart';
import 'hub_admin/hub_widgets.dart';
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
  final int refreshSignal;
  final Future<Object?> Function()? listingsLoader;
  final Future<bool> Function()? routingLoader;
  const EligibleListingsPage({
    super.key,
    this.refreshSignal = 0,
    this.listingsLoader,
    this.routingLoader,
  });
  @override
  State<EligibleListingsPage> createState() => _EligibleListingsPageState();
}

class _EligibleListingsPageState extends State<EligibleListingsPage> {
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
        ? await _db.rpc('discover_eligible_listing_cards')
        : await widget.listingsLoader!();
    if (response is! List) {
      throw const FormatException('Invalid listing response.');
    }
    return response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
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
                    onOpen: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => NgoListingDetailsPage(
                          listing: listing,
                          onClaimConfirmed: () {
                            if (mounted) _refresh();
                          },
                        ),
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
      child: ListTile(
        leading: _StoredImageThumbnail(
          path: listing['primary_image_path']?.toString(),
        ),
        title: Text(
          '${listing['title'] ?? listing['source_type']} · ${listing['listing_weight_kg']} kg',
        ),
        subtitle: Text(
          '${friendlyWorkflowStatus(listing['collection_path'] ?? listing['source_type'])}\n${blockReason == null ? 'Tap to review details. The database rechecks eligibility when you claim.' : 'Details may be viewed; claiming unavailable: $blockReason'}',
        ),
        isThreeLine: true,
        onTap: onOpen,
        trailing: const Icon(Icons.chevron_right),
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
  const MyClaimsPage({
    super.key,
    this.refreshSignal = 0,
    this.claimsLoader,
    this.actionRunner,
    this.detailBuilder,
  });
  @override
  State<MyClaimsPage> createState() => _MyClaimsPageState();
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
      'CANCEL_CLAIM' => _db.rpc(
        'cancel_claim',
        params: {'p_claim': claimId, 'p_request': requestId},
      ),
      _ => throw ArgumentError.value(operation),
    };
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

  Future<void> _openDetails(ClaimCard card) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            widget.detailBuilder?.call(card.claimId) ??
            ClaimPickupDetailPage(claimId: card.claimId),
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
  Widget build(BuildContext context) {
    final rows = _reader.cards
        .where((c) => _selectedTab == ClaimTab.all || c.tab == _selectedTab)
        .toList();
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
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      key: ValueKey('claims-tab-${tab.name}'),
                      label: Text(switch (tab) {
                        ClaimTab.active => 'Active',
                        ClaimTab.expired => 'Expired',
                        ClaimTab.history => 'History',
                        ClaimTab.all => 'All',
                      }),
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

  Widget _card(ClaimCard card) => Card(
    key: ValueKey('claim-${card.claimId}'),
    margin: const EdgeInsets.all(10),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StoredImageThumbnail(path: card.primaryImagePath),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.title ?? card.sourceType ?? 'Claim',
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text('${card.sourceType} · ${card.listingWeightKg} kg'),
                  ],
                ),
              ),
            ],
          ),
          Chip(label: Text(card.badge)),
          if (!_reader.fresh)
            const Text('Refresh required before claim actions.'),
          Text('Claim · ${friendlyWorkflowStatus(card.claimStatus)}'),
          Text('Lease · ${friendlyWorkflowStatus(card.leaseStatus)}'),
          Text(
            'Lease expiry (database): ${statusTimestampText(context, card.raw['lease_expires_at']) ?? '—'}',
          ),
          Text('Pickup task · ${friendlyWorkflowStatus(card.taskStatus)}'),
          if (card.releaseReason != null)
            Text('Release reason: ${card.releaseReason}'),
          if (card.displayStatus == ClaimDisplayStatus.reconciliation)
            const Text(
              'The listing is not available while handover remains unresolved.',
            ),
          if (card.tab == ClaimTab.expired)
            const Text(
              'Expiry does not release this claim or reopen its listing. The database controls recovery.',
            ),
          if (card.tab == ClaimTab.expired && card.taskStatus == 'DISPATCHED')
            const Text('Pickup started — custody requires review.'),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _openDetails(card),
                icon: const Icon(Icons.location_on_outlined),
                label: const Text('Claim details'),
              ),
              if (card.claimStatus == 'ACTIVE' &&
                  card.taskStatus == 'CONFIRMED')
                TextButton(
                  onPressed: _allowed(card, 'CANCEL_CLAIM')
                      ? () => _cancelClaim(card)
                      : null,
                  child: const Text('Cancel Claim'),
                ),
              TextButton.icon(
                onPressed: () => _audit(card.claimId),
                icon: const Icon(Icons.history),
                label: const Text('Audit'),
              ),
            ],
          ),
          Text(
            'Claim ID: ${card.claimId}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

class NgoListingDetailsPage extends StatefulWidget {
  final Map<String, dynamic> listing;
  final VoidCallback? onClaimConfirmed;
  const NgoListingDetailsPage({
    super.key,
    required this.listing,
    this.onClaimConfirmed,
  });

  @override
  State<NgoListingDetailsPage> createState() => _NgoListingDetailsPageState();
}

class _NgoListingDetailsPageState extends State<NgoListingDetailsPage> {
  late final Future<Map<String, dynamic>> _details = _load();
  late final Future<bool> _trustedRouting = _loadTrustedRouting();
  bool _claimBusy = false;

  Future<bool> _loadTrustedRouting() async {
    try {
      final response = await _db.rpc('geolock_app_capabilities');
      return response is Map && response['road_node_resolution'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _claim() async {
    if (_claimBusy) return;
    final userId = _db.auth.currentUser?.id;
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
      final key = 'geolock_claim_request_${userId}_$listingId';
      final id = prefs.getString(key) ?? const Uuid().v4();
      request = id;
      await prefs.setString(key, id);
      if (_db.auth.currentUser?.id != userId) {
        throw StateError('Your sign-in changed. No claim was sent.');
      }
      rpcStarted = true;
      final response = await _db.rpc(
        'claim_listing',
        params: {'p_listing': listingId, 'p_request': id},
      );
      if (response is! Map) {
        throw const FormatException(
          'Claim RPC returned no authoritative outcome.',
        );
      }
      result = Map<String, dynamic>.from(response);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              rpcStarted
                  ? 'Claim outcome is unconfirmed. Retry this same attempt; it will reuse request ID ${request ?? 'saved for this listing'}. Error: $error'
                  : 'The claim could not be prepared safely, so no claim request was sent. Error: $error',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      if (mounted) setState(() => _claimBusy = false);
      return;
    }

    final outcome = result['outcome']?.toString();
    final reason = result['reason_code']?.toString();
    final claimId = result['claim_id']?.toString();
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
              'Claim outcome is unconfirmed. Retry this same attempt; it will reuse request ID $request.',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      return;
    }

    // The database returned a complete terminal result. Removing the stored
    // key is best-effort; if it fails, replaying it remains idempotent.
    try {
      await prefs.remove('geolock_claim_request_${userId}_$listingId');
    } catch (_) {}
    if (!mounted) return;
    if (!confirmedSuccess) {
      setState(() => _claimBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Claim not accepted: ${roadOutcomeMessage(reason)}'),
        ),
      );
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
      const SnackBar(content: Text('Claim confirmed. Opening My Claims.')),
    );
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const MyClaimsPage()));
  }

  Future<Map<String, dynamic>> _load() async {
    final row = widget.listing;
    final isBatch = row['source_type'] == 'HUB_BATCH';
    // This protected read revalidates availability and exact road eligibility
    // before details or any image references are shown, for either source type.
    final rawMembers = await _db.rpc(
      'get_eligible_listing_constituents',
      params: {'p_listing': row['listing_id']},
    );
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
    return {
      'images': images,
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
  Widget build(BuildContext context) => Scaffold(
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
                widget.listing['routing_status'] == 'READY';
            return FilledButton.icon(
              onPressed: detailSnapshot.hasData && routeReady && !_claimBusy
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
        final images = (data['images'] as List).cast<Map<String, dynamic>>();
        final constituents = (data['constituents'] as List)
            .cast<Map<String, dynamic>>();
        final cover = widget.listing['primary_image_path']?.toString();
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
            const SizedBox(height: 4),
            Text(
              widget.listing['source_type'] == 'HUB_BATCH'
                  ? 'Community hub collection'
                  : 'Direct pickup',
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
              pendingMilestones: data['progress_status'] == 'AVAILABLE'
                  ? pendingDonationMilestones(
                      collectionPath: 'DIRECT_PICKUP',
                      currentStatus: 'AVAILABLE',
                    )
                  : const [],
              emptyMessage:
                  'This state is present in the eligible discovery response. Historical status timestamps are not provided on this screen.',
            ),
            const SizedBox(height: 12),
            DonationPhotoCarousel(paths: uniqueImagePaths),
            const SizedBox(height: 12),
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
            const SizedBox(height: 8),
            const Text(
              'Item-level names and quantities are not included in the current authorized listing-detail response.',
            ),
          ],
        );
      },
    ),
  );
}

class ClaimPickupDetailPage extends StatefulWidget {
  final String claimId;
  const ClaimPickupDetailPage({super.key, required this.claimId});

  @override
  State<ClaimPickupDetailPage> createState() => _ClaimPickupDetailPageState();
}

class _ClaimPickupDetailPageState extends State<ClaimPickupDetailPage>
    with WidgetsBindingObserver {
  late Future<Map<String, dynamic>> _detail = _load();
  bool _reconciliationBusy = false;
  Timer? _leaseRefresh;
  int _generation = 0;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authSubscription = _db.auth.onAuthStateChange.listen(
      (_) => _refreshDetail(),
    );
  }

  void _refreshDetail() {
    _leaseRefresh?.cancel();
    if (mounted) setState(() => _detail = _load());
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
    final userId = _db.auth.currentUser?.id;
    final elapsed = Stopwatch()..start();
    final response = await _db.rpc(
      'get_claimed_listing_detail',
      params: {'p_claim': widget.claimId},
    );
    if (response is! Map) {
      throw const FormatException('Invalid claim detail response.');
    }
    final result = Map<String, dynamic>.from(response);
    final constituents = await _db.rpc(
      'get_claimed_listing_constituents',
      params: {'p_claim': widget.claimId},
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
    final cards = await _db.rpc('get_my_claim_cards_v2');
    if (cards is List) {
      for (final row in cards) {
        final card = Map<String, dynamic>.from(row as Map);
        if (card['claim_id']?.toString() == widget.claimId) {
          result['claim_card'] = card;
          result['presentation'] = ClaimCard.fromJson(card);
          break;
        }
      }
    }
    var auditRows = <Map<String, dynamic>>[];
    String? auditError;
    try {
      final audit = await _db.rpc(
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
    if (userId != _db.auth.currentUser?.id) {
      throw StateError('Account changed. Refresh details.');
    }
    final presentation = result['presentation'] as ClaimCard?;
    if (mounted &&
        generation == _generation &&
        presentation?.isValidActive == true) {
      final delay =
          presentation!.leaseExpiresAt!.difference(presentation.serverNow!) -
          elapsed.elapsed;
      _leaseRefresh?.cancel();
      _leaseRefresh = Timer(
        delay > Duration.zero ? delay : const Duration(seconds: 1),
        _refreshDetail,
      );
    }
    return result;
  }

  Future<void> _submitReconciliation(bool handoverConfirmed) async {
    final choice = handoverConfirmed ? 'yes' : 'no';
    final prefs = await SharedPreferences.getInstance();
    final key =
        'geolock_reconcile_${_db.auth.currentUser?.id}_${widget.claimId}_$choice';
    final requestId = prefs.getString(key) ?? const Uuid().v4();
    await prefs.setString(key, requestId);
    setState(() => _reconciliationBusy = true);
    try {
      final response = await _db.rpc(
        'submit_claim_reconciliation',
        params: {
          'p_claim': widget.claimId,
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${result['outcome']}: ${result['reason_code'] ?? 'Evidence recorded'}',
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
      if (mounted) {
        _refreshDetail();
        setState(() => _reconciliationBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Claimed Pickup Details')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _detail,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Pickup details unavailable: ${snapshot.error}'),
          );
        }
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
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
        final presentation = data['presentation'] as ClaimCard?;
        final isReconciliationRequired =
            presentation?.displayStatus == ClaimDisplayStatus.reconciliation &&
            (claimStatus == 'RECONCILIATION_REQUIRED' ||
                leaseStatus == 'RECONCILIATION_REQUIRED');
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
            Chip(label: Text(presentation?.badge ?? 'Status Needs Review')),
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
              Card(
                color: const Color(0xfffff0e8),
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
                          'This claim is unresolved. Do not treat the listing as available.',
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          FilledButton.tonal(
                            onPressed: _reconciliationBusy
                                ? null
                                : () => _submitReconciliation(true),
                            child: const Text('Confirm handover'),
                          ),
                          OutlinedButton(
                            onPressed: _reconciliationBusy
                                ? null
                                : () => _submitReconciliation(false),
                            child: const Text('Confirm no handover'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'The donor or hub administrator must also submit matching evidence. Some cases remain under trusted review.',
                      ),
                    ],
                  ),
                ),
              ),
            GeoStatusTimeline(
              title: 'Claim and Pickup History',
              currentStatus: presentation?.badge ?? 'Status Needs Review',
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

  /// Storage the category needs (hubNeedKeys), e.g. food-safe storage for food.
  final Set<String> needs;
  const DonationCategory(this.id, this.name, [this.needs = const <String>{}]);

  DonationCategory.fromInfo(DonationCategoryInfo info)
    : this(info.id, info.name, info.needs);

  String? get needsText => needs.isEmpty
      ? null
      : 'Needs ${needs.map((n) => hubNeedLabels[n]!.toLowerCase()).join(', ')}';
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

  Future<List<DonationCategory>> _loadCategories() async =>
      (await HubService.categories()).map(DonationCategory.fromInfo).toList();

  static const _directPickupHint =
      'Choose a spot where a vehicle can stop (roadside, gate or lobby)';

  double get _previewTotalKg => donationTotalWeightKg(
    items.map(
      (item) => (
        quantity: int.tryParse(item.quantity.text.trim()),
        unitWeightKg: double.tryParse(item.weight.text.trim()),
      ),
    ),
  );

  bool get _directPickupPreview =>
      previewCollectionPath(_previewTotalKg) == 'DIRECT_PICKUP';

  Future<void> selectPickupLocation() async {
    final selected = await Navigator.push<LocationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          title: 'Pickup location',
          initialLocation: pickupLocation,
          roadAccess: RoadAccessRequirement.required,
          hint: _directPickupPreview ? _directPickupHint : null,
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
      final imagePayload = await _uploadDonationImages();
      if (mounted) {
        setState(() => progressMessage = 'Saving your donation…');
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
          // Never send a client node: trg_donation_road_node snaps the stored
          // pickup point to the nearest drivable road node in the database.
          pickupRoadNodeId: null,
          items: payload,
          images: imagePayload,
        ),
      );
      final donationId = id?.toString().trim() ?? '';
      if (donationId.isEmpty) {
        throw const FormatException('The database did not return a donation.');
      }
      if (mounted) {
        setState(() => progressMessage = 'Almost done…');
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
              Text(
                _directPickupPreview ? 'Pickup location' : 'Your location',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                _directPickupPreview
                    ? _directPickupHint
                    : 'Used to find community hubs near you',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : selectPickupLocation,
                icon: const Icon(Icons.location_on_outlined),
                label: Text(
                  pickupLocation == null ? 'Select location' : 'Change location',
                ),
              ),
              if (pickupLocation != null) Text(pickupLocation!.address),
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
                        if (_categoryNeedsText(choices, item.category).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.warehouse_outlined,
                                  size: 14,
                                  color: HubColors.muted,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    _categoryNeedsText(choices, item.category),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: HubColors.muted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
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
                            labelText: 'Weight of one piece (kg)',
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
              CollectionPathPreviewCard(totalKg: _previewTotalKg),
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
            ],
          ),
        );
      },
    ),
  );
}

class CollectionPathPreviewCard extends StatelessWidget {
  final double totalKg;
  const CollectionPathPreviewCard({super.key, required this.totalKg});

  @override
  Widget build(BuildContext context) {
    final direct = previewCollectionPath(totalKg) == 'DIRECT_PICKUP';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ListTile(
        leading: Icon(
          direct ? Icons.local_shipping_outlined : Icons.store_outlined,
        ),
        title: Text(
          totalKg <= 0
              ? 'Enter quantity and weight to see how it is collected'
              : collectionPathPreviewText(totalKg),
        ),
        subtitle: Text(
          'Under ${donationDirectMinKgPreview.toStringAsFixed(0)} kg: you bring it to a '
          'community hub. ${donationDirectMinKgPreview.toStringAsFixed(0)} kg or more: an '
          'NGO collects it from you.',
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
      content: hub
          ? Text(
              '${detail['total_weight_kg'] == null ? 'It is' : 'At ${detail['total_weight_kg']} kg it is'} '
              'under 10 kg, so you bring it to a community hub. Next, choose the hub '
              'and the day you will come.',
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailLine(
                  'Status',
                  donationStatusLabel(status: status, collectionPath: path),
                ),
                _detailLine('Collection', collectionPathLabel(path)),
                if (detail['total_weight_kg'] != null)
                  _detailLine('Total weight', '${detail['total_weight_kg']} kg'),
                _detailLine('Road', routingStatusExplanation(road)),
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

  /// Opens the hub chooser once the page appears (after a new hub donation).
  final bool openHubSelection;
  const DonationDetailPage({
    super.key,
    required this.donationId,
    this.openHubSelection = false,
  });
  @override
  State<DonationDetailPage> createState() => _DonationDetailPageState();
}

class _DonationDetailPageState extends State<DonationDetailPage> {
  late Future<Map<String, dynamic>> _detail = _load();
  bool _busy = false;
  String _cancelRequestId = const Uuid().v4();

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
    // Hubs are ranked by the AI service (or nearest first if it is down); the
    // booking itself is re-checked by reserve_hub_capacity.
    final booked = await openHubChooser(context, widget.donationId);
    if (booked && mounted) setState(() => _detail = _load());
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this donation?'),
        content: const Text(
          'Any hub booking for it is released. You cannot undo this.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep donation'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel donation'),
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
          const SnackBar(content: Text('Donation cancelled.')),
        );
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Not cancelled: ${hubErrorMessage(error)}')),
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
            'CREATE_DONATION',
            'DONATION_STATUS_CHANGED',
            'DONATION_STATUS_BACKFILL',
            'CONFIRM_HUB_RECEIPT',
            'CANCEL_DONATION',
          },
        );
        final hubHistoryIsClear = reservations.every(
          (reservation) => reservation['receipt_status'] == null,
        );
        final cancellable =
            !hasReceipt &&
            !hasInventory &&
            ((d['status'] == 'SUBMITTED' && reservations.isEmpty) ||
                (d['status'] == 'AVAILABLE' &&
                    d['collection_path'] == 'DIRECT_PICKUP' &&
                    d['listing_status'] == 'AVAILABLE' &&
                    reservations.isEmpty) ||
                (d['status'] == 'HUB_ASSIGNED' &&
                    d['collection_path'] == 'HUB_COLLECTION' &&
                    hubHistoryIsClear &&
                    (latestReservationStatus == 'ACTIVE' ||
                        latestReservationStatus == 'EXPIRED')));
        final statusLabel =
            d['status'] == 'HUB_ASSIGNED' &&
                latestReservationStatus == 'EXPIRED'
            ? 'Booking ended'
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
                      // What the donor has to do next comes first.
                      if (isHubCollection) ...[
                        const SizedBox(height: 14),
                        HubDropOffCard(
                          key: ObjectKey(_detail),
                          donationId: widget.donationId,
                          onChanged: () => setState(() => _detail = _load()),
                        ),
                      ],
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
                                            ? 'Your location'
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
                      if (cancellable)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Center(
                            child: TextButton.icon(
                              onPressed: _busy ? null : _cancel,
                              icon: const Icon(Icons.close),
                              label: Text(
                                _busy ? 'Please wait…' : 'Cancel this donation',
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
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

// Community hub drop-off for small donations: the card on the donation page,
// choosing a hub and the drop-off pass.

Future<bool> openHubChooser(
  BuildContext context,
  String donationId, {
  String? donationTitle,
}) async {
  final booked = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (_) =>
          HubChoosePage(donationId: donationId, donationTitle: donationTitle),
    ),
  );
  return booked == true;
}

/// "Needs food-safe storage" for the chosen category, or "" when nothing is needed.
String _categoryNeedsText(List<DonationCategory> choices, String? id) {
  for (final c in choices) {
    if (c.id == id) return c.needsText ?? '';
  }
  return '';
}

class HubDropOffCard extends StatefulWidget {
  final String donationId;

  /// Called after the donor booked a hub so the donation page can reload.
  final VoidCallback? onChanged;

  const HubDropOffCard({super.key, required this.donationId, this.onChanged});

  @override
  State<HubDropOffCard> createState() => _HubDropOffCardState();
}

class _HubDropOffCardState extends State<HubDropOffCard> {
  late Future<HubDropOffPass> _pass = HubService.dropOffPass(widget.donationId);
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(HubDropOffCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.donationId != widget.donationId) {
      _pass = HubService.dropOffPass(widget.donationId);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _choose(HubDropOffPass pass) async {
    final booked = await openHubChooser(
      context,
      widget.donationId,
      donationTitle: pass.title,
    );
    if (!booked || !mounted) return;
    setState(() => _pass = HubService.dropOffPass(widget.donationId));
    widget.onChanged?.call();
  }

  void _openPass() => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => HubDropOffPassPage(donationId: widget.donationId),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<HubDropOffPass>(
    future: _pass,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return HubCard(
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined, color: HubColors.muted),
              const SizedBox(width: 10),
              Expanded(child: Text(hubErrorMessage(snapshot.error!))),
              TextButton(
                onPressed: () => setState(
                  () => _pass = HubService.dropOffPass(widget.donationId),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      }
      if (!snapshot.hasData) {
        return const HubCard(child: LinearProgressIndicator());
      }
      final pass = snapshot.data!;
      final r = pass.reservation;
      switch (pass.nextStep) {
        case HubNextStep.notHub:
        case HubNextStep.cancelled:
          return const SizedBox.shrink();
        case HubNextStep.chooseHub:
          return _card(
            icon: Icons.storefront_outlined,
            color: HubColors.green,
            title: 'Choose a drop-off hub',
            body:
                'This donation is under 10 kg, so it is collected at a community hub. '
                'We show the best hub for your items first.',
            action: FilledButton.icon(
              onPressed: () => _choose(pass),
              icon: const Icon(Icons.storefront_outlined),
              label: const Text('Choose a hub'),
            ),
          );
        case HubNextStep.dropOff:
          final day = r?.dropOffDay;
          return _card(
            icon: Icons.directions_walk,
            color: HubColors.blue,
            title: 'Drop off at ${r?.hubName ?? 'the hub'}',
            body:
                'Reference ${r?.referenceCode ?? ''} · '
                '${day == null ? 'before ${hubCloseLabel(r?.expiresAt)}' : '${hubDayLabel(day)}, any time ${r!.hours.textOn(day)}'}'
                '\n${r?.hubAddress ?? ''}',
            action: FilledButton.icon(
              onPressed: _openPass,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Show drop-off pass'),
            ),
          );
        case HubNextStep.chooseAgain:
          return _card(
            icon: Icons.timer_off_outlined,
            color: HubColors.amber,
            title: 'Your booking ended',
            body:
                'The booking at ${r?.hubName ?? 'the hub'}'
                '${r?.dropOffDay == null ? '' : ' for ${hubDayDate(r!.dropOffDay!)}'} ended '
                'before the drop-off, so the space was given back. Choose a hub and day '
                'again when you are ready.',
            action: FilledButton.icon(
              onPressed: () => _choose(pass),
              icon: const Icon(Icons.refresh),
              label: const Text('Choose a hub again'),
            ),
          );
        case HubNextStep.atHub:
          return _card(
            icon: Icons.inventory_2_outlined,
            color: HubColors.green,
            title: 'At ${r?.hubName ?? 'the hub'}',
            body:
                'Received ${hubDateTime(r?.receivedAt)}. The hub will add it to a batch '
                'for an NGO to collect.',
          );
        case HubNextStep.inBatch:
          return _card(
            icon: Icons.all_inbox_outlined,
            color: HubColors.blue,
            title: 'In a batch for NGOs',
            body:
                '${r?.hubName ?? 'The hub'} grouped your donation with others. An NGO '
                'nearby claims and collects the batch.',
          );
        case HubNextStep.done:
          return _card(
            icon: Icons.task_alt,
            color: HubColors.green,
            title: 'Collected by an NGO',
            body:
                'Thank you! Your donation has reached an NGO through ${r?.hubName ?? 'the hub'}.',
          );
      }
    },
  );

  Widget _card({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    Widget? action,
  }) => HubCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(body),
        if (action != null) ...[
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: action),
        ],
      ],
    ),
  );
}

class HubChoosePage extends StatefulWidget {
  final String donationId;
  final String? donationTitle;

  const HubChoosePage({
    super.key,
    required this.donationId,
    this.donationTitle,
  });

  @override
  State<HubChoosePage> createState() => _HubChoosePageState();
}

class _HubChoosePageState extends State<HubChoosePage> {
  /// The day the donor will bring the donation (Malaysia date).
  DateTime _day = hubToday();
  late Future<List<HubOption>> _options = _load();
  bool _reserving = false;

  Future<List<HubOption>> _load() =>
      HubService.hubOptions(widget.donationId, day: _day);

  Future<void> _refresh() async {
    setState(() => _options = _load());
    await _options;
  }

  void _setDay(DateTime day) {
    if (day == _day) return;
    setState(() {
      _day = day;
      _options = _load();
    });
  }

  Future<void> _reserve(HubOption hub) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _ConfirmSheet(hub: hub, day: _day),
    );
    if (ok != true || !mounted) return;
    setState(() => _reserving = true);
    try {
      await HubService.reserveHub(widget.donationId, hub.hubId, day: _day);
      if (!mounted) return;
      hubToast(
        context,
        'Booked at ${hub.name} for ${hubOnDay(_day).replaceFirst('on ', '')}. '
        'Come any time it is open that day.',
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      hubToast(context, 'Not booked: ${hubErrorMessage(error)}');
      await _refresh();
    } finally {
      if (mounted) setState(() => _reserving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Choose a drop-off hub'),
      bottom: widget.donationTitle == null
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(22),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'For: ${widget.donationTitle}',
                  style: const TextStyle(color: HubColors.muted),
                ),
              ),
            ),
    ),
    body: Stack(
      children: [
        HubRefreshList<List<HubOption>>(
          future: _options,
          onRefresh: _refresh,
          builder: (context, options) {
            final feasible = options.where((o) => o.feasible).toList();
            final others = options.where((o) => !o.feasible).toList();
            // Keep the server's order; the first feasible hub is the recommendation.
            final recommended = feasible.isEmpty ? null : feasible.first;
            return [
              const _HowItWorks(),
              _DayPicker(
                selected: _day,
                onChanged: _reserving ? null : _setDay,
              ),
              if (recommended != null)
                _RankingBanner(mode: recommended.rankingMode),
              if (recommended != null) ...[
                HubSectionTitle(
                  recommended.rankingMode == 'MODEL'
                      ? 'AI recommended for you'
                      : 'Recommended for you',
                ),
                _HubOptionCard(
                  hub: recommended,
                  day: _day,
                  recommended: true,
                  onTap: _reserving ? null : () => _reserve(recommended),
                ),
              ],
              if (feasible.length > 1) ...[
                HubSectionTitle(
                  'Other hubs (${feasible.length - 1})',
                  subtitle: recommended!.aiRanked
                      ? 'Best match first'
                      : 'Nearest first',
                ),
                for (final hub in feasible.skip(1))
                  _HubOptionCard(
                    hub: hub,
                    day: _day,
                    onTap: _reserving ? null : () => _reserve(hub),
                  ),
              ],
              if (feasible.isEmpty)
                HubEmptyState(
                  icon: Icons.storefront_outlined,
                  title: 'No hub can take this donation ${hubOnDay(_day)}',
                  message:
                      'Hubs may be closed, full, or not accept these items that day. '
                      'Try another day above, or pull down to check again.',
                ),
              if (others.isNotEmpty)
                Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 2),
                    title: Text(
                      'Not available ${hubOnDay(_day)} (${others.length})',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    children: [
                      for (final hub in others) _UnavailableTile(hub: hub),
                    ],
                  ),
                ),
            ];
          },
        ),
        if (_reserving)
          const ColoredBox(
            color: Color(0x66ffffff),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    ),
  );
}

/// Drop-off day: today and the next 6 days.
class _DayPicker extends StatelessWidget {
  final DateTime selected;
  final ValueChanged<DateTime>? onChanged;
  const _DayPicker({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const HubSectionTitle(
        'When will you drop it off?',
        subtitle: 'Pick a day. You can come any time the hub is open that day.',
      ),
      SizedBox(
        height: 42,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final day in hubDropOffDays())
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(hubDayLabel(day)),
                  selected: day == selected,
                  onSelected: onChanged == null ? null : (_) => onChanged!(day),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 4),
    ],
  );
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) => const HubCard(
    color: HubColors.softGreen,
    borderColor: Colors.transparent,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, color: HubColors.green),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Small donations are collected at a community hub. Pick the day you will '
            'come, then a hub: it keeps space for you until it closes that day. Come any '
            'time it is open and show your reference code at the counter.',
          ),
        ),
      ],
    ),
  );
}

class _HubOptionCard extends StatelessWidget {
  final HubOption hub;
  final DateTime day;
  final bool recommended;
  final VoidCallback? onTap;

  const _HubOptionCard({
    required this.hub,
    required this.day,
    this.recommended = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final today = day == hubToday();
    final open = today && hub.hours.isOpenNow;
    final close = hub.hours.lastCloseOn(day);
    final until = close == null ? '' : ' · until ${hubTimeLabel(close)}';
    return HubCard(
      onTap: onTap,
      borderColor: recommended ? HubColors.green : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: HubColors.softGreen,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.storefront_outlined,
                  color: HubColors.green,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hub.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      hub.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: HubColors.muted),
                    ),
                  ],
                ),
              ),
              if (recommended)
                HubStatusChip(
                  hub.rankingMode == 'MODEL' ? 'AI pick' : 'Recommended',
                  color: HubColors.green,
                  icon: hub.rankingMode == 'MODEL'
                      ? Icons.auto_awesome
                      : Icons.star_rounded,
                )
              else if (hub.inTopK && hub.rank != null)
                HubStatusChip('Top ${hub.rank}', color: HubColors.blue),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (hub.roadKm != null)
                HubStatusChip(
                  '${hub.roadKm!.toStringAsFixed(1)} km by road',
                  color: HubColors.blue,
                  icon: Icons.route_outlined,
                ),
              HubStatusChip(
                today
                    ? (open ? 'Open now$until' : 'Opens later$until')
                    : 'Open ${hubDayLabel(day)}$until',
                color: open || !today ? HubColors.green : HubColors.amber,
                icon: Icons.schedule,
              ),
              HubStatusChip(
                '${hubKg(hub.availableKg)} free',
                color: HubColors.muted,
                icon: Icons.inventory_2_outlined,
              ),
              if (hub.storageNote != null)
                HubStatusChip(
                  hub.storageNote!,
                  color: hub.storageNote!.startsWith('Has')
                      ? HubColors.green
                      : HubColors.amber,
                  icon: Icons.warehouse_outlined,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${hubDayLabel(day)}: ${hub.hours.textOn(day)}',
            style: const TextStyle(fontSize: 13, color: HubColors.muted),
          ),
          if (recommended)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _whyRecommended(hub),
                style: const TextStyle(fontSize: 12, color: HubColors.muted),
              ),
            ),
        ],
      ),
    );
  }
}

String _whyRecommended(HubOption hub) => switch (hub.rankingMode) {
  'MODEL' =>
    hub.explanation ?? 'Best balance of distance, free space and handling.',
  'REFERENCE_FALLBACK' =>
    hub.explanation ??
        'Best balance of road distance, how full the hub is and free space.',
  _ =>
    'Nearest hub by road that accepts your items, has space and is open '
        'on your drop-off day.',
};

/// Says how the hub list is ordered.
class _RankingBanner extends StatelessWidget {
  final String mode;
  const _RankingBanner({required this.mode});

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (mode) {
      'MODEL' => (
        Icons.auto_awesome,
        HubColors.green,
        'Ranked by AI: road distance, how full each hub is, free space and whether '
            'the hub has the storage your items need.',
      ),
      'REFERENCE_FALLBACK' => (
        Icons.rule,
        HubColors.amber,
        'AI is unavailable. Ranked by the standard rule (distance, fullness, free space).',
      ),
      _ => (Icons.route_outlined, HubColors.muted, 'Sorted by road distance.'),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, color: HubColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnavailableTile extends StatelessWidget {
  final HubOption hub;
  const _UnavailableTile({required this.hub});

  @override
  Widget build(BuildContext context) => HubCard(
    color: const Color(0xfff7f9f8),
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        const Icon(Icons.block, color: HubColors.muted),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hub.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                hub.reasons.map(hubReasonText).join(' · '),
                style: const TextStyle(color: HubColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
        if (hub.roadKm != null)
          Text(
            '${hub.roadKm!.toStringAsFixed(1)} km',
            style: const TextStyle(color: HubColors.muted),
          ),
      ],
    ),
  );
}

class _ConfirmSheet extends StatelessWidget {
  final HubOption hub;
  final DateTime day;
  const _ConfirmSheet({required this.hub, required this.day});

  @override
  Widget build(BuildContext context) {
    final label = hubDayLabel(day);
    final close = hub.hours.lastCloseOn(day);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Book ${hub.name}?',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            HubInfoRow(Icons.place_outlined, 'Address', hub.address),
            HubInfoRow(
              Icons.event_outlined,
              'Drop-off day',
              label.startsWith('To') ? '$label (${hubDayDate(day)})' : label,
            ),
            HubInfoRow(Icons.schedule, 'Open that day', hub.hours.textOn(day)),
            HubInfoRow(
              Icons.timer_outlined,
              'Space held until',
              hub.closesAt != null
                  ? hubCloseLabel(hub.closesAt)
                  : (close == null ? '—' : hubTimeLabel(close)),
            ),
            const SizedBox(height: 8),
            const Text(
              'Come any time the hub is open that day; no appointment needed. If you do '
              'not come by closing time, the booking ends and you can choose a hub and '
              'day again.',
              style: TextStyle(color: HubColors.muted),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Book this hub'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class HubDropOffPassPage extends StatefulWidget {
  final String donationId;
  const HubDropOffPassPage({super.key, required this.donationId});

  @override
  State<HubDropOffPassPage> createState() => _HubDropOffPassPageState();
}

class _HubDropOffPassPageState extends State<HubDropOffPassPage> {
  late Future<HubDropOffPass> _pass = HubService.dropOffPass(widget.donationId);
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Redraw the countdown every 30 seconds.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _pass = HubService.dropOffPass(widget.donationId));
    await _pass;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Drop-off pass')),
    body: HubRefreshList<HubDropOffPass>(
      future: _pass,
      onRefresh: _refresh,
      builder: (context, pass) {
        final r = pass.reservation;
        if (r == null) {
          return const [
            HubEmptyState(
              icon: Icons.storefront_outlined,
              title: 'No hub booked',
              message: 'Choose a hub from the donation page first.',
            ),
          ];
        }
        final booked = r.dropOffDay;
        final bookedKey = booked == null ? hubTodayKey() : hubDayKey(booked);
        return [
          _PassCard(pass: pass, reservation: r),
          const HubSectionTitle('Hub'),
          HubCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.hubName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(r.hubAddress)),
                    IconButton(
                      tooltip: 'Copy address',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: r.hubAddress));
                        hubToast(
                          context,
                          'Address copied. Paste it into your maps app.',
                        );
                      },
                    ),
                  ],
                ),
                const Divider(height: 20),
                const Text(
                  'Opening hours',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                for (final day in hubWeekdays)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 110,
                          child: Text(
                            hubWeekdayLabels[day]!,
                            style: TextStyle(
                              fontWeight: day == bookedKey
                                  ? FontWeight.w800
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            r.hours.dayText(day),
                            style: TextStyle(
                              fontWeight: day == bookedKey
                                  ? FontWeight.w800
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (r.status == HubDropOffStatus.awaiting) ...[
            const HubSectionTitle('At the hub'),
            const HubCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Step(1, 'Bring all the items in this donation.'),
                  _Step(2, 'Show the reference code to the hub staff.'),
                  _Step(
                    3,
                    'The staff weigh the items and confirm the receipt.',
                  ),
                  _Step(
                    4,
                    'You will see "At hub" on your donation. Thank you!',
                  ),
                ],
              ),
            ),
            const HubSectionTitle('Cannot make it?'),
            HubCard(
              child: Text(
                'If you do not come by ${hubCloseLabel(r.expiresAt)}'
                '${booked == null ? '' : ' ${hubOnDay(booked)}'}, the booking ends and the '
                'space is given back. You can then choose a hub and day again from the '
                'donation page, or cancel the donation there.',
              ),
            ),
          ],
        ];
      },
    ),
  );
}

class _PassCard extends StatelessWidget {
  final HubDropOffPass pass;
  final HubPassReservation reservation;
  const _PassCard({required this.pass, required this.reservation});

  @override
  Widget build(BuildContext context) {
    final r = reservation;
    final awaiting = r.status == HubDropOffStatus.awaiting;
    final left = hubMinutesLeft(r.expiresAt);
    final day = r.dropOffDay;
    final today = day != null && day == hubToday();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xff2f806c), Color(0xff1f5f50)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Text(
            pass.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          Text(
            '${hubKg(r.reservedKg)} · ${r.hubName}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          const Text('Reference code', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              r.referenceCode,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w900,
                letterSpacing: 6,
                fontFamily: 'monospace',
                color: HubColors.ink,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (awaiting) ...[
            Text(
              left == 0
                  ? 'Time is up'
                  : day == null
                  ? 'Drop off before ${hubCloseLabel(r.expiresAt)}'
                  : 'Drop off ${hubOnDay(day)}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (day != null)
              Text(
                '${hubDayDate(day)} · any time ${r.hours.textOn(day)}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            if (today && left > 0 && left <= 120)
              Text(
                'Closes in ${hubDuration(left)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ] else
            Text(
              r.status == HubDropOffStatus.received
                  ? 'Received ${hubDateTime(r.receivedAt)} · ${hubKg(r.receivedKg ?? r.reservedKg)}'
                  : hubDropOffLabel(r.status),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final String text;
  const _Step(this.number, this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 11,
          backgroundColor: HubColors.softGreen,
          child: Text(
            '$number',
            style: const TextStyle(
              fontSize: 12,
              color: HubColors.green,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
