import 'dart:async';
import 'package:flutter/material.dart';
import '../location/location_picker_page.dart';
import '../location/location_result.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_controller.dart';
import 'auth_navigation.dart';
import '../dashboard_pages.dart';

const _ink = Color(0xff071a1e);
const _green = Color(0xff2f806c);
const _pale = Color(0xffedfbf7);
const _redirect = String.fromEnvironment(
  'AUTH_REDIRECT_URL',
  defaultValue: 'io.supabase.geolockhub://login-callback',
);

class AuthFrame extends StatelessWidget {
  final Widget child;
  final bool scroll;
  final EdgeInsets padding;
  const AuthFrame({
    super.key,
    required this.child,
    this.scroll = false,
    this.padding = const EdgeInsets.all(24),
  });
  @override
  Widget build(BuildContext context) {
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(padding: padding, child: child),
      ),
    );
    return Scaffold(
      body: SafeArea(
        child: scroll
            ? LayoutBuilder(
                builder: (context, c) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: c.maxHeight),
                    child: content,
                  ),
                ),
              )
            : content,
      ),
    );
  }
}

class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 54});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: const Color(0xffdcefe9),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Icon(Icons.hub_outlined, color: _green),
  );
}

class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 48,
    child: FilledButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox(
              width: 21,
              height: 21,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    ),
  );
}

void showMessage(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
String? validEmail(String? value) =>
    value == null ||
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim())
    ? 'Enter a valid email address.'
    : null;

String? validPassword(String? value) {
  if (value == null || value.length < 8) return 'Use at least 8 characters.';
  if (!RegExp(r'\d').hasMatch(value)) return 'Include at least one number.';
  if (!RegExp(r'[^A-Za-z0-9]').hasMatch(value)) {
    return 'Include at least one special character.';
  }
  return null;
}

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});
  @override
  Widget build(BuildContext context) => AuthFrame(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const BrandMark(size: 58),
        const SizedBox(height: 18),
        const Text(
          'Welcome to GeoLock Hub',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: _ink,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Your central platform for coordinating community support.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xff596d6a)),
        ),
        const SizedBox(height: 28),
        PrimaryButton(
          label: 'Log In',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LoginPage()),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SelectRolePage()),
            ),
            child: const Text('Create Account'),
          ),
        ),
      ],
    ),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false, reveal = false;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!(form.currentState?.validate() ?? false)) return;
    setState(() => busy = true);
    try {
      final response = await AuthController.instance.signIn(
        email.text,
        password.text,
      );
      if (response.session == null) {
        if (mounted) {
          showMessage(
            context,
            'Sign-in was accepted, but no session was created. Check whether this account still needs email verification.',
          );
        }
      } else if (mounted) {
        resetToAuthGate(context);
      }
    } catch (e) {
      if (mounted) showMessage(context, AuthController.message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthFrame(
    scroll: true,
    child: Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const BrandMark(size: 30),
              const SizedBox(width: 10),
              const Text(
                'GeoLock Hub',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 26),
          const Text(
            'Welcome back',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const Text(
            'Log in to securely access and manage your hub dashboard.',
            style: TextStyle(color: Colors.blueGrey),
          ),
          const SizedBox(height: 22),
          const _FieldLabel('Email Address'),
          TextFormField(
            controller: email,
            validator: validEmail,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(hintText: 'name@example.com'),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const _FieldLabel('Password'),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ForgotPasswordPage()),
                ),
                child: const Text('Forgot Password?'),
              ),
            ],
          ),
          TextFormField(
            controller: password,
            obscureText: !reveal,
            validator: (v) =>
                v == null || v.isEmpty ? 'Enter your password.' : null,
            decoration: InputDecoration(
              hintText: 'Password',
              suffixIcon: IconButton(
                onPressed: () => setState(() => reveal = !reveal),
                icon: Icon(
                  reveal
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 19),
          PrimaryButton(label: 'Log In', onPressed: submit, busy: busy),
          const SizedBox(height: 13),
          const Row(
            children: [
              Expanded(child: Divider()),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('OR'),
              ),
              Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SelectRolePage()),
              ),
              child: const Text('Create Account'),
            ),
          ),
        ],
      ),
    ),
  );
}

