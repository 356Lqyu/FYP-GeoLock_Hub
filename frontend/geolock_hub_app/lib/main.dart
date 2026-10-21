import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_controller.dart';
import 'auth/auth_navigation.dart';
import 'auth/auth_pages.dart';
import 'donation_pages.dart';
import 'location/location_result.dart';
import 'supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!SupabaseConfig.isConfigured) {
    runApp(const _MissingDevConfigurationApp());
    return;
  }
  await Supabase.initialize(
    url: SupabaseConfig.projectUrl,
    publishableKey: SupabaseConfig.publishableKey,
  );
  runApp(const GeoLockApp());
}

class _MissingDevConfigurationApp extends StatelessWidget {
  const _MissingDevConfigurationApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.settings_outlined, size: 44),
                const SizedBox(height: 12),
                Text(
                  'Development configuration required',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'This build has no valid Supabase environment configuration. '
                  'Normal launches use the isolated DEV project. The original '
                  'shared project requires an explicit environment selection '
                  'and its own publishable key.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class GeoLockApp extends StatelessWidget {
  const GeoLockApp({super.key});
  @override
  Widget build(BuildContext context) {
    const green = Color(0xff2f806c);
    return MaterialApp(
      title: 'GeoLock Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xffedfbf7),
        colorScheme: ColorScheme.fromSeed(seedColor: green, primary: green),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: Color(0xffdce8e4)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: Color(0xffdce8e4)),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 13,
            vertical: 13,
          ),
        ),
      ),
      initialRoute: '/auth',
      routes: {'/auth': (_) => const AuthGate()},
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
    stream: Supabase.instance.client.auth.onAuthStateChange,
    builder: (context, snapshot) {
      if (snapshot.data?.event == AuthChangeEvent.passwordRecovery) {
        return const ResetPasswordPage();
      }
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return const WelcomePage();
      return SessionRouter(key: ValueKey(userId), userId: userId);
    },
  );
}

typedef NgoEligibilityStatusLoader = Future<String> Function(String userId);

class SessionRouter extends StatefulWidget {
  final String userId;
  final Future<String?> Function(String userId)? roleLoader;
  final Future<Map<String, dynamic>?> Function(String userId)? profileLoader;
  final bool Function(String userId)? isUserCurrent;
  final Widget Function(String role, String userId)? dashboardBuilder;
  final NgoEligibilityStatusLoader? eligibilityStatusLoader;

  const SessionRouter({
    super.key,
    required this.userId,
    this.roleLoader,
    this.profileLoader,
    this.isUserCurrent,
    this.dashboardBuilder,
    this.eligibilityStatusLoader,
  });
  @override
  State<SessionRouter> createState() => _SessionRouterState();
}

