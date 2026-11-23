import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolock_hub_app/dashboard_pages.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('Hub account and hub details use separate dialogs at 320 px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    SharedPreferences.setMockInitialValues({});
    const actor = '11111111-1111-4111-8111-111111111111';
    const email = 'hub@example.invalid';
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
      'role': 'HUB_ADMIN',
      'full_name': 'Original Name',
      'phone_number': '0123456789',
    };
    final writes = <Map<String, dynamic>>[];
    const hubId = '22222222-2222-4222-8222-222222222222';
    final hub = <String, dynamic>{
      'hub_id': hubId,
      'hub_name': 'Original Hub',
      'address_text': 'Saved address',
      'latitude': 3.0,
      'longitude': 101.0,
      'capacity_kg': 100,
    };
    final hubWrites = <Map<String, dynamic>>[];
    var reads = 0;
    var hubChanges = 0;

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
              profile['full_name'] = values['p_full_name'];
              profile['phone_number'] = values['p_phone'];
              profile['ngo_name'] = values['p_ngo_name'];
              return json({'updated': true});
            case '/rest/v1/rpc/get_my_hubs':
              return json([hub]);
            case '/rest/v1/rpc/get_hub_dashboard':
              return json({'available_capacity_kg': 90});
            case '/rest/v1/rpc/update_my_hub':
              final values = jsonDecode(request.body) as Map<String, dynamic>;
              hubWrites.add(values);
              if (hubWrites.length == 1) {
                return json({
                  'message': 'HUB_HAS_ACTIVE_INVENTORY_OR_COMMITMENTS',
                  'code': 'P0001',
                }, 400);
              }
              hub['hub_name'] = values['p_name'];
              hub['capacity_kg'] = values['p_capacity_kg'];
              return json({'road_node_id': 'test-node'});
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
        home: Scaffold(
          body: RoleProfilePage(
            role: 'HUB_ADMIN',
            onHubChanged: () => hubChanges++,
          ),
        ),
      ),
    );
    final heading = find.text('Account information');
    final edit = find.byTooltip('Edit profile');
    final dialog = find.byType(AlertDialog);
    final fields = find.byType(TextFormField);
    final inputs = find.byType(TextField);
    final save = find.widgetWithText(FilledButton, 'Save');
    final cancel = find.widgetWithText(TextButton, 'Cancel');
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

    void expectForm(
      String title,
      List<String> labels,
      List<String> initialValues,
    ) {
      expect(
        find.descendant(of: dialog, matching: find.text(title)),
        findsOneWidget,
      );
      expect(tester.widget<AlertDialog>(dialog).backgroundColor, Colors.white);
      expect(
        tester
            .widgetList<TextFormField>(fields)
            .map((field) => field.initialValue),
        initialValues,
      );
      for (var index = 0; index < labels.length; index++) {
        final label = find.descendant(
          of: dialog,
          matching: find.text(labels[index]),
        );
        expect(
          tester.getBottomLeft(label).dy,
          lessThan(tester.getTopLeft(inputs.at(index)).dy),
        );
      }
    }

    await tester.tap(edit);
    await tester.pumpAndSettle();
    expectForm(
      'Edit profile',
      ['Full name', 'Phone number'],
      ['Original Name', '0123456789'],
    );
    expect(
      find.text('Email address and account role cannot be changed here.'),
      findsOneWidget,
    );
    await tester.showKeyboard(inputs.last);
    tester.view.viewInsets = const FakeViewPadding(bottom: 290);
    await tester.pumpAndSettle();
    expect(save.hitTestable(), findsOneWidget);
    await tester.enterText(inputs.first, 'Discard this name');
    await tester.tap(cancel);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(writes, isEmpty);

    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(inputs.first, '  Updated Name  ');
    await tester.tap(save);
    await waitFor(find.text('Updated Name'));
    await tester.pumpAndSettle();
    expect(writes.single, {
      'p_full_name': 'Updated Name',
      'p_phone': '0123456789',
      'p_ngo_name': null,
    });
    expect(hubWrites, isEmpty);
    expect(reads, 2);

    final editHub = find.ancestor(
      of: find.text('Edit hub details'),
      matching: find.bySubtype<OutlinedButton>(),
    );
    Future<void> openHubDetails() async {
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        editHub,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(editHub);
      await tester.pumpAndSettle();
    }

    await openHubDetails();
    expectForm(
      'Edit hub details',
      ['Hub name', 'Storage capacity (kg)'],
      ['Original Hub', '100'],
    );
    expect(find.text('50\u2013250 kg'), findsOneWidget);
    expect(
      find.textContaining('stored donations, active drop-offs or open batches'),
      findsOneWidget,
    );
    await tester.enterText(inputs.first, 'Discard this hub name');
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(hubWrites, isEmpty);

    await openHubDetails();
    await tester.showKeyboard(inputs.last);
    tester.view.viewInsets = const FakeViewPadding(bottom: 290);
    await tester.pumpAndSettle();
    expect(save.hitTestable(), findsOneWidget);
    await tester.enterText(inputs.last, '49');
    await tester.tap(save);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Enter a hub name and a capacity from 50 to 250 kg.'),
      findsOneWidget,
    );
    expect(hubWrites, isEmpty);
    expect(reads, 2);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await openHubDetails();
    await tester.enterText(inputs.last, '251');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(hubWrites, isEmpty);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await openHubDetails();
    await tester.enterText(inputs.last, '50');
    await tester.tap(save);
    await waitFor(
      find.textContaining('HUB_HAS_ACTIVE_INVENTORY_OR_COMMITMENTS'),
    );
    expect(hubWrites.single['p_capacity_kg'], 50);
    expect(hubChanges, 0);
    expect(reads, 2);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await openHubDetails();
    await tester.enterText(inputs.first, '  Updated Hub  ');
    await tester.enterText(inputs.last, '250');
    await tester.tap(save);
    await waitFor(find.text('Hub details saved.'));
    await waitFor(heading);
    final updatedHub = find.text('Updated Hub');
    await tester.scrollUntilVisible(
      updatedHub,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(updatedHub.hitTestable(), findsOneWidget);
    expect(hubWrites.last, {
      'p_hub': hubId,
      'p_name': 'Updated Hub',
      'p_address': 'Saved address',
      'p_lat': 3.0,
      'p_lon': 101.0,
      'p_capacity_kg': 250,
    });
    expect(hubChanges, 1);
    expect(reads, 3);
    expect(dialog, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
