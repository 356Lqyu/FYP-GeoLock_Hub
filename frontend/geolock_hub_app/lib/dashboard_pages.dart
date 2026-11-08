import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'async_request_gate.dart';
import 'claim_cards_controller.dart';
import 'auth/auth_navigation.dart';
import 'auth/auth_controller.dart';
import 'donation_pages.dart';
import 'donation_status.dart';
import 'location/road_routing.dart';
import 'location/location_picker_page.dart';
import 'location/location_result.dart';
import 'routing/ngo_routes_page.dart';
import 'auth/auth_pages.dart' as hub_auth;
import 'hub_admin/hub_admin_controller.dart';
import 'hub_admin/hub_dropoff_page.dart';
import 'hub_admin/hub_inventory_page.dart';
import 'hub_admin/hub_listing_page.dart';
import 'hub_admin/hub_notification_page.dart';
import 'hub_admin/hub_service.dart';
import 'hub_admin/hub_service_rules_page.dart';
import 'hub_admin/hub_widgets.dart';

const _mint = Color(0xffedfbf7);
const _green = Color(0xff2f806c);
const _ink = Color(0xff102c2a);
final _dashboardDb = Supabase.instance.client;

class RoleNavigationShell extends StatefulWidget {
  final String role;
  final String userId;

  const RoleNavigationShell({
    super.key,
    required this.role,
    required this.userId,
  });

  @override
  State<RoleNavigationShell> createState() => _RoleNavigationShellState();
}

class _RoleNavigationShellState extends State<RoleNavigationShell> {
  int _index = 0;
  final List<int> _ngoTabRefreshSignals = List<int>.filled(5, 0);
  final List<int> _donorTabRefreshSignals = List<int>.filled(4, 0);
  final List<bool> _donorTabVisited = [true, false, false, false];
  late final List<_RoleTab> _tabs = _tabsFor(widget.role);

  List<_RoleTab> _tabsFor(String role) {
    if (role == 'DONOR') {
      return [
        _RoleTab(
          'Home',
          Icons.home_outlined,
          DonorHomePage(onDonations: () => _select(1)),
        ),
        _RoleTab(
          'Donations',
          Icons.volunteer_activism_outlined,
          const DonorMyDonationsPage(),
        ),
        _RoleTab('Impact', Icons.insights_outlined, const DonorImpactPage()),
        _RoleTab(
          'Profile',
          Icons.person_outline,
          const RoleProfilePage(role: 'DONOR'),
        ),
      ];
    }
    if (role == 'NGO') {
      return [
        _RoleTab('Home', Icons.home_outlined, const NgoHomePage()),
        _RoleTab('Discover', Icons.search, const EligibleListingsPage()),
        _RoleTab('My Claims', Icons.assignment_outlined, const MyClaimsPage()),
        _RoleTab(
          'Pickups',
          Icons.local_shipping_outlined,
          const NgoPickupsPage(),
        ),
        _RoleTab(
          'Profile',
          Icons.person_outline,
          const RoleProfilePage(role: 'NGO'),
        ),
      ];
    }
    return [
      _RoleTab('Home', Icons.home_outlined, const HubAdminHomePage()),
      _RoleTab(
        'Inventory',
        Icons.inventory_2_outlined,
        const HubOperationsTab(section: 'Inventory'),
      ),
      _RoleTab(
        'Receive',
        Icons.move_to_inbox_outlined,
        const HubOperationsTab(section: 'Receive'),
      ),
      _RoleTab(
        'Collections',
        Icons.local_shipping_outlined,
        const HubOperationsTab(section: 'Collections'),
      ),
      _RoleTab(
        'Profile',
        Icons.person_outline,
        const RoleProfilePage(role: 'HUB_ADMIN'),
      ),
    ];
  }

  void _select(int index) {
    if (!mounted || index == _index) return;
    setState(() {
      _index = index;
      if (widget.role == 'NGO') {
        _ngoTabRefreshSignals[index]++;
      } else if (widget.role == 'DONOR') {
        if (_donorTabVisited[index]) {
          _donorTabRefreshSignals[index]++;
        } else {
          _donorTabVisited[index] = true;
        }
      }
    });
  }

  Widget _ngoTab(int index) {
    final signal = _ngoTabRefreshSignals[index];
    return switch (index) {
      0 => NgoHomePage(refreshSignal: signal),
      1 => EligibleListingsPage(refreshSignal: signal),
      2 => MyClaimsPage(refreshSignal: signal),
      3 => NgoPickupsPage(refreshSignal: signal),
      _ => RoleProfilePage(role: 'NGO', refreshSignal: signal),
    };
  }

  Widget _donorTab(int index) {
    final signal = _donorTabRefreshSignals[index];
    return switch (index) {
      0 => DonorHomePage(refreshSignal: signal, onDonations: () => _select(1)),
      1 => DonorMyDonationsPage(refreshSignal: signal),
      2 => const DonorImpactPage(),
      _ => const RoleProfilePage(role: 'DONOR'),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_dashboardDb.auth.currentUser?.id != widget.userId) {
      return const Scaffold(
        body: Center(child: Text('Account changed. Please wait…')),
      );
    }
    if (widget.role == 'HUB_ADMIN') return const HubAdminHomePage();
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index != 0) _select(0);
      },
      child: Scaffold(
        backgroundColor: _mint,
        body: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: _index,
            children: [
              for (var index = 0; index < _tabs.length; index++)
                if (widget.role == 'NGO')
                  _ngoTab(index)
                else if (widget.role == 'DONOR')
                  _donorTab(index)
                else
                  _tabs[index].page,
            ],
          ),
        ),
        bottomNavigationBar: RoleNavigationBar(
          role: widget.role,
          selectedIndex: _index,
          onDestinationSelected: _select,
        ),
      ),
    );
  }
}

class RoleNavigationBar extends StatelessWidget {
  final String role;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  const RoleNavigationBar({
    super.key,
    required this.role,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.badges = const {},
  });

  final Map<int, int> badges;

  static List<String> labelsForRole(String role) => switch (role) {
    'DONOR' => const ['Home', 'Donations', 'Impact', 'Profile'],
    'NGO' => const ['Home', 'Discover', 'My Claims', 'Pickups', 'Profile'],
    _ => const ['Home', 'Drop-offs', 'Inventory', 'Listings', 'Profile'],
  };

  static List<IconData> iconsForRole(String role) => switch (role) {
    'DONOR' => const [
      Icons.home_outlined,
      Icons.volunteer_activism_outlined,
      Icons.insights_outlined,
      Icons.person_outline,
    ],
    'NGO' => const [
      Icons.home_outlined,
      Icons.search,
      Icons.assignment_outlined,
      Icons.local_shipping_outlined,
      Icons.person_outline,
    ],
    _ => const [
      Icons.home_outlined,
      Icons.move_to_inbox_outlined,
      Icons.inventory_2_outlined,
      Icons.campaign_outlined,
      Icons.person_outline,
    ],
  };

  @override
  Widget build(BuildContext context) {
    final labels = labelsForRole(role);
    final icons = iconsForRole(role);
    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      destinations: [
        for (var i = 0; i < labels.length; i++)
          NavigationDestination(
            icon: Badge(
              isLabelVisible: (badges[i] ?? 0) > 0,
              label: Text('${badges[i]}'),
              child: Icon(icons[i]),
            ),
            label: labels[i],
          ),
      ],
    );
  }
}

class _RoleTab {
  final String label;
  final IconData icon;
  final Widget page;
  const _RoleTab(this.label, this.icon, this.page);
}

class DonorHomePage extends StatefulWidget {
  final VoidCallback onDonations;
  final int refreshSignal;
  final Future<List<Map<String, dynamic>>> Function()? donationsLoader;
  final Future<Map<String, dynamic>?> Function()? profileLoader;
  const DonorHomePage({
    super.key,
    required this.onDonations,
    this.refreshSignal = 0,
    this.donationsLoader,
    this.profileLoader,
  });

  @override
  State<DonorHomePage> createState() => _DonorHomePageState();
}