enum AccountRole { donor, ngo, hubAdmin }

class SelectRolePage extends StatefulWidget {
  const SelectRolePage({super.key});
  @override
  State<SelectRolePage> createState() => _SelectRolePageState();
}

class _SelectRolePageState extends State<SelectRolePage> {
  AccountRole? selected;
  @override
  Widget build(BuildContext context) => AuthFrame(
    scroll: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        const Text(
          'How will you use\nGeoLock Hub?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 23,
            height: 1.2,
            fontWeight: FontWeight.w700,
            color: _ink,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Select a role to tailor your experience.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.blueGrey),
        ),
        const SizedBox(height: 20),
        _RoleCard(
          selected: selected == AccountRole.donor,
          icon: Icons.volunteer_activism_outlined,
          title: 'Donor',
          description: 'Donate useful items and track their collection.',
          onTap: () => setState(() => selected = AccountRole.donor),
        ),
        _RoleCard(
          selected: selected == AccountRole.ngo,
          icon: Icons.apartment_outlined,
          title: 'NGO Personnel',
          description: 'Discover, claim and coordinate available donations.',
          onTap: () => setState(() => selected = AccountRole.ngo),
        ),
        _RoleCard(
          selected: selected == AccountRole.hubAdmin,
          icon: Icons.home_work_outlined,
          title: 'Community Hub Administrator',
          description:
              'Manage hub inventory and coordinate NGO collections. Authorized accounts only.',
          onTap: () => setState(() => selected = AccountRole.hubAdmin),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          label: 'Continue  →',
          onPressed: selected == null
              ? null
              : () {
                  if (selected == AccountRole.hubAdmin) {
                    showMessage(
                      context,
                      'Hub Admin accounts must be provisioned by a trusted administrator.',
                    );
                    return;
                  }
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RegistrationPage(role: selected!),
                    ),
                  );
                },
        ),
      ],
    ),
  );
}

class _RoleCard extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String title, description;
  final VoidCallback onTap;
  const _RoleCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Card(
    color: selected ? const Color(0xffddf1eb) : _pale,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(13),
      side: BorderSide(color: selected ? _green : const Color(0xffcddfd9)),
    ),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xffdcefe9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: _green),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.blueGrey,
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

class RegistrationPage extends StatefulWidget {
  final AccountRole role;
  const RegistrationPage({super.key, required this.role});
  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

class _RegistrationPageState extends State<RegistrationPage> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      email = TextEditingController(),
      phone = TextEditingController(),
      password = TextEditingController(),
      confirm = TextEditingController();
  final ngoName = TextEditingController(), regNo = TextEditingController();
  LocationResult? ngoLocation;
  bool busy = false, showPass = false, showConfirm = false;
  @override
  void dispose() {
    for (final c in [name, email, phone, password, confirm, ngoName, regNo]) {
      c.dispose();
    }
    super.dispose();
  }

