import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('NGO profile pencil opens the existing form at 320 px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    SharedPreferences.setMockInitialValues({});
    const actor = '11111111-1111-4111-8111-111111111111';
    const email = 'ngo@example.invalid';
    final tokenPayload = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'sub': actor,
              'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            }),
          ),
        )
        .replaceAll('=', '');
    final profile = <String, dynamic>{
      'role': 'NGO',
      'full_name': 'Original Name',
      'phone_number': '0123456789',
      'ngo_name': 'Original NGO',
    };
    final writes = <Map<String, dynamic>>[];
    var reads = 0;

    await tester.runAsync(() async {
      final supabase = await Supabase.initialize(
        url: 'http://localhost:54321',
        publishableKey: 'offline-test-key',
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
        ),
        httpClient: MockClient((request) async {
          http.Response json(Object body, [int status = 200]) => http.Response(
            jsonEncode(body),
            status,
            request: request,
            headers: {'content-type': 'application/json'},
          );
          switch (request.url.path) {
            case '/auth/v1/token':
              return json({
                'access_token': 'eyJhbGciOiJub25lIn0.$tokenPayload.signature',
                'token_type': 'bearer',
                'expires_in': 3600,
                'refresh_token': 'offline-test-refresh',
                'user': {
                  'id': actor,
                  'email': email,
                  'created_at': '2026-10-20T00:00:00Z',
                  'app_metadata': {},
                  'user_metadata': {},
                },
              });
            case '/rest/v1/rpc/get_my_profile':
              reads++;
              return json(profile);
            case '/rest/v1/rpc/update_my_profile':
              final values = jsonDecode(request.body) as Map<String, dynamic>;
              writes.add(values);
              if (values['p_ngo_name'] == '') {
                return json({
                  'message': 'NGO_NAME_REQUIRED',
                  'code': 'P0001',
                }, 400);
              }
              profile['full_name'] = values['p_full_name'];
              profile['phone_number'] = values['p_phone'];
              profile['ngo_name'] = values['p_ngo_name'];
              return json({'updated': true});
            default:
              throw StateError('Unexpected request to ${request.url.path}');
          }
        }),
      );
      addTearDown(supabase.dispose);
      await supabase.client.auth.signInWithPassword(
        email: email,
        password: 'offline-test',
      );
    });

    Future<void> waitFor(Finder finder) async {
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.pump(const Duration(milliseconds: 24));
        if (finder.evaluate().isNotEmpty) return;
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
      }
      expect(finder, findsWidgets);
    }

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.2)),
          child: child!,
        ),
        home: const Scaffold(body: RoleProfilePage(role: 'NGO')),
      ),
    );
    final heading = find.text('Account information');
    final edit = find.byTooltip('Edit profile');
    await waitFor(heading);
    await tester.ensureVisible(heading);
    await tester.pumpAndSettle();
    final account = find.ancestor(of: heading, matching: find.byType(Card));
    expect(find.descendant(of: account, matching: edit), findsOneWidget);
    expect(
      tester.getCenter(edit).dx,
      greaterThan(tester.getCenter(heading).dx),
    );
    expect(tester.getSize(edit).shortestSide, greaterThanOrEqualTo(48));
    expect(find.text('Edit profile'), findsNothing);

    final fields = find.byType(TextField);
    final save = find.widgetWithText(FilledButton, 'Save');
    Future<void> openEdit() async {
      await tester.ensureVisible(heading);
      await tester.pumpAndSettle();
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(fields, findsNWidgets(3));
      final dialog = find.byType(AlertDialog);
      expect(tester.widget<AlertDialog>(dialog).backgroundColor, Colors.white);
      const labels = ['Full name', 'Phone number', 'NGO name'];
      for (var index = 0; index < labels.length; index++) {
        final label = find.descendant(
          of: dialog,
          matching: find.text(labels[index]),
        );
        expect(label, findsOneWidget);
        expect(
          tester.getBottomLeft(label).dy,
          lessThan(tester.getTopLeft(fields.at(index)).dy),
        );
      }
      expect(
        find.text('Email address and account role cannot be changed here.'),
        findsOneWidget,
      );
    }

    await openEdit();
    await tester.enterText(fields.at(2), 'Discarded NGO');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(reads, 1);

    await openEdit();
    expect(
      tester.widget<TextField>(fields.at(2)).controller!.text,
      'Original NGO',
    );
    await tester.showKeyboard(fields.at(2));
    tester.view.viewInsets = const FakeViewPadding(bottom: 290);
    await tester.pumpAndSettle();
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.enterText(fields.at(2), '  ');
    await tester.tap(save);
    tester.view.resetViewInsets();
    await waitFor(find.textContaining('Profile change was not confirmed'));
    await tester.pumpAndSettle();
    expect(writes.single['p_ngo_name'], '');
    expect(reads, 1);

    await openEdit();
    await tester.enterText(fields.at(0), '  Updated Name  ');
    await tester.enterText(fields.at(1), '  ');
    await tester.enterText(fields.at(2), '  Updated NGO  ');
    await tester.tap(save);
    await waitFor(find.text('Updated Name'));
    await tester.pumpAndSettle();
    expect(writes.last, {
      'p_full_name': 'Updated Name',
      'p_phone': null,
      'p_ngo_name': 'Updated NGO',
    });
    expect(reads, 2);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