class _DonorHomePageState extends State<DonorHomePage> {
  late Future<List<Map<String, dynamic>>> _donations = _loadDonations();
  late Future<Map<String, dynamic>?> _profile = _loadProfile();

  @override
  void didUpdateWidget(covariant DonorHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) _refresh();
  }

  Future<List<Map<String, dynamic>>> _loadDonations() async {
    if (widget.donationsLoader != null) return widget.donationsLoader!();
    final response = await _dashboardDb.rpc('get_my_donation_dashboard_v2');
    if (response is! List) {
      throw const FormatException(
        'Donation dashboard RPC returned an invalid response.',
      );
    }
    final donations = response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
    if (kDebugMode) {
      debugPrint(
        '[GeoLock photo] donor dashboard returned ${donations.length} donation(s)',
      );
      for (var index = 0; index < donations.length; index++) {
        final path = donations[index]['primary_image_path']?.toString();
        debugPrint(
          '[GeoLock photo] donor dashboard donation #${index + 1}: '
          'primary_image_path_present=${path?.isNotEmpty == true}',
        );
      }
    }
    return donations;
  }

  Future<Map<String, dynamic>?> _loadProfile() async {
    if (widget.profileLoader != null) return widget.profileLoader!();
    final response = await _dashboardDb.rpc('get_my_profile');
    if (response == null) return null;
    if (response is! Map) {
      throw const FormatException('Profile RPC returned an invalid response.');
    }
    return Map<String, dynamic>.from(response);
  }

  Future<void> _refresh() async {
    final donations = _loadDonations();
    final profile = _loadProfile();
    setState(() {
      _donations = donations;
      _profile = profile;
    });
    await Future.wait([donations, profile]);
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _refresh,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        const GeoLockHeader(),
        const SizedBox(height: 22),
        FutureBuilder<Map<String, dynamic>?>(
          future: _profile,
          builder: (context, snapshot) {
            final name = snapshot.data?['full_name']?.toString().trim();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Good ${_greeting()}, ${name == null || name.isEmpty ? 'there' : name.split(' ').first}',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 4),
                const Text('Ready to give something a new home?'),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _donations,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return DashboardErrorCard(
                message:
                    'Donor dashboard data is unavailable. The secure dashboard read RPC may not be deployed yet.\n${snapshot.error}',
                onRetry: () => setState(() => _donations = _loadDonations()),
              );
            }
            if (!snapshot.hasData) {
              return const DashboardLoadingCard(height: 122);
            }
            final rows = snapshot.data!;
            final active = rows
                .where((d) => _active(d['donation_status']?.toString()))
                .length;
            final awaiting = rows
                .where(
                  (d) =>
                      d['donation_status'] == 'HUB_ASSIGNED' &&
                      d['reservation_effective_status'] == 'ACTIVE',
                )
                .length;
            final completed = rows
                .where((d) => d['donation_status'] == 'COLLECTED')
                .length;
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DashboardStatCard(
                        label: 'Active donations',
                        value: '$active',
                        icon: Icons.inventory_2_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DashboardStatCard(
                        label: 'Awaiting drop-off',
                        value: '$awaiting',
                        icon: Icons.local_shipping_outlined,
                        tint: const Color(0xffe9f3fb),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DashboardStatCard(
                  label: 'Collected',
                  value: '$completed',
                  icon: Icons.check_circle_outline,
                  wide: true,
                ),
                const SizedBox(height: 16),
                _CreateDonationBanner(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const CreateDonationPage(),
                    ),
                  ).then((_) => _refresh()),
                ),
                const SizedBox(height: 22),
                SectionHeading(
                  title: 'Recent donations',
                  action: 'View all',
                  onAction: widget.onDonations,
                ),
                if (rows.isEmpty)
                  EmptyStateCard(
                    icon: Icons.volunteer_activism_outlined,
                    title: 'Your first donation starts here',
                    message: 'Share useful items with people nearby.',
                    actionLabel: 'Create donation',
                    onAction: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CreateDonationPage(),
                      ),
                    ).then((_) => _refresh()),
                  )
                else
                  ...rows
                      .take(4)
                      .map(
                        (d) => DonationSummaryCard(
                          donation: d,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DonationDetailPage(
                                donationId: d['donation_id'].toString(),
                              ),
                            ),
                          ).then((_) => _refresh()),
                        ),
                      ),
              ],
            );
          },
        ),
      ],
    ),
  );
}

String _greeting() {
  final hour = DateTime.now().hour;
  if (hour < 12) return 'morning';
  if (hour < 17) return 'afternoon';
  return 'evening';
}

bool _active(String? s) => const {
  'SUBMITTED',
  'AVAILABLE',
  'CLAIMED',
  // Keep legacy rows visible until the forward migration converts them.
  'VALIDATED',
  'READY_FOR_PICKUP',
  'HUB_ASSIGNED',
  'AT_HUB',
  'BATCHED',
  'PICKUP_IN_PROGRESS',
}.contains(s);

class DonorMyDonationsPage extends StatefulWidget {
  final int refreshSignal;
  final Future<List<Map<String, dynamic>>> Function()? donationsLoader;
  const DonorMyDonationsPage({
    super.key,
    this.refreshSignal = 0,
    this.donationsLoader,
  });
  @override
  State<DonorMyDonationsPage> createState() => _DonorMyDonationsPageState();
}

class _DonorMyDonationsPageState extends State<DonorMyDonationsPage> {
  late Future<List<Map<String, dynamic>>> _data = _load();
  final _search = TextEditingController();
  String _filter = 'All';
  static const _filters = [
    'All',
    'Active',
    'At Hub',
    'Claimed',
    'Picked Up',
    'Completed',
    'Cancelled',
  ];

  @override
  void didUpdateWidget(covariant DonorMyDonationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      setState(() {
        _data = _load();
      });
    }
  }

  Future<List<Map<String, dynamic>>> _load() async {
    if (widget.donationsLoader != null) return widget.donationsLoader!();
    final response = await _dashboardDb.rpc('get_my_donation_dashboard_v2');
    if (response is! List) {
      throw const FormatException(
        'Donation dashboard RPC returned an invalid response.',
      );
    }
    return response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  bool _matches(Map<String, dynamic> d) {
    final status = d['donation_status']?.toString();
    final query = _search.text.trim().toLowerCase();
    if (query.isNotEmpty &&
        !d['title'].toString().toLowerCase().contains(query)) {
      return false;
    }
    return switch (_filter) {
      'Active' => _active(status),
      'At Hub' => status == 'AT_HUB' || status == 'BATCHED',
      'Claimed' => status == 'CLAIMED',
      'Picked Up' => status == 'PICKUP_IN_PROGRESS' || status == 'COLLECTED',
      'Completed' => status == 'COLLECTED',
      'Cancelled' => status == 'CANCELLED',
      _ => true,
    };
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const GeoLockHeader(compact: true),
            const SizedBox(height: 14),
            Text(
              'My Donations',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search donations…',
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final filter in _filters)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(filter),
                        selected: filter == _filter,
                        onSelected: (_) => setState(() => _filter = filter),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _data,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return DashboardErrorCard(
                message:
                    'Donation history is unavailable. Deploy the reviewed donor read RPC before using this screen.\\n${snapshot.error}',
                onRetry: () => setState(() => _data = _load()),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final rows = snapshot.data!.where(_matches).toList();
            if (rows.isEmpty) {
              final noDonations = snapshot.data!.isEmpty;
              return EmptyStateCard(
                icon: Icons.inbox_outlined,
                title: noDonations
                    ? 'No donations yet'
                    : 'No matching donations',
                message: noDonations
                    ? 'Create a donation to see its progress here.'
                    : 'Try another search or status filter.',
                actionLabel: noDonations ? 'Create donation' : null,
                onAction: noDonations
                    ? () =>
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const CreateDonationPage(),
                            ),
                          ).then((_) {
                            if (mounted) setState(() => _data = _load());
                          })
                    : null,
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                setState(() => _data = _load());
                await _data;
              },
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 104),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final donation = rows[index];
                  return DonationSummaryCard(
                    donation: donation,
                    onTap: () =>
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DonationDetailPage(
                              donationId: donation['donation_id'].toString(),
                            ),
                          ),
                        ).then((_) {
                          if (mounted) setState(() => _data = _load());
                        }),
                  );
                },
              ),
            );
          },
        ),
      ),
      Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 18, 14),
          child: FloatingActionButton.extended(
            onPressed: () =>
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateDonationPage()),
                ).then((_) {
                  if (mounted) setState(() => _data = _load());
                }),
            icon: const Icon(Icons.add),
            label: const Text('Create donation'),
          ),
        ),
      ),
    ],
  );
}

