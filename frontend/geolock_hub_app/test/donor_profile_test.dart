import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('donor edits profile from the account card at 320 px', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    const actor = '11111111-1111-4111-8111-111111111111';
    final profile = <String, dynamic>{
      'full_name': 'Original Name',
      'phone_number': '0123456789',
      'role': 'DONOR',
    };
    final writes = <Map<String, dynamic>>[];
    var reads = 0;
    final firstSave = Completer<void>();
    Future<void> waitForResponse(Finder visible) async {
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.pump(const Duration(milliseconds: 24));
        if (visible.evaluate().isNotEmpty) return;
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
      }
      expect(
        visible,
        findsWidgets,
        reason:
            'reads=$reads writes=${writes.length} texts=${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).toList()}',
      );
    }

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
              final payload = base64Url
                  .encode(
                    utf8.encode(
                      jsonEncode({
                        'sub': actor,
                        'exp':
                            DateTime.now().millisecondsSinceEpoch ~/ 1000 +
                            3600,
                      }),
                    ),
                  )
                  .replaceAll('=', '');
              return json({
                'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
                'token_type': 'bearer',
                'expires_in': 3600,
                'refresh_token': 'offline-test-refresh',
                'user': {
                  'id': actor,
                  'email': 'donor@example.invalid',
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
              if (writes.length == 1) {
                await firstSave.future;
                return json({
                  'message': 'Fixture rejection',
                  'code': 'P0001',
                }, 400);
              }
              profile['full_name'] = values['p_full_name'];
              profile['phone_number'] = values['p_phone'];
              return json({'updated': true});
            default:
              throw StateError('Unexpected test request');
          }
        }),
      );
      addTearDown(supabase.dispose);
      await supabase.client.auth.signInWithPassword(
        email: 'donor@example.invalid',
        password: 'offline-test',
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.2)),
          child: child!,
        ),
        home: const Scaffold(body: RoleProfilePage(role: 'DONOR')),
      ),
    );
    await waitForResponse(find.text('Original Name'));
    await tester.pumpAndSettle();
    final heading = find.text('Account information');
    final edit = find.byTooltip('Edit profile');
    await tester.scrollUntilVisible(
      heading,
      140,
      scrollable: find.byType(Scrollable).first,
    );
    expect(reads, 1);
    expect(heading, findsOneWidget);
    expect(edit, findsOneWidget);
    final account = find.ancestor(of: heading, matching: find.byType(Card));
    expect(find.descendant(of: account, matching: edit), findsOneWidget);
    expect(
      tester.getCenter(edit).dx,
      greaterThan(tester.getCenter(heading).dx),
    );
    expect(tester.getSize(edit).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(edit).height, greaterThanOrEqualTo(48));
    expect(find.widgetWithText(OutlinedButton, 'Edit profile'), findsNothing);
    expect(find.text('donor@example.invalid'), findsOneWidget);

    await tester.tap(edit);
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    final name = fields.at(0);
    final phone = fields.at(1);
    String fieldText(Finder field) => tester
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .controller
        .text;
    expect(fieldText(name), 'Original Name');
    expect(fieldText(phone), '0123456789');
    expect(
      find.text('Email address and account role cannot be changed here.'),
      findsOneWidget,
    );
    await tester.enterText(name, 'Discard these edits');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);

    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(fieldText(name), 'Original Name');
    await tester.showKeyboard(name);
    tester.view.viewInsets = const FakeViewPadding(bottom: 290);
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(save.hitTestable(), findsOneWidget);
    await tester.enterText(name, '  ');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Full name is required.'), findsOneWidget);
    expect(writes, isEmpty);
    expect(tester.takeException(), isNull);

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.enterText(name, '  Updated Name  ');
    await tester.enterText(phone, '  ');
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(writes, hasLength(1));
    expect(find.bySemanticsLabel('Saving profile'), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    final primary = find.descendant(
      of: dialog,
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(primary).onPressed, isNull);
    final cancel = find.widgetWithText(TextButton, 'Cancel');
    expect(tester.widget<TextButton>(cancel).onPressed, isNull);
    await tester.tap(primary);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(dialog, findsOneWidget);
    expect(writes, hasLength(1));

    firstSave.complete();
    await waitForResponse(
      find.text('Profile change was not confirmed. Try again.'),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Profile change was not confirmed. Try again.'),
      findsOneWidget,
    );
    expect(fieldText(name), '  Updated Name  ');
    expect(reads, 1);
    await tester.tap(save);
    await waitForResponse(find.text('Updated Name'));
    await tester.pumpAndSettle();
    expect(writes, [
      {'p_full_name': 'Updated Name', 'p_phone': null, 'p_ngo_name': null},
      {'p_full_name': 'Updated Name', 'p_phone': null, 'p_ngo_name': null},
    ]);
    expect(reads, 2);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Updated Name'), findsWidgets);
    expect(find.text('Not added'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