class _SessionRouterState extends State<SessionRouter> {
  String? role;
  Map<String, dynamic>? _profile;
  Object? failure;
  bool loading = true;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant SessionRouter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) _resolve();
  }

  bool _isCurrent(String userId) =>
      widget.isUserCurrent?.call(userId) ??
      Supabase.instance.client.auth.currentUser?.id == userId;

  Future<String?> _loadRole(String userId) async {
    final customLoader = widget.roleLoader;
    if (customLoader != null) {
      final customRole = await customLoader(userId);
      final profileLoader = widget.profileLoader;
      if (profileLoader != null) {
        _profile = await profileLoader(userId);
      } else if (customRole != null) {
        // A role-only test loader represents an already-loaded profile.
        _profile = {'role': customRole};
      }
      await _loadNgoEligibilityStatus(userId, custom: true);
      return customRole;
    }
    final controller = AuthController.instance;
    final registeredRole = await controller.completePendingRegistration(
      expectedUserId: userId,
    );
    _profile = await controller.profile(expectedUserId: userId);
    await _loadNgoEligibilityStatus(userId);
    return _profile?['role'] as String? ?? registeredRole;
  }

  Future<void> _loadNgoEligibilityStatus(
    String userId, {
    bool custom = false,
  }) async {
    if (_profile?['role'] != 'NGO' ||
        _profile?['ngo_location_setup_required'] == true) {
      return;
    }
    final loader = widget.eligibilityStatusLoader;
    if (custom && loader == null) {
      _profile?['ngo_eligibility_status'] ??= 'READY';
      return;
    }
    final status = loader == null
        ? await _readEligibilityStatus()
        : await loader(userId);
    if (_profile != null) _profile!['ngo_eligibility_status'] = status;
  }

  Future<String> _readEligibilityStatus() async {
    final value = await Supabase.instance.client.rpc(
      'get_my_ngo_eligibility_refresh_status',
    );
    if (value is! String) {
      throw const FormatException(
        'NGO eligibility status response was invalid.',
      );
    }
    return value;
  }

  Future<void> _retryNgoEligibility() async {
    final profile = _profile;
    final latitude = double.tryParse('${profile?['latitude']}');
    final longitude = double.tryParse('${profile?['longitude']}');
    final address = profile?['operating_address']?.toString();
    if (latitude == null || longitude == null || address == null) {
      throw StateError('Saved NGO location is unavailable; choose it again.');
    }
    await Supabase.instance.client.rpc(
      'set_ngo_operating_location',
      params: {
        'p_operating_address': address,
        'p_latitude': latitude,
        'p_longitude': longitude,
      },
    );
    await _resolve();
  }

  Future<void> _resolve() async {
    final request = ++_request;
    final userId = widget.userId;
    if (mounted) {
      setState(() {
        role = null;
        _profile = null;
        loading = true;
        failure = null;
      });
    }
    try {
      final resolvedRole = await _loadRole(userId);
      if (mounted &&
          request == _request &&
          widget.userId == userId &&
          _isCurrent(userId)) {
        setState(() {
          role = resolvedRole;
          loading = false;
        });
      }
    } catch (error) {
      if (mounted &&
          request == _request &&
          widget.userId == userId &&
          _isCurrent(userId)) {
        setState(() {
          failure =
              'Account profile could not be loaded: ${AuthController.message(error)}';
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const _BusyScreen();
    if (failure != null) {
      return _ProblemScreen(message: failure.toString(), onRetry: _resolve);
    }
    if (role == null) {
      return const _ProblemScreen(
        message:
            'Signed in successfully, but this account has no role profile. Sign out and register with a role to continue.',
      );
    }
    if (!_isCurrent(widget.userId)) return const WelcomePage();
    if (role == 'NGO' && _profile?['ngo_location_setup_required'] == true) {
      return _NgoLocationOnboardingPage(onComplete: _resolve);
    }
    if (role == 'NGO' && _profile?['ngo_eligibility_status'] != 'READY') {
      return _NgoEligibilityUpdatingPage(
        userId: widget.userId,
        status: _profile?['ngo_eligibility_status']?.toString() ?? 'PENDING',
        loadStatus: widget.eligibilityStatusLoader == null
            ? (_) => _readEligibilityStatus()
            : widget.eligibilityStatusLoader!,
        onReady: _resolve,
        onRetry: _retryNgoEligibility,
      );
    }
    if (role == 'HUB_ADMIN' && _profile?['hub_setup_required'] == true) {
      return RegisterHubPage(onRegistered: _resolve);
    }
    return widget.dashboardBuilder?.call(role!, widget.userId) ??
        RoleDashboardPage(role: role!, userId: widget.userId);
  }
}

class _NgoEligibilityUpdatingPage extends StatefulWidget {
  final String userId;
  final String status;
  final NgoEligibilityStatusLoader loadStatus;
  final Future<void> Function() onReady;
  final Future<void> Function() onRetry;
  const _NgoEligibilityUpdatingPage({
    required this.userId,
    required this.status,
    required this.loadStatus,
    required this.onReady,
    required this.onRetry,
  });

  @override
  State<_NgoEligibilityUpdatingPage> createState() =>
      _NgoEligibilityUpdatingPageState();
}

class _NgoEligibilityUpdatingPageState
    extends State<_NgoEligibilityUpdatingPage> {
  late String _status = widget.status;
  String? _error;
  bool _checking = false;
  bool _retrying = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkStatus() async {
    if (_checking) return;
    _checking = true;
    try {
      final status = await widget.loadStatus(widget.userId);
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
      if (status == 'READY') {
        _timer?.cancel();
        await widget.onReady();
      } else if (status == 'PENDING' || status == 'PROCESSING') {
        _timer ??= Timer.periodic(
          const Duration(seconds: 5),
          (_) => _checkStatus(),
        );
      } else if (status == 'FAILED') {
        _timer?.cancel();
      }
    } catch (error) {
      if (mounted) setState(() => _error = AuthController.message(error));
    } finally {
      _checking = false;
    }
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() {
      _retrying = true;
      _error = null;
    });
    try {
      await widget.onRetry();
    } catch (error) {
      if (mounted) setState(() => _error = AuthController.message(error));
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final failed = _status == 'FAILED';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  failed ? Icons.sync_problem_outlined : Icons.route_outlined,
                  size: 46,
                  color: failed
                      ? Theme.of(context).colorScheme.error
                      : const Color(0xff2f806c),
                ),
                const SizedBox(height: 14),
                Text(
                  failed
                      ? 'Eligibility update needs attention'
                      : 'Eligibility updating',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  failed
                      ? 'Your location was validated and saved, but road-distance eligibility could not be refreshed. Discovery remains unavailable until the refresh succeeds.'
                      : 'Your location was validated and saved. The server is calculating directed road distances. Donation discovery will open when the update is complete.',
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 18),
                if (!failed && _error == null)
                  const CircularProgressIndicator(),
                if (failed)
                  FilledButton.icon(
                    onPressed: _retrying ? null : _retry,
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      _retrying ? 'Retrying…' : 'Retry eligibility update',
                    ),
                  )
                else
                  OutlinedButton(
                    onPressed: _checking ? null : _checkStatus,
                    child: const Text('Check status'),
                  ),
                TextButton(
                  onPressed: () => signOutAndReset(context),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NgoLocationOnboardingPage extends StatefulWidget {
  final Future<void> Function() onComplete;
  const _NgoLocationOnboardingPage({required this.onComplete});

  @override
  State<_NgoLocationOnboardingPage> createState() =>
      _NgoLocationOnboardingPageState();
}

class _NgoLocationOnboardingPageState
    extends State<_NgoLocationOnboardingPage> {
  LocationResult? _location;
  bool _busy = false;
  String? _error;

  Future<void> _chooseLocation() async {
    final selected = await Navigator.push<LocationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => buildNgoLocationPicker(
          initialLocation: _location,
          requireRoadPreview: true,
        ),
      ),
    );
    if (selected != null && mounted) setState(() => _location = selected);
  }

  Future<void> _saveLocation() async {
    final location = _location;
    if (location == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.rpc(
        'set_ngo_operating_location',
        params: {
          'p_operating_address': location.address,
          'p_latitude': location.latitude,
          'p_longitude': location.longitude,
        },
      );
      await widget.onComplete();
    } catch (error) {
      if (mounted) setState(() => _error = AuthController.message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(
            Icons.location_on_outlined,
            size: 42,
            color: Color(0xff2f806c),
          ),
          const SizedBox(height: 12),
          Text(
            'Set up your NGO location',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          const Text(
            'Choose your operating address after login. Road access is previewed using the approved network, then PostgreSQL validates and saves the trusted road node. This technical check does not verify NGO identity.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _busy ? null : _chooseLocation,
            icon: const Icon(Icons.map_outlined),
            label: Text(
              _location == null
                  ? 'Choose operating location'
                  : 'Change location',
            ),
          ),
          if (_location != null) ...[
            const SizedBox(height: 8),
            Text(_location!.address, textAlign: TextAlign.center),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _location == null || _busy ? null : _saveLocation,
            child: _busy
                ? const CircularProgressIndicator()
                : const Text('Validate and continue'),
          ),
          TextButton(
            onPressed: () => signOutAndReset(context),
            child: const Text('Sign out'),
          ),
        ],
      ),
    ),
  );
}

class _BusyScreen extends StatelessWidget {
  const _BusyScreen();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _ProblemScreen extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const _ProblemScreen({required this.message, this.onRetry});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
            TextButton(
              onPressed: () => signOutAndReset(context),
              child: const Text('Back to welcome'),
            ),
          ],
        ),
      ),
    ),
  );
}