class NgoHomePage extends StatefulWidget {
  final int refreshSignal;
  final Future<Object?> Function()? listingsLoader;
  final Future<Object?> Function()? claimsLoader;
  final Future<bool> Function()? routingLoader;
  final Future<String?> Function()? ngoNameLoader;

  const NgoHomePage({
    super.key,
    this.refreshSignal = 0,
    this.listingsLoader,
    this.claimsLoader,
    this.routingLoader,
    this.ngoNameLoader,
  });
  @override
  State<NgoHomePage> createState() => _NgoHomePageState();
}

class _NgoHomePageState extends State<NgoHomePage> with WidgetsBindingObserver {
  bool _listingDetailOpen = false;
  final _listingsGate = AsyncRequestGate();
  late final ClaimCardsController _claimReader;
  late Future<void> _claimsRefresh;
  StreamSubscription<AuthState>? _authSubscription;
  final _routingGate = AsyncRequestGate();
  final _nameGate = AsyncRequestGate();
  late Future<List<Map<String, dynamic>>> _listings;
  late Future<bool> _trustedRouting;
  late Future<String?> _ngoName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _claimReader = ClaimCardsController(
      load: () =>
          widget.claimsLoader?.call() ??
          _dashboardDb.rpc('get_my_claim_cards_v2'),
      identity: () => widget.claimsLoader != null
          ? 'injected'
          : _dashboardDb.auth.currentUser?.id,
    );
    if (widget.claimsLoader == null) {
      _authSubscription = _dashboardDb.auth.onAuthStateChange.listen(
        (_) => _refresh(),
      );
    }
    _assignRefreshFutures();
  }

  @override
  void didUpdateWidget(covariant NgoHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    } else {
      _claimReader.invalidate();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    _claimReader.dispose();
    super.dispose();
  }

  void _assignRefreshFutures() {
    _listings = _listingsGate.run(_loadListings);
    _claimsRefresh = _claimReader.refresh();
    _trustedRouting = _routingGate.run(_loadTrustedRouting);
    _ngoName = _nameGate.run(_loadNgoName);
  }

  void _refresh() {
    _assignRefreshFutures();
    if (mounted) setState(() {});
  }

  Future<void> _refreshAndWait() async {
    _refresh();
    await Future.wait([_listings, _claimsRefresh, _trustedRouting, _ngoName]);
  }

  Future<String?> _loadNgoName() async {
    final profile = widget.ngoNameLoader == null
        ? await _dashboardDb.rpc('get_my_profile')
        : await widget.ngoNameLoader!();
    return profile is Map ? profile['ngo_name']?.toString() : null;
  }

  Future<List<Map<String, dynamic>>> _loadListings() async {
    // The card RPC returns the fields rendered by ListingPreviewCard. The
    // legacy discover_eligible_listings RPC omits titles, images and routing
    // readiness, so using it here produced incomplete dashboard cards.
    final rows = widget.listingsLoader == null
        ? await _dashboardDb.rpc('discover_eligible_listing_cards')
        : await widget.listingsLoader!();
    if (rows is! List) {
      throw const FormatException(
        'Listing discovery returned an invalid response.',
      );
    }
    return rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
  }

  Future<bool> _loadTrustedRouting() async {
    if (widget.routingLoader != null) return widget.routingLoader!();
    try {
      final result = await _dashboardDb.rpc('geolock_app_capabilities');
      return result is Map && result['road_node_resolution'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _refreshAndWait,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        const GeoLockHeader(),
        const SizedBox(height: 22),
        FutureBuilder<String?>(
          future: _ngoName,
          builder: (context, snapshot) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                snapshot.data?.isNotEmpty == true
                    ? snapshot.data!
                    : 'NGO workspace',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: _claimReader,
          builder: (context, _) => FutureBuilder<List<Map<String, dynamic>>>(
            future: _listings,
            builder: (context, l) {
              if (_claimReader.error != null || l.hasError) {
                return DashboardErrorCard(
                  message:
                      'NGO counts require the secure claim-history read RPC and eligible-listing discovery.\n${_claimReader.error ?? l.error}',
                  onRetry: _refresh,
                );
              }
              if (_claimReader.loading ||
                  l.connectionState != ConnectionState.done ||
                  !l.hasData) {
                return const DashboardLoadingCard(height: 116);
              }
              final active = _claimReader.fresh
                  ? _claimReader.cards.where((c) => c.isValidActive).length
                  : 0;
              final pickups = active;
              return Row(
                children: [
                  Expanded(
                    child: DashboardStatCard(
                      label: 'Discovery results',
                      value: '${l.data!.length}',
                      icon: Icons.search,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DashboardStatCard(
                      label: 'Active claims',
                      value: '$active',
                      icon: Icons.assignment_outlined,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DashboardStatCard(
                      label: 'Pickups to action',
                      value: '$pickups',
                      icon: Icons.local_shipping_outlined,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        FutureBuilder<bool>(
          future: _trustedRouting,
          builder: (context, route) {
            // The positive capability notice is informational. Keep the real
            // unavailable condition without treating pending reads as failure.
            if (route.connectionState != ConnectionState.done ||
                route.data == true) {
              return const SizedBox.shrink();
            }
            return const Card(
              color: Color(0xfffff5df),
              child: ListTile(
                leading: Icon(Icons.route_outlined, color: _green),
                title: Text('Claiming is unavailable'),
                subtitle: Text(
                  'An approved operational road graph is not confirmed. Discovery results are not presented as claimable.',
                ),
              ),
            );
          },
        ),
        SectionHeading(
          title: 'Recommended listings',
          action: 'Browse all',
          onAction: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const EligibleListingsPage()),
          ),
        ),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _listings,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return DashboardErrorCard(
                message: 'Eligible listings unavailable: ${snapshot.error}',
                onRetry: _refresh,
              );
            }
            if (snapshot.connectionState != ConnectionState.done ||
                !snapshot.hasData) {
              return const DashboardLoadingCard(height: 96);
            }
            if (snapshot.data!.isEmpty) {
              return const EmptyStateCard(
                icon: Icons.search_off,
                title: 'No eligible listings returned',
                message:
                    'Listings depend on a verified NGO location and current backend eligibility.',
              );
            }
            return Column(
              children: [
                for (final row in snapshot.data!.take(3))
                  ListingPreviewCard(
                    row: row,
                    onTap: () async {
                      if (_listingDetailOpen) return;
                      _listingDetailOpen = true;
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NgoListingDetailsPage(
                            listing: row,
                            onClaimConfirmed: () {
                              if (mounted) _refresh();
                            },
                          ),
                        ),
                      );
                      if (mounted) {
                        _refresh();
                        _listingDetailOpen = false;
                      }
                    },
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );
}

class HubAdminHomePage extends StatefulWidget {
  const HubAdminHomePage({super.key});

  @override
  State<HubAdminHomePage> createState() => _HubAdminHomePageState();
}

class _HubAdminHomePageState extends State<HubAdminHomePage> {
  late Future<List<HubSummary>> _hubs = HubService.myHubs();
  HubAdminController? _controller;
  HubAdminTab _tab = HubAdminTab.dashboard;
  Timer? _bellTimer;

  @override
  void dispose() {
    _bellTimer?.cancel();
    _controller?.attachTabOpener(null);
    _controller?.dispose();
    super.dispose();
  }

  void _reloadHub() => setState(() => _hubs = HubService.myHubs());

  HubAdminController _controllerFor(HubSummary hub) {
    final c = _controller;
    if (c != null) {
      c.hub = hub;
      return c;
    }
    final created = HubAdminController(hub)
      ..attachTabOpener((tab) {
        if (mounted) setState(() => _tab = tab);
      });
    _controller = created;
    _bellTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _checkBell(),
    );
    scheduleMicrotask(_checkBell);
    return created;
  }

  Future<void> _checkBell() async {
    final c = _controller;
    if (c == null || !mounted) return;
    try {
      final items = await HubService.activity(c.hubId, limit: 60);
      c.unreadCount = await HubNotificationStore.unreadCount(c.hubId, items);
    } catch (_) {
      // Each page shows its own errors.
    }
  }

  Future<void> _open(Widget page) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
    if (!mounted) return;
    if (changed == true) _reloadHub();
    _controller?.dataChanged();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<HubSummary>>(
    future: _hubs,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          body: SafeArea(
            child: HubErrorState(error: snapshot.error!, onRetry: _reloadHub),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final hubs = snapshot.data!;
      if (hubs.isEmpty) {
        return hub_auth.HubRegistrationPage(onRegistered: _reloadHub);
      }
      final c = _controllerFor(hubs.first);
      return ListenableBuilder(
        listenable: c,
        builder: (context, _) => _home(c),
      );
    },
  );

  Widget _home(HubAdminController c) {
    final onProfile = _tab == HubAdminTab.profile;
    return PopScope(
      canPop: _tab == HubAdminTab.dashboard,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = HubAdminTab.dashboard);
      },
      child: Scaffold(
        backgroundColor: _mint,
        appBar: onProfile
            ? null
            : AppBar(
                backgroundColor: _mint,
                surfaceTintColor: Colors.transparent,
                title: Text(
                  c.hub.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                actions: [
                  IconButton(
                    tooltip: 'Notifications',
                    onPressed: () => _open(HubNotificationPage(controller: c)),
                    icon: Badge(
                      isLabelVisible: c.unreadCount > 0,
                      label: Text(
                        c.unreadCount > 99 ? '99+' : '${c.unreadCount}',
                      ),
                      child: const Icon(Icons.notifications_none),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Categories, hours & storage',
                    onPressed: () => _open(HubServiceRulesPage(hub: c.hub)),
                    icon: const Icon(Icons.tune),
                  ),
                ],
              ),
        body: SafeArea(
          top: onProfile,
          bottom: false,
          child: IndexedStack(
            index: _tab.index,
            children: [
              HubDashboardPage(controller: c),
              HubDropOffPage(controller: c),
              HubInventoryManagePage(controller: c),
              HubListingPage(controller: c),
              RoleProfilePage(role: 'HUB_ADMIN', onHubChanged: _reloadHub),
            ],
          ),
        ),
        bottomNavigationBar: RoleNavigationBar(
          role: 'HUB_ADMIN',
          selectedIndex: _tab.index,
          onDestinationSelected: (i) =>
              setState(() => _tab = HubAdminTab.values[i]),
          badges: {HubAdminTab.dropOffs.index: c.awaitingCount},
        ),
      ),
    );
  }
}

// Hub admin dashboard tab: capacity, tasks waiting, hub flow and latest notifications.

const _batchMinimum = 3;

class _DashboardData {
  final HubDashboard dashboard;
  final HubServiceRules rules;
  final List<HubDropOff> dropOffs;
  final List<HubStoredDonation> inventory;
  final List<HubBatchListing> listings;
  final List<HubActivity> activity;
  final HubAdminStatus adminStatus;

  _DashboardData(
    this.adminStatus,
    this.dashboard,
    this.rules,
    this.dropOffs,
    this.inventory,
    this.listings,
    this.activity,
  );
}

class HubDashboardPage extends StatefulWidget {
  final HubAdminController controller;
  const HubDashboardPage({super.key, required this.controller});

  @override
  State<HubDashboardPage> createState() => _HubDashboardPageState();
}

class _HubDashboardPageState extends State<HubDashboardPage>
    with HubReloadOnChange {
  late Future<_DashboardData> _data;

  HubAdminController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    hubNeedsReload(_c);
    _data = _load();
    _c.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (hubNeedsReload(_c) && mounted) setState(() => _data = _load());
  }

  Future<_DashboardData> _load() async {
    final id = _c.hubId;
    final r = await Future.wait<Object>([
      HubService.adminStatus(),
      HubService.dashboard(id),
      HubService.serviceRules(id),
      HubService.dropOffs(id),
      HubService.inventory(id),
      HubService.listings(id),
      HubService.activity(id, limit: 4),
    ]);
    final data = _DashboardData(
      r[0] as HubAdminStatus,
      r[1] as HubDashboard,
      r[2] as HubServiceRules,
      r[3] as List<HubDropOff>,
      r[4] as List<HubStoredDonation>,
      r[5] as List<HubBatchListing>,
      r[6] as List<HubActivity>,
    );
    _c.awaitingCount = data.dropOffs.where((d) => d.awaiting).length;
    return data;
  }

  Future<void> _refresh() async {
    setState(() => _data = _load());
    await _data;
  }

  Future<void> _openRules() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => HubServiceRulesPage(hub: _c.hub)),
    );
    if (saved == true) _c.dataChanged();
  }

  @override
  Widget build(BuildContext context) => HubRefreshList<_DashboardData>(
    future: _data,
    onRefresh: _refresh,
    builder: (context, d) => [
      hub_auth.HubAdminStatusCard(
        status: d.adminStatus,
        onChanged: _c.dataChanged,
      ),
      _HubHeaderCard(hub: _c.hub, data: d, onEditRules: _openRules),
      if (!d.rules.ready) _SetupCard(onSetup: _openRules),
      HubSectionTitle('To do', subtitle: _todoSubtitle(d)),
      ..._todoTiles(d),
      const HubSectionTitle(
        'Hub flow',
        subtitle: 'Where the donations are now',
      ),
      _FlowCard(data: d),
      HubSectionTitle(
        'Latest notifications',
        action: 'See all',
        onAction: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => HubNotificationPage(controller: _c),
          ),
        ),
      ),
      if (d.activity.isEmpty)
        const HubCard(child: Text('Nothing has happened at this hub yet.')),
      for (final a in d.activity) _MiniActivity(activity: a),
    ],
  );

  String _todoSubtitle(_DashboardData d) {
    final n = _todoTiles(d).whereType<_TaskTile>().length;
    return n == 0
        ? 'All caught up'
        : '$n ${n == 1 ? 'thing needs' : 'things need'} you';
  }

  List<Widget> _todoTiles(_DashboardData d) {
    final tiles = <Widget>[];
    final awaiting = d.dropOffs.where((r) => r.awaiting).toList();
    if (awaiting.isNotEmpty) {
      // Donors book a day and come any time the hub is open that day.
      final today = awaiting.where((r) => r.dropOffDay == hubToday()).toList();
      final later = awaiting.length - today.length;
      final next = today.isEmpty ? awaiting.first : today.first;
      final nextDay = next.dropOffDay;
      tiles.add(
        _TaskTile(
          icon: Icons.directions_walk,
          color: HubColors.blue,
          title: today.isNotEmpty
              ? '${today.length} ${today.length == 1 ? 'donor is' : 'donors are'} coming today'
              : '$later ${later == 1 ? 'donor has' : 'donors have'} booked a later day',
          subtitle: today.isNotEmpty
              ? 'Next: ${next.title} ┬╖ ref ${next.referenceCode}'
                    '${later > 0 ? ' ┬╖ $later more on later days' : ''}'
              : 'Next: ${next.title} ┬╖ ${nextDay == null ? '' : hubDayLabel(nextDay)}',
          onTap: () => _c.openTab(HubAdminTab.dropOffs),
        ),
      );
    }

    final handover = d.listings.where((l) => l.handoverCaseOpen).toList();
    if (handover.isNotEmpty) {
      tiles.add(
        _TaskTile(
          icon: Icons.help_outline,
          color: HubColors.amber,
          title:
              'Confirm ${handover.length} handover${handover.length == 1 ? '' : 's'}',
          subtitle: 'Tell us whether the NGO collected the batch',
          onTap: () => _c.openTab(HubAdminTab.listings),
        ),
      );
    }

    final coming = d.listings
        .where(
          (l) =>
              l.stage == HubListingStage.claimed ||
              l.stage == HubListingStage.pickupInProgress,
        )
        .toList();
    if (coming.isNotEmpty) {
      final onTheWay = coming.where(
        (l) => l.stage == HubListingStage.pickupInProgress,
      );
      tiles.add(
        _TaskTile(
          icon: Icons.local_shipping_outlined,
          color: HubColors.blue,
          title: onTheWay.isNotEmpty
              ? '${onTheWay.first.ngoName ?? 'An NGO'} is on the way'
              : '${coming.length} claimed batch${coming.length == 1 ? '' : 'es'} to hand over',
          subtitle: 'Have the batch ready for the NGO',
          onTap: () => _c.openTab(HubAdminTab.listings),
        ),
      );
    }

    final byCategory = <String, List<HubStoredDonation>>{};
    for (final r in d.inventory.where((r) => r.stored && r.singleCategory)) {
      byCategory.putIfAbsent(r.categoryName, () => []).add(r);
    }
    for (final entry in byCategory.entries) {
      if (entry.value.length < _batchMinimum) continue;
      final kg = entry.value.fold<double>(0, (s, r) => s + r.weightKg);
      tiles.add(
        _TaskTile(
          icon: Icons.playlist_add_check,
          color: HubColors.green,
          title: '${entry.key}: ready to batch',
          subtitle: '${entry.value.length} stored donations ┬╖ ${hubKg(kg)}',
          onTap: () =>
              _c.openTab(HubAdminTab.inventory, inventoryCategory: entry.key),
        ),
      );
    }

    final old = d.inventory
        .where((r) => r.stored && r.waitingMinutes >= hubLongWaitMinutes)
        .length;
    if (old > 0) {
      tiles.add(
        _TaskTile(
          icon: Icons.hourglass_bottom,
          color: HubColors.amber,
          title: '$old donation${old == 1 ? '' : 's'} waiting 3+ days',
          subtitle: 'Add them to the next batch',
          onTap: () => _c.openTab(HubAdminTab.inventory),
        ),
      );
    }

    if (tiles.isEmpty) {
      tiles.add(
        const HubCard(
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, color: HubColors.green),
              SizedBox(width: 10),
              Expanded(
                child: Text('Nothing waiting. New bookings will show here.'),
              ),
            ],
          ),
        ),
      );
    }
    return tiles;
  }
}