  String? requiredValue(String? v) =>
      v == null || v.trim().isEmpty ? 'This field is required.' : null;
  Future<void> selectNgoLocation() async {
    final selected = await Navigator.push<LocationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          title: 'NGO Operating Location',
          initialLocation: ngoLocation,
        ),
      ),
    );
    if (selected != null && mounted) setState(() => ngoLocation = selected);
  }

  Future<void> submit() async {
    if (!(form.currentState?.validate() ?? false)) return;
    if (widget.role == AccountRole.ngo && ngoLocation == null) {
      showMessage(context, 'Select and confirm the NGO operating location.');
      return;
    }
    setState(() => busy = true);
    final role = widget.role == AccountRole.donor ? 'DONOR' : 'NGO';
    final pending = <String, dynamic>{
      'role': role,
      'full_name': name.text.trim(),
      'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
    };
    if (role == 'NGO') {
      pending.addAll({
        'ngo_name': ngoName.text.trim(),
        'registration_number': regNo.text.trim().isEmpty
            ? null
            : regNo.text.trim(),
        'operating_address': ngoLocation!.address,
        'latitude': ngoLocation!.latitude,
        'longitude': ngoLocation!.longitude,
      });
    }
    try {
      final response = await AuthController.instance.signUp(
        email: email.text,
        password: password.text,
        pendingProfile: pending,
      );
      if (!mounted) return;
      if (response.session != null) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      }
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => EmailVerificationPage(email: email.text.trim()),
        ),
      );
    } catch (e) {
      if (mounted) showMessage(context, AuthController.message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthFrame(
    scroll: true,
    padding: const EdgeInsets.all(16),
    child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [BoxShadow(color: Color(0x10000000), blurRadius: 18)],
      ),
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  const Icon(Icons.volunteer_activism, color: _green, size: 34),
                  const SizedBox(height: 4),
                  const Text(
                    'Create Account',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'Role selected: ${widget.role == AccountRole.donor ? 'Donor' : 'NGO Personnel'}',
                    style: const TextStyle(color: _green, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const _SectionTitle('Personal Details'),
            const _FieldLabel('Full Name'),
            TextFormField(
              controller: name,
              validator: requiredValue,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'Jane Doe'),
            ),
            const SizedBox(height: 10),
            const _FieldLabel('Email Address'),
            TextFormField(
              controller: email,
              validator: validEmail,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(hintText: 'jane@example.com'),
            ),
            const SizedBox(height: 10),
            const _FieldLabel('Phone Number (optional)'),
            TextFormField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(hintText: '+60 12 345 6789'),
            ),
            if (widget.role == AccountRole.ngo) ...[
              const SizedBox(height: 16),
              const _SectionTitle('NGO Information'),
              const _FieldLabel('NGO Organisation Name'),
              TextFormField(
                controller: ngoName,
                validator: requiredValue,
                decoration: const InputDecoration(
                  hintText: 'Organisation name',
                ),
              ),
              const SizedBox(height: 10),
              const _FieldLabel('Registration / Reference Number (optional)'),
              TextFormField(
                controller: regNo,
                decoration: const InputDecoration(
                  hintText: 'Registration number',
                ),
              ),
              const SizedBox(height: 10),
              const _FieldLabel('Operating Address and Map Pin'),
              OutlinedButton.icon(
                onPressed: busy ? null : selectNgoLocation,
                icon: const Icon(Icons.location_on_outlined),
                label: Text(
                  ngoLocation == null ? 'Select location' : 'Change location',
                ),
              ),
              if (ngoLocation != null) ...[
                const SizedBox(height: 6),
                Text(ngoLocation!.address),
                Text(
                  '${ngoLocation!.latitude.toStringAsFixed(6)}, ${ngoLocation!.longitude.toStringAsFixed(6)} · awaiting trusted location verification',
                  style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
                ),
              ],
            ],
            const SizedBox(height: 16),
            const _SectionTitle('Security'),
            const _FieldLabel('Password'),
            TextFormField(
              controller: password,
              obscureText: !showPass,
              validator: validPassword,
              decoration: InputDecoration(
                suffixIcon: IconButton(
                  onPressed: () => setState(() => showPass = !showPass),
                  icon: Icon(
                    showPass ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const _FieldLabel('Confirm Password'),
            TextFormField(
              controller: confirm,
              obscureText: !showConfirm,
              validator: (v) =>
                  v != password.text ? 'Passwords do not match.' : null,
              decoration: InputDecoration(
                suffixIcon: IconButton(
                  onPressed: () => setState(() => showConfirm = !showConfirm),
                  icon: Icon(
                    showConfirm ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            PrimaryButton(label: 'Register', onPressed: submit, busy: busy),
            Center(
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                ),
                child: const Text('Already have an account? Log in'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class EmailVerificationPage extends StatefulWidget {
  final String email;
  const EmailVerificationPage({super.key, required this.email});
  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  bool busy = false, sent = false;
  int cooldown = 0;
  Timer? timer;
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void startCooldown() {
    timer?.cancel();
    setState(() => cooldown = 60);
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (cooldown <= 1) {
        t.cancel();
        setState(() => cooldown = 0);
      } else {
        setState(() => cooldown--);
      }
    });
  }

  Future<void> resend() async {
    if (busy || cooldown > 0) return;
    setState(() => busy = true);
    try {
      await AuthController.instance.resendVerification(
        widget.email,
        redirectTo: _redirect,
      );
      if (mounted) {
        setState(() => sent = true);
        startCooldown();
      }
    } catch (e) {
      if (mounted) showMessage(context, AuthController.message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthFrame(
    child: Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Color(0x10000000), blurRadius: 18)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircleAvatar(
            radius: 25,
            backgroundColor: Color(0xffdcefe9),
            child: Icon(Icons.mark_email_read_outlined, color: _green),
          ),
          const SizedBox(height: 16),
          const Text(
            'Check your email',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
          const Text(
            'We sent a verification link to:',
            textAlign: TextAlign.center,
          ),
          Text(
            widget.email,
            style: const TextStyle(color: _green, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'Open the link to verify your address and finish creating your profile.',
            textAlign: TextAlign.center,
          ),
          if (sent)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                cooldown > 0
                    ? 'Verification email sent. You can resend in $cooldown seconds.'
                    : 'Verification email sent.',
                style: const TextStyle(color: _green),
              ),
            ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: busy || cooldown > 0 ? null : resend,
            child: Text(
              busy
                  ? 'Sending…'
                  : cooldown > 0
                  ? 'Resend in ${cooldown}s'
                  : 'Resend Verification Email',
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const LoginPage()),
              (_) => false,
            ),
            child: const Text('Back to Log In'),
          ),
        ],
      ),
    ),
  );
}

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});
  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  bool busy = false, sent = false;
  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!(form.currentState?.validate() ?? false)) return;
    setState(() => busy = true);
    try {
      await AuthController.instance.sendReset(
        email.text,
        redirectTo: _redirect,
      );
      if (mounted) setState(() => sent = true);
    } catch (e) {
      if (mounted) {
        setState(() => sent = true);
        showMessage(
          context,
          'If the address is eligible, a reset email will arrive shortly. Check your connection and try again if needed.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthFrame(
    scroll: true,
    child: Form(
      key: form,
      child: Column(
        children: [
          const Icon(Icons.lock_reset, size: 62, color: _green),
          const SizedBox(height: 14),
          const Text(
            'Reset your password',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          const Text(
            'Enter your email address and we’ll send you a link to reset your password.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.blueGrey),
          ),
          const SizedBox(height: 20),
          if (sent)
            const Text(
              'If an account exists for that address, a reset link has been sent.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _green),
            ),
          const Align(
            alignment: Alignment.centerLeft,
            child: _FieldLabel('Email Address'),
          ),
          TextFormField(
            controller: email,
            validator: validEmail,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(hintText: 'you@example.com'),
          ),
          const SizedBox(height: 17),
          PrimaryButton(
            label: sent ? 'Send Again' : 'Send Reset Email',
            onPressed: submit,
            busy: busy,
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('← Back to login'),
          ),
        ],
      ),
    ),
  );
}

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key});
  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final form = GlobalKey<FormState>();
  final password = TextEditingController(), confirm = TextEditingController();
  bool busy = false, show1 = false, show2 = false;
  @override
  void dispose() {
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!(form.currentState?.validate() ?? false)) return;
    setState(() => busy = true);
    try {
      await AuthController.instance.updatePassword(password.text);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const PasswordUpdatedPage()),
        );
      }
    } catch (e) {
      if (mounted) showMessage(context, AuthController.message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthFrame(
    scroll: true,
    child: Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 25),
          const Icon(Icons.lock_reset, size: 48, color: _green),
          const SizedBox(height: 14),
          const Text(
            'Create New Password',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
          ),
          const Text(
            'Choose a password for your account.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          const _FieldLabel('New Password'),
          TextFormField(
            controller: password,
            obscureText: !show1,
            validator: validPassword,
            decoration: InputDecoration(
              hintText: 'At least 8 characters',
              suffixIcon: IconButton(
                onPressed: () => setState(() => show1 = !show1),
                icon: Icon(show1 ? Icons.visibility_off : Icons.visibility),
              ),
            ),
          ),
          const SizedBox(height: 15),
          const _FieldLabel('Confirm New Password'),
          TextFormField(
            controller: confirm,
            obscureText: !show2,
            validator: (v) =>
                v != password.text ? 'Passwords do not match.' : null,
            decoration: InputDecoration(
              hintText: 'Repeat your password',
              suffixIcon: IconButton(
                onPressed: () => setState(() => show2 = !show2),
                icon: Icon(show2 ? Icons.visibility_off : Icons.visibility),
              ),
            ),
          ),
          const SizedBox(height: 20),
          PrimaryButton(
            label: 'Update Password',
            onPressed: submit,
            busy: busy,
          ),
          TextButton(
            onPressed: () => Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const LoginPage()),
              (_) => false,
            ),
            child: const Text('← Back to Login'),
          ),
        ],
      ),
    ),
  );
}

