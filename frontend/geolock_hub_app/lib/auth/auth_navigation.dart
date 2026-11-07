import 'package:flutter/material.dart';

import 'auth_controller.dart';

/// Rebuild the authenticated landing route and discard screens from the prior
/// account, including any dashboard/detail pages pushed above AuthGate.
void resetToAuthGate(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).pushNamedAndRemoveUntil('/auth', (route) => false);
}

Future<void> signOutAndReset(BuildContext context) async {
  await AuthController.instance.client.auth.signOut();
  if (context.mounted) resetToAuthGate(context);
}