class _HubHeaderCard extends StatelessWidget {
  final HubSummary hub;
  final _DashboardData data;
  final VoidCallback onEditRules;

  const _HubHeaderCard({
    required this.hub,
    required this.data,
    required this.onEditRules,
  });

  @override
  Widget build(BuildContext context) {
    final hours = data.rules.hours;
    final open = data.rules.ready && hours.isOpenNow;
    final verified = data.adminStatus.verified;
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  hub.address,
                  style: const TextStyle(color: HubColors.muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              HubStatusChip(
                !verified
                    ? 'Setup needed'
                    : !hub.active
                    ? 'Inactive'
                    : open
                    ? 'Open now'
                    : 'Closed now',
                color: !verified
                    ? HubColors.amber
                    : open
                    ? HubColors.green
                    : HubColors.muted,
                icon: verified ? Icons.circle : Icons.hourglass_top,
              ),
            ],
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: onEditRules,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.schedule, size: 16, color: HubColors.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      data.rules.ready
                          ? 'Today ${hours.todayText} ┬╖ accepts ${data.rules.acceptedNames.join(', ')}'
                          : 'Opening hours and categories not set',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: HubColors.muted,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          HubCapacityBar(
            usedKg: data.dashboard.committedKg,
            capacityKg: data.dashboard.capacityKg,
          ),
          const SizedBox(height: 6),
          const Text(
            'Used = stored donations + space held for donors on the way.',
            style: TextStyle(fontSize: 12, color: HubColors.muted),
          ),
        ],
      ),
    );
  }
}