class PasswordUpdatedPage extends StatelessWidget {
  const PasswordUpdatedPage({super.key});
  @override
  Widget build(BuildContext context) => AuthFrame(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircleAvatar(
          radius: 32,
          backgroundColor: Color(0xffd9f0e8),
          child: Icon(Icons.check_circle, size: 46, color: _green),
        ),
        const SizedBox(height: 20),
        const Text(
          'Password updated',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        const Text(
          'You can now log in using your new password.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 22),
        PrimaryButton(
          label: 'Log In',
          onPressed: () async {
            await signOutAndReset(context);
          },
        ),
      ],
    ),
  );
}

class RoleDashboardPage extends StatelessWidget {
  final String role;
  final String userId;
  const RoleDashboardPage({
    super.key,
    required this.role,
    required this.userId,
  });
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
    stream: Supabase.instance.client.auth.onAuthStateChange,
    builder: (context, snapshot) {
      if (Supabase.instance.client.auth.currentSession == null) {
        return const WelcomePage();
      }
      if (Supabase.instance.client.auth.currentUser?.id != userId) {
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 44, color: _green),
                  const SizedBox(height: 12),
                  const Text(
                    'Role lookup is unavailable for this account.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'The supplied database schema does not expose a protected current-profile read RPC.',
                    textAlign: TextAlign.center,
                  ),
                  TextButton(
                    onPressed: () => signOutAndReset(context),
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      if (role == 'DONOR' || role == 'NGO' || role == 'HUB_ADMIN') {
        return RoleNavigationShell(role: role, userId: userId);
      }
      final title = role == 'NGO' ? 'NGO Dashboard' : 'Community Hub Dashboard';
      final icon = role == 'NGO'
          ? Icons.apartment_outlined
          : Icons.home_work_outlined;
      return Scaffold(
        appBar: AppBar(
          title: const Text('GeoLock Hub'),
          actions: [
            IconButton(
              tooltip: 'Log out',
              onPressed: () => signOutAndReset(context),
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 58, color: _green),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text(
                'Your account is connected. Protected coordination read RPCs are still required for data views.',
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    ),
  );
}
