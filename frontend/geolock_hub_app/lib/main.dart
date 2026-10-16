import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_controller.dart';
import 'auth/auth_navigation.dart';
import 'auth/auth_pages.dart';
import 'supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: SupabaseConfig.projectUrl,
    publishableKey: SupabaseConfig.publishableKey,
  );
  runApp(const GeoLockApp());
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

class SessionRouter extends StatefulWidget {
  final String userId;
  final Future<String?> Function(String userId)? roleLoader;
  final bool Function(String userId)? isUserCurrent;
  final Widget Function(String role, String userId)? dashboardBuilder;

  const SessionRouter({
    super.key,
    required this.userId,
    this.roleLoader,
    this.isUserCurrent,
    this.dashboardBuilder,
  });
  @override
  State<SessionRouter> createState() => _SessionRouterState();
}

class _SessionRouterState extends State<SessionRouter> {
  String? role;
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
    if (customLoader != null) return customLoader(userId);
    final controller = AuthController.instance;
    var resolvedRole = await controller.completePendingRegistration(
      expectedUserId: userId,
    );
    if (resolvedRole == null) {
      final data = await controller.profile(expectedUserId: userId);
      resolvedRole = data?['role'] as String?;
    }
    return resolvedRole;
  }

  Future<void> _resolve() async {
    final request = ++_request;
    final userId = widget.userId;
    if (mounted) {
      setState(() {
        role = null;
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
            'Signed in successfully, but this account has no role profile. Sign out and complete registration, or contact the administrator for a provisioned hub account.',
      );
    }
    if (!_isCurrent(widget.userId)) return const WelcomePage();
    return widget.dashboardBuilder?.call(role!, widget.userId) ??
        RoleDashboardPage(role: role!, userId: widget.userId);
  }
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