class _SetupCard extends StatelessWidget {
  final VoidCallback onSetup;
  const _SetupCard({required this.onSetup});

  @override
  Widget build(BuildContext context) => HubCard(
    color: const Color(0xfffff8e8),
    borderColor: HubColors.amber.withValues(alpha: .5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.storefront_outlined, color: HubColors.amber),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Finish setting up your hub',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Donors cannot choose this hub until you set the categories you accept '
          'and your opening hours.',
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: onSetup,
          child: const Text('Set categories & hours'),
        ),
      ],
    ),
  );
}

class _TaskTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _TaskTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => HubCard(
    onTap: onTap,
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(
                subtitle,
                style: const TextStyle(color: HubColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
        const Icon(Icons.chevron_right, color: HubColors.muted),
      ],
    ),
  );
}

class _FlowCard extends StatelessWidget {
  final _DashboardData data;
  const _FlowCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final monthAgo = DateTime.now().subtract(const Duration(days: 30));
    final steps = <(String, int, IconData)>[
      (
        'Booked',
        data.dropOffs.where((r) => r.awaiting).length,
        Icons.event_available_outlined,
      ),
      (
        'Stored',
        data.inventory.where((r) => r.stored).length,
        Icons.inventory_2_outlined,
      ),
      (
        'Listed',
        data.listings
            .where((l) => l.stage == HubListingStage.waitingForNgo)
            .length,
        Icons.campaign_outlined,
      ),
      (
        'Claimed',
        data.listings
            .where(
              (l) =>
                  l.stage == HubListingStage.claimed ||
                  l.stage == HubListingStage.pickupInProgress ||
                  l.stage == HubListingStage.handoverReview,
            )
            .length,
        Icons.assignment_turned_in_outlined,
      ),
      (
        'Collected',
        data.listings
            .where(
              (l) =>
                  l.stage == HubListingStage.collected &&
                  (l.collectedAt == null || l.collectedAt!.isAfter(monthAgo)),
            )
            .length,
        Icons.task_alt,
      ),
    ];
    return HubCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      child: Row(
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            Expanded(
              child: Column(
                children: [
                  Icon(steps[i].$3, color: HubColors.green, size: 22),
                  const SizedBox(height: 4),
                  Text(
                    '${steps[i].$2}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: HubColors.ink,
                    ),
                  ),
                  Text(
                    steps[i].$1,
                    style: const TextStyle(
                      fontSize: 11,
                      color: HubColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (i < steps.length - 1)
              const Icon(Icons.chevron_right, size: 16, color: HubColors.line),
          ],
        ],
      ),
    );
  }
}

class _MiniActivity extends StatelessWidget {
  final HubActivity activity;
  const _MiniActivity({required this.activity});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = hubActivityStyle(activity.type);
    return HubCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activity.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  activity.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: HubColors.muted, fontSize: 13),
                ),
              ],
            ),
          ),
          Text(
            hubAgo(activity.occurredAt),
            style: const TextStyle(color: HubColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

double _number(Object? value) => double.tryParse('$value') ?? 0;

class HubOperationsTab extends StatefulWidget {
  final String section;
  const HubOperationsTab({super.key, required this.section});
  @override
  State<HubOperationsTab> createState() => _HubOperationsTabState();
}

class _HubOperationsTabState extends State<HubOperationsTab> {
  @override
  Widget build(BuildContext context) => FutureBuilder<dynamic>(
    future: _dashboardDb.rpc('get_my_hubs'),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.section)),
          body: DashboardErrorCard(
            message:
                'Hub operations require the authorized hub reads.\n${snapshot.error}',
            onRetry: () => setState(() {}),
          ),
        );
      }
      if (!snapshot.hasData) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.section)),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      final rows = snapshot.data as List;
      if (rows.isEmpty) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.section)),
          body: const EmptyStateCard(
            icon: Icons.home_work_outlined,
            title: 'No managed hub',
            message: 'No community hub is linked to this account yet.',
          ),
        );
      }
      final hub = Map<String, dynamic>.from(rows.first as Map);
      return HubOperationsPage(hub: hub, section: widget.section);
    },
  );
}

