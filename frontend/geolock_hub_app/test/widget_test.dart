import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/auth/auth_pages.dart';
import 'package:geolock_hub_app/donation_pages.dart';
import 'package:geolock_hub_app/main.dart';

void main() {
  testWidgets('welcome page opens login', (tester) async {
    await tester.pumpWidget(const TestHost(child: WelcomePage()));
    expect(find.text('Welcome to GeoLock Hub'), findsOneWidget);
    await tester.tap(find.text('Log In'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Forgot Password?'), findsOneWidget);
  });

  testWidgets('donor selection opens donor registration', (tester) async {
    await tester.pumpWidget(const TestHost(child: SelectRolePage()));
    await tester.tap(find.text('Donor'));
    await tester.pump();
    await tester.tap(find.text('Continue  →'));
    await tester.pumpAndSettle();
    expect(find.text('Role selected: Donor'), findsOneWidget);
    expect(find.text('Full Name'), findsOneWidget);
  });

  testWidgets('login A, logout, login B ignores A profile response', (
    tester,
  ) async {
    final aResult = Completer<String?>();
    await tester.pumpWidget(
      _AuthSwitchHost(
        loadRole: (id) =>
            id == 'account-a' ? aResult.future : Future.value('NGO'),
      ),
    );
    await tester.tap(find.text('Login account A'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('Logout'));
    await tester.pump();
    expect(find.text('Welcome to GeoLock Hub'), findsOneWidget);
    await tester.tap(find.text('Login account B'));
    await tester.pump();
    await tester.pump();
    expect(find.text('account-b · NGO'), findsOneWidget);

    aResult.complete('DONOR');
    await tester.pump();
    expect(find.text('account-b · NGO'), findsOneWidget);
    expect(find.text('account-a · DONOR'), findsNothing);
  });

  testWidgets('switching donor to NGO reloads the role for the new user', (
    tester,
  ) async {
    await tester.pumpWidget(
      _AuthSwitchHost(
        loadRole: (id) => Future.value(id == 'account-a' ? 'DONOR' : 'NGO'),
        initialUserId: 'account-a',
      ),
    );
    await tester.pump();
    expect(find.text('account-a · DONOR'), findsOneWidget);

    await tester.tap(find.text('Switch to account B'));
    await tester.pump();
    await tester.pump();
    expect(find.text('account-b · NGO'), findsOneWidget);
    expect(find.text('account-a · DONOR'), findsNothing);
  });

  testWidgets('signed-in account with missing profile is not auto-created', (
    tester,
  ) async {
    var profileLookups = 0;
    await tester.pumpWidget(
      _AuthSwitchHost(
        initialUserId: 'account-a',
        loadRole: (_) async {
          profileLookups++;
          return null;
        },
      ),
    );
    await tester.pump();
    expect(
      find.textContaining(
        'Signed in successfully, but this account has no role profile',
      ),
      findsOneWidget,
    );
    expect(profileLookups, 1);
    expect(find.text('account-a · DONOR'), findsNothing);
  });

  testWidgets(
    'incomplete NGO onboarding blocks dashboard until location setup',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SessionRouter(
            userId: 'ngo-account',
            isUserCurrent: (id) => id == 'ngo-account',
            roleLoader: (_) async => 'NGO',
            profileLoader: (_) async => {
              'role': 'NGO',
              'ngo_location_setup_required': true,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Set up your NGO location'), findsOneWidget);
      expect(find.text('Choose operating location'), findsOneWidget);
      expect(find.text('Validate and continue'), findsOneWidget);
      expect(find.text('Discover'), findsNothing);
    },
  );

  testWidgets('incomplete Hub Admin onboarding opens hub registration', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionRouter(
          userId: 'hub-account',
          isUserCurrent: (id) => id == 'hub-account',
          roleLoader: (_) async => 'HUB_ADMIN',
          profileLoader: (_) async => {
            'role': 'HUB_ADMIN',
            'hub_setup_required': true,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RegisterHubPage), findsOneWidget);
    expect(find.text('Register Community Hub'), findsOneWidget);
    expect(find.text('Total capacity (kg)'), findsOneWidget);
  });

  testWidgets('NGO sees eligibility updating after location validation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionRouter(
          userId: 'ngo-account',
          isUserCurrent: (id) => id == 'ngo-account',
          roleLoader: (_) async => 'NGO',
          profileLoader: (_) async => {
            'role': 'NGO',
            'ngo_location_setup_required': false,
          },
          eligibilityStatusLoader: (_) async => 'PENDING',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Eligibility updating'), findsOneWidget);
    expect(
      find.textContaining('Your location was validated and saved'),
      findsOneWidget,
    );
    expect(find.text('Discover'), findsNothing);
  });

  testWidgets('eligibility refresh failure is not shown as location failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionRouter(
          userId: 'ngo-account',
          isUserCurrent: (id) => id == 'ngo-account',
          roleLoader: (_) async => 'NGO',
          profileLoader: (_) async => {
            'role': 'NGO',
            'ngo_location_setup_required': false,
          },
          eligibilityStatusLoader: (_) async => 'FAILED',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Eligibility update needs attention'), findsOneWidget);
    expect(
      find.textContaining('Your location was validated and saved'),
      findsOneWidget,
    );
    expect(find.text('Retry eligibility update'), findsOneWidget);
    expect(
      find.textContaining('location could not be validated'),
      findsNothing,
    );
  });
}

class TestHost extends StatelessWidget {
  final Widget child;
  const TestHost({super.key, required this.child});
  @override
  Widget build(BuildContext context) => MaterialApp(home: child);
}

class _AuthSwitchHost extends StatefulWidget {
  final Future<String?> Function(String userId) loadRole;
  final String? initialUserId;

  const _AuthSwitchHost({required this.loadRole, this.initialUserId});

  @override
  State<_AuthSwitchHost> createState() => _AuthSwitchHostState();
}

class _AuthSwitchHostState extends State<_AuthSwitchHost> {
  late String? userId = widget.initialUserId;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: userId == null
        ? Scaffold(
            body: Column(
              children: [
                const Expanded(child: WelcomePage()),
                TextButton(
                  onPressed: () => setState(() => userId = 'account-a'),
                  child: const Text('Login account A'),
                ),
                TextButton(
                  onPressed: () => setState(() => userId = 'account-b'),
                  child: const Text('Login account B'),
                ),
              ],
            ),
          )
        : Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: SessionRouter(
                    key: ValueKey(userId),
                    userId: userId!,
                    roleLoader: widget.loadRole,
                    isUserCurrent: (id) => id == userId,
                    dashboardBuilder: (role, id) => Text('$id · $role'),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => userId = null),
                  child: const Text('Logout'),
                ),
                TextButton(
                  onPressed: () => setState(() => userId = 'account-b'),
                  child: const Text('Switch to account B'),
                ),
              ],
            ),
          ),
  );
}
