import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'async_request_gate.dart';
import 'auth/auth_navigation.dart';
import 'auth/auth_controller.dart';
import 'donation_pages.dart';
import 'donation_status.dart';
import 'location/road_routing.dart';
import 'location/location_picker_page.dart';
import 'location/location_result.dart';

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
  late final List<_RoleTab> _tabs = _tabsFor(widget.role);

  List<_RoleTab> _tabsFor(String role) {
    if (role == 'DONOR') {
      return [
        _RoleTab(
          'Home',
          Icons.home_outlined,
          DonorHomePage(onDonations: () => _select(2)),
        ),
        _RoleTab(
          'Map',
          Icons.map_outlined,
          const _UnavailableTab(
            title: 'Donation Map',
            message:
                'A privacy-safe map feed is not available in the deployed V3 RPCs. Your pickup address remains private to your account.',
          ),
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

  @override
  Widget build(BuildContext context) {
    if (_dashboardDb.auth.currentUser?.id != widget.userId) {
      return const Scaffold(
        body: Center(child: Text('Account changed. Please wait…')),
      );
    }
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
                if (widget.role == 'NGO') _ngoTab(index) else _tabs[index].page,
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
  });

  static List<String> labelsForRole(String role) => switch (role) {
    'DONOR' => const ['Home', 'Map', 'Donations', 'Impact', 'Profile'],
    'NGO' => const ['Home', 'Discover', 'My Claims', 'Pickups', 'Profile'],
    _ => const ['Home', 'Inventory', 'Receive', 'Collections', 'Profile'],
  };

  static List<IconData> iconsForRole(String role) => switch (role) {
    'DONOR' => const [
      Icons.home_outlined,
      Icons.map_outlined,
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
      Icons.inventory_2_outlined,
      Icons.move_to_inbox_outlined,
      Icons.local_shipping_outlined,
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
          NavigationDestination(icon: Icon(icons[i]), label: labels[i]),
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
  const DonorHomePage({super.key, required this.onDonations});

  @override
  State<DonorHomePage> createState() => _DonorHomePageState();
}

class _DonorHomePageState extends State<DonorHomePage> {
  late Future<List<Map<String, dynamic>>> _donations = _loadDonations();
  late Future<Map<String, dynamic>?> _profile = _loadProfile();

  Future<List<Map<String, dynamic>>> _loadDonations() async {
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
    final response = await _dashboardDb.rpc('get_my_profile');
    if (response == null) return null;
    if (response is! Map) {
      throw const FormatException('Profile RPC returned an invalid response.');
    }
    return Map<String, dynamic>.from(response);
  }

  Future<void> _refresh() async {
    setState(() {
      _donations = _loadDonations();
      _profile = _loadProfile();
    });
    await Future.wait([_donations, _profile]);
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
  const DonorMyDonationsPage({super.key});
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

  Future<List<Map<String, dynamic>>> _load() async {
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

class _NgoHomePageState extends State<NgoHomePage> {
  final _listingsGate = AsyncRequestGate();
  final _claimsGate = AsyncRequestGate();
  final _routingGate = AsyncRequestGate();
  final _nameGate = AsyncRequestGate();
  late Future<List<Map<String, dynamic>>> _listings;
  late Future<List<Map<String, dynamic>>> _claims;
  late Future<bool> _trustedRouting;
  late Future<String?> _ngoName;

  @override
  void initState() {
    super.initState();
    _assignRefreshFutures();
  }

  @override
  void didUpdateWidget(covariant NgoHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) _refresh();
  }

  void _assignRefreshFutures() {
    _listings = _listingsGate.run(_loadListings);
    _claims = _claimsGate.run(_loadClaims);
    _trustedRouting = _routingGate.run(_loadTrustedRouting);
    _ngoName = _nameGate.run(_loadNgoName);
  }

  void _refresh() {
    _assignRefreshFutures();
    if (mounted) setState(() {});
  }

  Future<void> _refreshAndWait() async {
    _refresh();
    await Future.wait([_listings, _claims, _trustedRouting, _ngoName]);
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

  Future<List<Map<String, dynamic>>> _loadClaims() async {
    final rows = widget.claimsLoader == null
        ? await _dashboardDb.rpc('get_my_claims')
        : await widget.claimsLoader!();
    if (rows is! List) {
      throw const FormatException(
        'Claim history returned an invalid response.',
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
              const Text('Donation coordination overview'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _claims,
          builder: (context, c) => FutureBuilder<List<Map<String, dynamic>>>(
            future: _listings,
            builder: (context, l) {
              if (c.hasError || l.hasError) {
                return DashboardErrorCard(
                  message:
                      'NGO counts require the secure claim-history read RPC and eligible-listing discovery.\n${c.error ?? l.error}',
                  onRetry: _refresh,
                );
              }
              if (c.connectionState != ConnectionState.done ||
                  l.connectionState != ConnectionState.done ||
                  !c.hasData ||
                  !l.hasData) {
                return const DashboardLoadingCard(height: 116);
              }
              final active = c.data!
                  .where((r) => r['claim_status'] == 'ACTIVE')
                  .length;
              final pickups = c.data!
                  .where(
                    (r) =>
                        r['task_status'] == 'CONFIRMED' ||
                        r['task_status'] == 'PLANNED' ||
                        r['task_status'] == 'DISPATCHED',
                  )
                  .length;
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
            final ready = route.data == true;
            return Card(
              color: ready ? Colors.white : const Color(0xfffff5df),
              child: ListTile(
                leading: Icon(
                  ready ? Icons.verified_outlined : Icons.route_outlined,
                  color: _green,
                ),
                title: Text(
                  ready
                      ? 'Trusted route validation configured'
                      : 'Claiming is unavailable',
                ),
                subtitle: Text(
                  ready
                      ? 'The server remains authoritative for every claim.'
                      : 'An approved operational road graph is not confirmed. Discovery results are not presented as claimable.',
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
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => NgoListingDetailsPage(
                          listing: row,
                          onClaimConfirmed: () {
                            if (mounted) _refresh();
                          },
                        ),
                      ),
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

class HubAdminHomePage extends StatefulWidget {
  const HubAdminHomePage({super.key});
  @override
  State<HubAdminHomePage> createState() => _HubAdminHomePageState();
}

class _HubAdminHomePageState extends State<HubAdminHomePage> {
  late Future<List<Map<String, dynamic>>> _hubs = _loadHubs();
  String? _selectedId;
  Future<List<Map<String, dynamic>>> _loadHubs() async {
    final rows = await _dashboardDb.rpc('get_my_hubs');
    if (rows is! List) {
      throw const FormatException(
        'Authorized hub lookup returned an invalid response.',
      );
    }
    final hubs = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
    _selectedId ??= hubs.isEmpty ? null : hubs.first['hub_id'].toString();
    return hubs;
  }

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _hubs,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const GeoLockHeader(),
            const SizedBox(height: 30),
            DashboardErrorCard(
              message:
                  'Hub dashboard data requires authorized hub read RPCs.\n${snapshot.error}',
              onRetry: () => setState(() => _hubs = _loadHubs()),
            ),
          ],
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final hubs = snapshot.data!;
      if (hubs.isEmpty) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const GeoLockHeader(),
            const SizedBox(height: 24),
            const EmptyStateCard(
              icon: Icons.home_work_outlined,
              title: 'No hub is linked to this account',
              message:
                  'Create your community hub here. Its location and capacity are validated by the database before activation.',
            ),
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RegisterHubPage()),
                  ).then((created) {
                    if (created == true) setState(() => _hubs = _loadHubs());
                  }),
              icon: const Icon(Icons.add_business),
              label: const Text('Register Community Hub'),
            ),
          ],
        );
      }
      final selected = hubs.firstWhere(
        (h) => h['hub_id'].toString() == _selectedId,
        orElse: () => hubs.first,
      );
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const GeoLockHeader(),
          const SizedBox(height: 14),
          if (hubs.length > 1)
            DropdownButtonFormField<String>(
              initialValue: selected['hub_id'].toString(),
              decoration: const InputDecoration(labelText: 'Managed hub'),
              items: [
                for (final h in hubs)
                  DropdownMenuItem(
                    value: h['hub_id'].toString(),
                    child: Text(
                      h['hub_name'].toString(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _selectedId = v),
            )
          else
            Text(
              selected['hub_name'].toString(),
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          if (hubs.length > 1) Text(selected['address_text'].toString()),
          const SizedBox(height: 14),
          FutureBuilder<Map<String, dynamic>>(
            future: _loadHubSummary(selected['hub_id'].toString()),
            builder: (context, data) {
              if (data.hasError) {
                return DashboardErrorCard(
                  message:
                      'Capacity and hub counts require the authorized hub summary RPC.\n${data.error}',
                  onRetry: () => setState(() {}),
                );
              }
              if (!data.hasData) return const DashboardLoadingCard(height: 145);
              final d = data.data!;
              final capacity = _number(d['capacity_kg']);
              final used = _number(d['committed_capacity_kg']);
              final available = (capacity - used).clamp(0, capacity);
              final ratio = capacity <= 0
                  ? 0.0
                  : (used / capacity).clamp(0.0, 1.0);
              return Column(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.storage_outlined, color: _green),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Storage utilisation',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              Text('${(ratio * 100).round()}%'),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '${used.toStringAsFixed(1)} / ${capacity.toStringAsFixed(1)} kg',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: ratio, minHeight: 9),
                          const SizedBox(height: 6),
                          Text(
                            '${available.toStringAsFixed(1)} kg available',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DashboardStatCard(
                          label: 'Awaiting drop-off',
                          value: '${d['awaiting_dropoff_count'] ?? '—'}',
                          icon: Icons.move_to_inbox_outlined,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DashboardStatCard(
                          label: 'Stored donations',
                          value: '${d['stored_donation_count'] ?? '—'}',
                          icon: Icons.inventory_2_outlined,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DashboardStatCard(
                          label: 'Published batches',
                          value: '${d['published_batch_count'] ?? '—'}',
                          icon: Icons.all_inbox_outlined,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DashboardStatCard(
                          label: 'Upcoming collections',
                          value: '${d['upcoming_collection_count'] ?? '—'}',
                          icon: Icons.local_shipping_outlined,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _selectHub(context, selected, section: 'Receive'),
            icon: const Icon(Icons.move_to_inbox_outlined),
            label: const Text('Receive a donation'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () =>
                _selectHub(context, selected, section: 'Inventory'),
            icon: const Icon(Icons.inventory_2_outlined),
            label: const Text('View inventory'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () =>
                _selectHub(context, selected, section: 'Collections'),
            icon: const Icon(Icons.local_shipping_outlined),
            label: const Text('Manage collections and batches'),
          ),
        ],
      );
    },
  );

  Future<Map<String, dynamic>> _loadHubSummary(String id) async {
    final result = await _dashboardDb.rpc(
      'get_hub_dashboard',
      params: {'p_hub': id},
    );
    if (result is! Map) {
      throw const FormatException(
        'Hub summary RPC returned an invalid response.',
      );
    }
    return Map<String, dynamic>.from(result);
  }

  Future<void> _selectHub(
    BuildContext context,
    Map<String, dynamic> hub, {
    String section = 'All',
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HubOperationsPage(hub: hub, section: section),
      ),
    );
    if (mounted) setState(() => _hubs = _loadHubs());
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
  Widget build(BuildContext context) =>
      MyClaimsPage(refreshSignal: refreshSignal, claimsLoader: claimsLoader);
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
  const RoleProfilePage({
    super.key,
    required this.role,
    this.refreshSignal = 0,
    this.profileLoader,
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
    final registration = TextEditingController(
      text: '${profile['registration_number'] ?? ''}',
    );
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
                  TextField(
                    controller: registration,
                    decoration: const InputDecoration(
                      labelText: 'Registration number',
                    ),
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
                registration.text,
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
          'p_registration_number':
              widget.role == 'NGO' && values[3].trim().isNotEmpty
              ? values[3].trim()
              : null,
        },
      );
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) _showProfileError(error);
    } finally {
      name.dispose();
      phone.dispose();
      ngoName.dispose();
      registration.dispose();
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
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => RegisterHubPage(initialHub: hub)),
    );
    if (result == true && mounted) _refresh();
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
                  icon: Icons.confirmation_number_outlined,
                  label: 'Registration number',
                  value: _profileValue(profile['registration_number']),
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
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _editHub(hubs[index]),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit hub details'),
                      ),
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
          if (widget.role == 'DONOR') const SizedBox(height: 16),
          _ProfileSection(
            title: 'Settings',
            icon: Icons.settings_outlined,
            children: const [
              Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Email and account role are fixed for this account. Personal details and permitted role information can be updated securely.',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
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
                  'Confirms road-network access only; it does not verify NGO identity.',
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
      IconButton(
        tooltip: 'Notifications',
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notifications are not available yet.')),
        ),
        icon: const Icon(Icons.notifications_none),
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

class _UnavailableTab extends StatelessWidget {
  final String title;
  final String message;
  const _UnavailableTab({required this.title, required this.message});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: EmptyStateCard(
          icon: Icons.info_outline,
          title: 'Not available yet',
          message: message,
        ),
      ),
    ),
  );
}