class NgoPickupsPage extends StatelessWidget {
  final int refreshSignal;
  final Future<Object?> Function()? claimsLoader;
  const NgoPickupsPage({super.key, this.refreshSignal = 0, this.claimsLoader});
  @override
  Widget build(BuildContext context) => claimsLoader != null
      ? MyClaimsPage(refreshSignal: refreshSignal, claimsLoader: claimsLoader)
      : NgoRoutesPage(refreshSignal: refreshSignal);
}

class DonorImpactPage extends StatefulWidget {
  const DonorImpactPage({super.key});
  @override
  State<DonorImpactPage> createState() => _DonorImpactPageState();
}

class _DonorImpactPageState extends State<DonorImpactPage> {
  late Future<List<Map<String, dynamic>>> _data = _load();
  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await _dashboardDb.rpc('get_my_donation_dashboard_v2');
    if (rows is! List) {
      throw const FormatException(
        'Donor dashboard RPC returned an invalid response.',
      );
    }
    return rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
  }

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          appBar: AppBar(title: const Text('Your Impact')),
          body: DashboardErrorCard(
            message:
                'Impact totals require donor-owned donation history.\n${snapshot.error}',
            onRetry: () => setState(() => _data = _load()),
          ),
        );
      }
      if (!snapshot.hasData) {
        return Scaffold(
          appBar: AppBar(title: const Text('Your Impact')),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      final collected = snapshot.data!
          .where((d) => d['donation_status'] == 'COLLECTED')
          .toList();
      final kg = collected.fold<double>(
        0,
        (sum, d) => sum + _number(d['total_weight_kg']),
      );
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const GeoLockHeader(compact: true),
          const SizedBox(height: 24),
          Text(
            'Your Impact',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          DashboardStatCard(
            label: 'Collected donations',
            value: '${collected.length}',
            icon: Icons.volunteer_activism_outlined,
            wide: true,
          ),
          const SizedBox(height: 10),
          DashboardStatCard(
            label: 'Weight collected',
            value: '${kg.toStringAsFixed(1)} kg',
            icon: Icons.scale_outlined,
            wide: true,
          ),
          const SizedBox(height: 12),
          const Text(
            'These totals reflect donation records marked COLLECTED by the backend. No environmental or beneficiary impact is inferred.',
          ),
        ],
      );
    },
  );
}

class RoleProfilePage extends StatefulWidget {
  final String role;
  final int refreshSignal;
  final Future<Object?> Function()? profileLoader;
  final VoidCallback? onHubChanged;
  const RoleProfilePage({
    super.key,
    required this.role,
    this.refreshSignal = 0,
    this.profileLoader,
    this.onHubChanged,
  });

  @override
  State<RoleProfilePage> createState() => _RoleProfilePageState();
}

class _RoleProfilePageState extends State<RoleProfilePage> {
  final _profileGate = AsyncRequestGate();
  late Future<Map<String, dynamic>> _profile = _profileGate.run(_loadProfile);

