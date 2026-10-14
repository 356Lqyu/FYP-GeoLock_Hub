import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'donation_pages.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  if (url.isEmpty || key.isEmpty) throw StateError('Missing Supabase configuration');
  await Supabase.initialize(url: url, anonKey: key);
  runApp(const GeoLockApp());
}

final supabase = Supabase.instance.client;

class GeoLockApp extends StatelessWidget {
  const GeoLockApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'GeoLock Hub', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
    home: const AuthGate(),
  );
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final subscription = supabase.auth.onAuthStateChange.listen((_) {
    if (mounted) setState(() {});
  });
  @override
  void dispose() { subscription.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (supabase.auth.currentSession == null) return const LoginPage();
    return const ProfileRouter();
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  @override
  void dispose() { email.dispose(); password.dispose(); super.dispose(); }
  Future<void> login() async {
    setState(() => busy = true);
    try {
      await supabase.auth.signInWithPassword(email: email.text.trim(), password: password.text);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Login failed: $e')));
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('GeoLock Hub — Login')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: Padding(
      padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: email, decoration: const InputDecoration(labelText: 'Email')),
        TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
        const SizedBox(height: 16),
        FilledButton(onPressed: busy ? null : login, child: const Text('Log in')),
        TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPage())), child: const Text('Create an account')),
      ]),
    ))),
  );
}

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});
  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final name = TextEditingController(), email = TextEditingController(), password = TextEditingController();
  final ngoName = TextEditingController(), radius = TextEditingController(text: '20');
  String role = 'DONOR'; bool busy = false;
  @override
  void dispose() { name.dispose(); email.dispose(); password.dispose(); ngoName.dispose(); radius.dispose(); super.dispose(); }
  Future<void> register() async {
    if (name.text.trim().length < 2 || password.text.length < 6 || !email.text.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid name, email and password (6+ characters).'))); return;
    }
    final distance = num.tryParse(radius.text);
    if (role == 'NGO' && (ngoName.text.trim().length < 2 || distance == null || distance <= 0 || distance > 20)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('NGO name and radius (0–20 km) are required.'))); return;
    }
    setState(() => busy = true);
    try {
      final response = await supabase.auth.signUp(
        email: email.text.trim(), password: password.text,
        data: {
          'full_name': name.text.trim(), 'role': role,
          if (role == 'NGO') 'ngo_name': ngoName.text.trim(),
          if (role == 'NGO') 'service_radius_km': distance,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
        response.session == null ? 'Registration submitted. Check your email for confirmation, then log in.' : 'Registration successful.',
      )));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Registration failed: $e')));
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Register')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(20), children: [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name')),
      TextField(controller: email, decoration: const InputDecoration(labelText: 'Email')),
      TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password (6+ characters)')),
      DropdownButtonFormField<String>(initialValue: role, decoration: const InputDecoration(labelText: 'Account role'),
        items: const [DropdownMenuItem(value: 'DONOR', child: Text('Donor')), DropdownMenuItem(value: 'NGO', child: Text('NGO')), DropdownMenuItem(value: 'HUB_ADMIN', child: Text('Hub Admin'))],
        onChanged: (v) => setState(() => role = v ?? 'DONOR')),
      if (role == 'NGO') ...[
        TextField(controller: ngoName, decoration: const InputDecoration(labelText: 'NGO name')),
        TextField(controller: radius, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Service radius (km, max 20)')),
      ],
      const SizedBox(height: 18),
      FilledButton(onPressed: busy ? null : register, child: const Text('Register')),
    ]))),
  );
}

class ProfileRouter extends StatefulWidget {
  const ProfileRouter({super.key});
  @override
  State<ProfileRouter> createState() => _ProfileRouterState();
}

class _ProfileRouterState extends State<ProfileRouter> {
  late Future<Map<String, dynamic>> profile = loadProfile();
  Future<Map<String, dynamic>> loadProfile() async {
    final user = supabase.auth.currentUser;
    if (user == null) throw StateError('No signed-in user');
    return await supabase.from('user_profiles').select('full_name, role, account_status').eq('user_id', user.id).single();
  }
  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: profile,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) return const Scaffold(body: Center(child: CircularProgressIndicator()));
      if (snapshot.hasError) return Scaffold(appBar: AppBar(title: const Text('Profile error')), body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Unable to load profile: ${snapshot.error}', textAlign: TextAlign.center),
        FilledButton(onPressed: () => setState(() => profile = loadProfile()), child: const Text('Retry')),
        TextButton(onPressed: () => supabase.auth.signOut(), child: const Text('Log out')),
      ])));
      final data = snapshot.data!;
      if (data['account_status'] != 'ACTIVE') return const RoleHome(title: 'Account not active');
      switch (data['role']) {
        case 'DONOR': return const DonorDashboard();
        case 'NGO': return const RoleHome(title: 'NGO Dashboard');
        case 'HUB_ADMIN': return const RoleHome(title: 'Hub Admin Dashboard');
        default: return const RoleHome(title: 'Unknown account role');
      }
    },
  );
}

class RoleHome extends StatelessWidget {
  final String title;
  const RoleHome({super.key, required this.title});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title), actions: [IconButton(onPressed: () => supabase.auth.signOut(), icon: const Icon(Icons.logout), tooltip: 'Log out')]),
    body: Center(child: Text('$title\nPhase 6B authentication is working.', textAlign: TextAlign.center)),
  );
}