  @override
  void didUpdateWidget(covariant RoleProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) _refresh();
  }

  Future<Map<String, dynamic>> _loadProfile() async {
    final userId = _dashboardDb.auth.currentUser?.id;
    if (userId == null) throw StateError('Your session has ended.');
    final response = widget.profileLoader == null
        ? await _dashboardDb.rpc('get_my_profile')
        : await widget.profileLoader!();
    if (_dashboardDb.auth.currentUser?.id != userId) {
      throw StateError('Account changed while the profile was loading.');
    }
    if (response is! Map) {
      throw const FormatException('Profile information is unavailable.');
    }
    final profile = Map<String, dynamic>.from(response);
    final result = <String, dynamic>{'profile': profile};
    if (widget.role == 'HUB_ADMIN') {
      try {
        final hubResponse = await _dashboardDb.rpc('get_my_hubs');
        if (hubResponse is! List) {
          throw const FormatException('Hub list response was invalid.');
        }
        final hubs = hubResponse
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        result['hubs'] = hubs;
        final summaries = <String, Map<String, dynamic>>{};
        for (final hub in hubs) {
          final hubId = hub['hub_id']?.toString();
          if (hubId == null) continue;
          try {
            final summary = await _dashboardDb.rpc(
              'get_hub_dashboard',
              params: {'p_hub': hubId},
            );
            if (summary is Map) {
              summaries[hubId] = Map<String, dynamic>.from(summary);
            }
          } catch (_) {
            // Hub identity and registered capacity remain useful even when
            // the separate authorized availability summary is unavailable.
          }
        }
        result['hub_summaries'] = summaries;
      } catch (error) {
        result['hub_error'] = error;
      }
    }
    if (_dashboardDb.auth.currentUser?.id != userId) {
      throw StateError('Account changed while the profile was loading.');
    }
    return result;
  }

  void _refresh() {
    final refreshed = _profileGate.run(_loadProfile);
    if (mounted) {
      setState(() {
        _profile = refreshed;
      });
    }
  }

  Future<void> _editProfile(Map<String, dynamic> profile) async {
    final name = TextEditingController(text: '${profile['full_name'] ?? ''}');
    final phone = TextEditingController(
      text: '${profile['phone_number'] ?? ''}',
    );
    final ngoName = TextEditingController(text: '${profile['ngo_name'] ?? ''}');
    try {
      final values = await showDialog<List<String>>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Edit profile'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Full name'),
                ),
                TextField(
                  controller: phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                ),
                if (widget.role == 'NGO') ...[
                  TextField(
                    controller: ngoName,
                    decoration: const InputDecoration(labelText: 'NGO name'),
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Email and account role are managed by Supabase Auth and cannot be changed here.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, [
                name.text,
                phone.text,
                ngoName.text,
              ]),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (values == null) return;
      await _dashboardDb.rpc(
        'update_my_profile',
        params: {
          'p_full_name': values[0].trim(),
          'p_phone': values[1].trim().isEmpty ? null : values[1].trim(),
          'p_ngo_name': widget.role == 'NGO' ? values[2].trim() : null,
        },
      );
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) _showProfileError(error);
    } finally {
      name.dispose();
      phone.dispose();
      ngoName.dispose();
    }
  }

  Future<void> _changeNgoLocation(Map<String, dynamic> profile) async {
    final latitude = double.tryParse('${profile['latitude']}');
    final longitude = double.tryParse('${profile['longitude']}');
    final initial = latitude == null || longitude == null
        ? null
        : LocationResult(
            address: '${profile['operating_address'] ?? ''}',
            latitude: latitude,
            longitude: longitude,
            method: LocationSelectionMethod.mapPin,
          );
    final selected = await Navigator.push<LocationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          title: 'NGO Operating Location',
          initialLocation: initial,
          roadAccess: RoadAccessRequirement.required,
          hint:
              'Road access is previewed here and validated again by PostgreSQL before saving.',
        ),
      ),
    );
    if (selected == null) return;
    try {
      await _dashboardDb.rpc(
        'set_ngo_operating_location',
        params: {
          'p_operating_address': selected.address,
          'p_latitude': selected.latitude,
          'p_longitude': selected.longitude,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Location saved. NGO listing eligibility is updating; discovery may take a moment to refresh.',
            ),
          ),
        );
        _refresh();
      }
    } catch (error) {
      if (mounted) _showProfileError(error);
    }
  }

  Future<void> _editHub(Map<String, dynamic> hub) async {
    final name = TextEditingController(text: '${hub['hub_name'] ?? ''}');
    final capacity = TextEditingController(text: '${hub['capacity_kg'] ?? ''}');
    try {
      final values = await showDialog<List<String>>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Edit hub details'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Hub name'),
                ),
                TextField(
                  controller: capacity,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Storage capacity (kg)',
                    helperText: '50ΓÇô250 kg',
                    suffixText: 'kg',
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Capacity can only change while the hub has no stored donations, active drop-offs or open batches.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, [name.text, capacity.text]),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (values == null) return;
      final capacityKg = double.tryParse(values[1].trim());
      if (values[0].trim().isEmpty ||
          capacityKg == null ||
          capacityKg < 50 ||
          capacityKg > 250) {
        throw StateError('Enter a hub name and a capacity from 50 to 250 kg.');
      }
      await _saveHub(hub, name: values[0].trim(), capacityKg: capacityKg);
    } catch (error) {
      if (mounted) _showProfileError(error);
    } finally {
      name.dispose();
      capacity.dispose();
    }
  }

  Future<void> _changeHubLocation(Map<String, dynamic> hub) async {
    final latitude = double.tryParse('${hub['latitude']}');
    final longitude = double.tryParse('${hub['longitude']}');
    final initial = latitude == null || longitude == null
        ? null
        : LocationResult(
            address: '${hub['address_text'] ?? ''}',
            latitude: latitude,
            longitude: longitude,
            method: LocationSelectionMethod.mapPin,
          );
    final selected = await Navigator.push<LocationResult>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            hub_auth.buildHubLocationPicker(initialLocation: initial),
      ),
    );
    if (selected == null) return;
    try {
      await _saveHub(hub, location: selected);
    } catch (error) {
      if (mounted) _showProfileError(error);
    }
  }

  /// Opening hours, accepted categories and storage facilities.
  Future<void> _editServiceRules(Map<String, dynamic> hub) async {
    if (hub['hub_id'] == null) return;
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => HubServiceRulesPage(hub: HubSummary.fromRow(hub)),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hours, categories and storage saved.')),
      );
      _refresh();
      widget.onHubChanged?.call();
    }
  }

  /// update_my_hub takes every field, so unchanged ones are sent as saved.
  Future<void> _saveHub(
    Map<String, dynamic> hub, {
    String? name,
    double? capacityKg,
    LocationResult? location,
  }) async {
    final hubId = hub['hub_id']?.toString();
    final latitude =
        location?.latitude ?? double.tryParse('${hub['latitude']}');
    final longitude =
        location?.longitude ?? double.tryParse('${hub['longitude']}');
    if (hubId == null || latitude == null || longitude == null) {
      throw StateError('Saved hub details are incomplete. Refresh and retry.');
    }
    await HubService.updateHub(
      hubId: hubId,
      name: name ?? '${hub['hub_name'] ?? ''}',
      address: location?.address ?? '${hub['address_text'] ?? ''}',
      latitude: latitude,
      longitude: longitude,
      capacityKg: capacityKg ?? double.tryParse('${hub['capacity_kg']}') ?? 0,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          location == null
              ? 'Hub details saved.'
              : 'Hub location saved and linked to the nearest road.',
        ),
      ),
    );
    _refresh();
    widget.onHubChanged?.call();
  }

  void _showProfileError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Profile change was not confirmed: ${AuthController.message(error)}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: _profile,
    builder: (context, snapshot) {
      final theme = Theme.of(context);
      if (snapshot.hasError) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const GeoLockHeader(compact: true),
            const SizedBox(height: 20),
            Text('Your profile', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            DashboardErrorCard(
              message: 'Profile information could not be loaded.',
              onRetry: _refresh,
            ),
          ],
        );
      }
      if (snapshot.connectionState != ConnectionState.done ||
          !snapshot.hasData) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const GeoLockHeader(compact: true),
            const SizedBox(height: 20),
            Text('Your profile', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            const DashboardLoadingCard(height: 148),
          ],
        );
      }
      final data = snapshot.data!;
      final profile = data['profile'] as Map<String, dynamic>;
      final user = _dashboardDb.auth.currentUser;
      final rawName = profile['full_name']?.toString().trim() ?? '';
      final name = _profileValue(rawName, empty: 'Name unavailable');
      final roleLabel = _profileRoleLabel(
        profile['role']?.toString() ?? widget.role,
      );
      final hubs = (data['hubs'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final summaries =
          (data['hub_summaries'] as Map<String, dynamic>? ?? const {});

      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          const GeoLockHeader(compact: true),
          const SizedBox(height: 18),
          Text(
            'Your profile',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: _ink,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          _ProfileSection(
            child: Row(
              children: [
                CircleAvatar(
                  radius: 31,
                  backgroundColor: const Color(0xffd9efe8),
                  foregroundColor: _green,
                  child: Text(
                    _profileInitials(rawName),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: _ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _ProfileRoleBadge(label: roleLabel),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () => _editProfile(profile),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit profile'),
            ),
          ),
          const SizedBox(height: 16),
          _ProfileSection(
            title: 'Account information',
            icon: Icons.person_outline,
            children: [
              _ProfileField(
                icon: Icons.badge_outlined,
                label: 'Full name',
                value: _profileValue(profile['full_name']),
              ),
              _ProfileField(
                icon: Icons.email_outlined,
                label: 'Email address',
                value: _profileValue(user?.email, empty: 'Not available'),
              ),
              _ProfileField(
                icon: Icons.phone_outlined,
                label: 'Phone number',
                value: _profileValue(
                  profile['phone_number'],
                  empty: 'Not added',
                ),
              ),
              _ProfileField(
                icon: Icons.verified_user_outlined,
                label: 'Account role',
                value: roleLabel,
              ),
              _ProfileField(
                icon: Icons.calendar_today_outlined,
                label: 'Account created',
                value: _profileDate(user?.createdAt),
                isLast: true,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (widget.role == 'NGO')
            _ProfileSection(
              title: 'NGO information',
              icon: Icons.volunteer_activism_outlined,
              children: [
                _ProfileField(
                  icon: Icons.business_outlined,
                  label: 'Organization',
                  value: _profileValue(profile['ngo_name']),
                ),
                _ProfileField(
                  icon: Icons.location_on_outlined,
                  label: 'Operating address',
                  value: _profileValue(profile['operating_address']),
                ),
                _ProfileLocationStatus(
                  status: profile['location_status']?.toString(),
                  verifiedAt: profile['location_verified_at'],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => _changeNgoLocation(profile),
                  icon: const Icon(Icons.location_searching_outlined),
                  label: const Text('Change operating location'),
                ),
              ],
            ),
          if (widget.role == 'HUB_ADMIN') ...[
            _ProfileSection(
              title: 'Assigned hubs',
              icon: Icons.home_work_outlined,
              children: [
                if (data['hub_error'] != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('Assigned hub information is unavailable.'),
                  )
                else if (hubs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('No hub is currently linked to this account.'),
                  )
                else
                  for (var index = 0; index < hubs.length; index++) ...[
                    if (index > 0)
                      const Divider(height: 24, color: Color(0xffe5eee9)),
                    _ProfileHubFields(
                      hub: hubs[index],
                      summary:
                          summaries[hubs[index]['hub_id']?.toString()]
                              as Map<String, dynamic>?,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _editHub(hubs[index]),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit hub details'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _changeHubLocation(hubs[index]),
                          icon: const Icon(Icons.location_searching_outlined),
                          label: const Text('Change hub location'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _editServiceRules(hubs[index]),
                          icon: const Icon(Icons.tune),
                          label: const Text('Hours, categories & storage'),
                        ),
                      ],
                    ),
                  ],
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (widget.role == 'DONOR')
            _ProfileSection(
              title: 'Donor account',
              icon: Icons.volunteer_activism_outlined,
              children: const [
                Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'Pickup details are provided with each donation. Your account does not store a permanent pickup address.',
                  ),
                ),
              ],
            ),
          if (widget.role != 'HUB_ADMIN') const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => signOutAndReset(context),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.error.withValues(alpha: .5),
              ),
            ),
          ),
        ],
      );
    },
  );
}

String _profileRoleLabel(String role) => switch (role) {
  'DONOR' => 'Donor',
  'NGO' => 'NGO Personnel',
  'HUB_ADMIN' => 'Community Hub Admin',
  _ => 'Account',
};

String _profileValue(Object? value, {String empty = 'Not provided'}) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? empty : text;
}

String _profileInitials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty);
  final initials = parts.take(2).map((part) => part[0].toUpperCase()).join();
  return initials.isEmpty ? '?' : initials;
}

String _profileDate(Object? value) {
  final parsed = value == null ? null : DateTime.tryParse(value.toString());
  if (parsed == null) return 'Not available';
  final local = parsed.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year}';
}

class _ProfileSection extends StatelessWidget {
  final String? title;
  final IconData? icon;
  final Widget? child;
  final List<Widget> children;

  const _ProfileSection({
    this.title,
    this.icon,
    this.child,
    this.children = const [],
  });

  @override
  Widget build(BuildContext context) => Card(
    color: Colors.white,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: Color(0xffdfeae4)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Icon(icon, color: _green, size: 20),
                const SizedBox(width: 9),
                Text(
                  title!,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (child != null || children.isNotEmpty)
              const SizedBox(height: 10),
          ],
          ?child,
          ...children,
        ],
      ),
    ),
  );
}

class _ProfileField extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool isLast;

  const _ProfileField({
    required this.icon,
    required this.label,
    required this.value,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: 10, bottom: isLast ? 0 : 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 19, color: const Color(0xff668078)),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: const Color(0xff6b7b75),
                ),
              ),
              const SizedBox(height: 2),
              SelectableText(
                value,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: _ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ProfileRoleBadge extends StatelessWidget {
  final String label;
  const _ProfileRoleBadge({required this.label});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xffe4f3ed),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: Color(0xff216d5a),
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
    ),
  );
}

class _ProfileLocationStatus extends StatelessWidget {
  final String? status;
  final Object? verifiedAt;
  const _ProfileLocationStatus({this.status, this.verifiedAt});

  @override
  Widget build(BuildContext context) {
    final verified = status == 'VERIFIED' || verifiedAt != null;
    final label = verified
        ? 'Road location validated'
        : 'Road location not validated';
    final color = verified ? _green : const Color(0xff98681b);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            verified ? Icons.verified_outlined : Icons.pending_outlined,
            size: 19,
            color: color,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Location verification',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
                const Text(
                  'Confirms road-network access only.',
                  style: TextStyle(fontSize: 12),
                ),
                if (verified && verifiedAt != null)
                  Text(
                    'Validated ${_profileDate(verifiedAt)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileHubFields extends StatelessWidget {
  final Map<String, dynamic> hub;
  final Map<String, dynamic>? summary;
  const _ProfileHubFields({required this.hub, this.summary});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _profileValue(hub['hub_name'], empty: 'Community hub'),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: _ink,
        ),
      ),
      _ProfileField(
        icon: Icons.location_on_outlined,
        label: 'Hub address',
        value: _profileValue(hub['address_text']),
      ),
      _ProfileField(
        icon: Icons.storage_outlined,
        label: 'Registered total capacity',
        value: hub['capacity_kg'] == null
            ? 'Not available'
            : '${hub['capacity_kg']} kg',
      ),
      _ProfileField(
        icon: Icons.inventory_2_outlined,
        label: 'Available capacity',
        value: summary?['available_capacity_kg'] == null
            ? 'Not available from the current hub read'
            : '${summary!['available_capacity_kg']} kg',
        isLast: true,
      ),
    ],
  );
}

class GeoLockHeader extends StatelessWidget {
  final bool compact;
  const GeoLockHeader({super.key, this.compact = false});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: compact ? 32 : 38,
        height: compact ? 32 : 38,
        decoration: BoxDecoration(
          color: const Color(0xffd9efe8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.hub_outlined, color: _green),
      ),
      const SizedBox(width: 9),
      Expanded(
        child: Text(
          'GeoLock Hub',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: _green,
            fontSize: compact ? 15 : 17,
          ),
        ),
      ),
    ],
  );
}

class DashboardStatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? tint;
  final bool wide;
  const DashboardStatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tint,
    this.wide = false,
  });
  @override
  Widget build(BuildContext context) => Card(
    color: tint ?? Colors.white,
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(icon, color: _green),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class SectionHeading extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHeading({
    super.key,
    required this.title,
    this.action,
    this.onAction,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ],
    ),
  );
}

class DonationSummaryCard extends StatelessWidget {
  final Map<String, dynamic> donation;
  final VoidCallback onTap;
  const DonationSummaryCard({
    super.key,
    required this.donation,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DonationImage(
              path: donation['primary_image_path']?.toString(),
              size: 66,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${donation['title'] ?? 'Donation'}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      StatusBadge(
                        status: donationStatusLabel(
                          status: donation['donation_status']?.toString(),
                          collectionPath: donation['collection_path']
                              ?.toString(),
                          reservationStatus:
                              donation['reservation_effective_status']
                                  ?.toString(),
                          inventoryStatus: donation['inventory_status']
                              ?.toString(),
                          listingStatus: donation['listing_status']?.toString(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${donation['item_count'] ?? '—'} items · ${donation['total_weight_kg'] ?? '—'} kg',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    donation['collection_path'] == 'HUB_COLLECTION'
                        ? 'Community Hub Collection'
                        : 'Direct Pickup',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    _date(donation['created_at']),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'View details →',
                    style: TextStyle(
                      color: _green,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

String _date(Object? date) {
  final parsed = DateTime.tryParse('$date');
  return parsed == null
      ? 'Date unavailable'
      : '${parsed.day}/${parsed.month}/${parsed.year}';
}

class StatusBadge extends StatelessWidget {
  final String status;
  const StatusBadge({super.key, required this.status});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: _statusColor(status).withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      status,
      style: TextStyle(
        color: _statusColor(status),
        fontSize: 10,
        fontWeight: FontWeight.w700,
      ),
      maxLines: 1,
    ),
  );
}

Color _statusColor(String value) {
  final s = value.toLowerCase();
  if (s.contains('complete') || s.contains('collected')) {
    return const Color(0xff16745e);
  }
  if (s.contains('cancel')) return const Color(0xffa84a4a);
  if (s.contains('claim') || s.contains('pickup') || s.contains('await')) {
    return const Color(0xff2670a7);
  }
  return _green;
}

class DonationImage extends StatelessWidget {
  final String? path;
  final double size;
  const DonationImage({super.key, required this.path, this.size = 72});
  @override
  Widget build(BuildContext context) {
    if (path == null || path!.isEmpty) return _placeholder();
    return FutureBuilder<String>(
      future: createDonationPhotoSignedUrl(
        _dashboardDb,
        path!,
        surface: 'DonationImage thumbnail',
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.hasError) return _placeholder();
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            snapshot.data!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, error, stackTrace) {
              logDonationPhotoNetworkFailure(
                surface: 'DonationImage thumbnail',
                error: error,
                stackTrace: stackTrace,
              );
              return _placeholder();
            },
          ),
        );
      },
    );
  }

  Widget _placeholder() => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: const Color(0xffe4f2ed),
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Icon(Icons.volunteer_activism_outlined, color: _green),
  );
}

class ListingPreviewCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback? onTap;
  const ListingPreviewCard({super.key, required this.row, this.onTap});
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            DonationImage(
              path: row['primary_image_path']?.toString(),
              size: 58,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${row['title'] ?? (row['source_type'] == 'HUB_BATCH' ? 'Community hub batch' : 'Donation')} · ${row['listing_weight_kg']} kg',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    row['collection_path'] == 'HUB_COLLECTION'
                        ? 'Community Hub Collection'
                        : 'Direct Pickup',
                  ),
                  if (row['distance_m'] != null)
                    Text(
                      '${(_number(row['distance_m']) / 1000).toStringAsFixed(1)} km by road',
                    ),
                  Text(
                    'Routing: ${roadStatusLine(row['routing_status'])}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            if (onTap != null) const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );
}

class EmptyStateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyStateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          Icon(icon, size: 36, color: _green),
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(message, textAlign: TextAlign.center),
          if (actionLabel != null) ...[
            const SizedBox(height: 12),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}

class DashboardErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const DashboardErrorCard({
    super.key,
    required this.message,
    required this.onRetry,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const Icon(Icons.cloud_off_outlined, color: _green),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}

class DashboardLoadingCard extends StatelessWidget {
  final double height;
  const DashboardLoadingCard({super.key, required this.height});
  @override
  Widget build(BuildContext context) => Card(
    child: SizedBox(
      height: height,
      child: const Center(child: CircularProgressIndicator()),
    ),
  );
}

class _CreateDonationBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _CreateDonationBanner({required this.onTap});
  @override
  Widget build(BuildContext context) => Card(
    color: const Color(0xffdff2eb),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const Text(
            'Have something to donate?',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'Every item finds a new purpose. Start your donation journey today.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('Create donation'),
          ),
        ],
      ),
    ),
  );
}
