import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolock_hub_app/donation_pages.dart';

const listing = <String, dynamic>{
  'listing_id': 'listing-1',
  'source_type': 'DIRECT_DONATION',
  'routing_status': 'READY',
  'title': 'Food donation',
  'listing_weight_kg': 5,
};
const conflict = <String, dynamic>{
  'outcome': 'CONFLICT',
  'reason_code': 'ALREADY_CLAIMED',
};
const success = <String, dynamic>{'outcome': 'SUCCESS', 'claim_id': 'claim-1'};
const key = 'geolock_claim_request_ngo-a_listing-1';

class Harness {
  bool available = true;
  bool failRead = false;
  int reads = 0;
  final requests = <String>[];
  Future<Object?> Function()? send;
  final refresh = Completer<Object?>();
  bool holdRefresh = false;
  int successes = 0;

  Widget page({String actor = 'ngo-a'}) => NgoListingDetailsPage(
    listing: listing,
    identity: () => actor,
    routingLoader: () async => true,
    listingsLoader: () async {
      reads++;
      if (holdRefresh && reads > 1) return refresh.future;
      if (failRead) throw StateError('private diagnostic');
      return available ? [listing] : [];
    },
    detailsLoader: () async => {
      'images': <Map<String, dynamic>>[],
      'constituents': <Map<String, dynamic>>[],
      'listing_discovered_available': true,
      'progress_status': 'AVAILABLE',
    },
    claimSender: (_, request) async {
      requests.add(request);
      return send == null ? conflict : await send!();
    },
    onSuccess: () => successes++,
  );
}

Finder get claim => find.widgetWithText(FilledButton, 'Claim listing');
bool enabled(WidgetTester tester) =>
    tester.widget<FilledButton>(claim).onPressed != null;
Future<void> mount(
  WidgetTester tester,
  Harness h, {
  String actor = 'ngo-a',
}) async {
  await tester.pumpWidget(MaterialApp(home: h.page(actor: actor)));
  await tester.pumpAndSettle();
  expect(find.text('Refresh availability'), findsNothing);
  expect(find.text('Back to Donations'), findsNothing);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'successful claim keeps confirmation and clears terminal request',
    (t) async {
      final h = Harness()..send = (() async => success);
      await mount(t, h);
      await t.tap(claim);
      await t.pumpAndSettle();
      expect(h.successes, 1);
      expect(find.textContaining('Claim confirmed.'), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString(key), isNull);
    },
  );

  testWidgets('competing NGO gets an explicit already-claimed response', (
    t,
  ) async {
    var owned = false;
    final a = Harness()
      ..send = (() async {
        owned = true;
        return success;
      });
    await mount(t, a);
    await t.tap(claim);
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    final b = Harness();
    b.send = () async {
      expect(owned, isTrue);
      b.available = false;
      return conflict;
    };
    await mount(t, b, actor: 'ngo-b');
    await t.tap(claim);
    await t.pumpAndSettle();
    expect(b.successes, 0);
    expect(enabled(t), isFalse);
    expect(
      find.text('This donation has already been claimed by another NGO.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'definite rejection disables stale page while refresh is pending',
    (t) async {
      final h = Harness()..holdRefresh = true;
      await mount(t, h);
      await t.tap(claim);
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(enabled(t), isFalse);
      expect(find.textContaining('Eligible in the latest'), findsNothing);
      expect(find.text('Current status · Available'), findsNothing);
      h.refresh.complete([]);
      await t.pumpAndSettle();
      expect(find.textContaining('Unavailable to claim'), findsOneWidget);
      expect(h.requests.length, 1);
    },
  );

  testWidgets('trusted refresh confirms unavailable and clears terminal UUID', (
    t,
  ) async {
    final h = Harness();
    h.send = () async {
      h.available = false;
      return conflict;
    };
    await mount(t, h);
    await t.tap(claim);
    await t.pumpAndSettle();
    expect(enabled(t), isFalse);
    expect(h.reads, 2);
    expect(find.textContaining('Unavailable for your account'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString(key), isNull);
  });

  testWidgets(
    'reopening rechecks availability before a fresh deliberate attempt',
    (t) async {
      final h = Harness();
      h.send = () async {
        h.available = false;
        return conflict;
      };
      await mount(t, h);
      await t.tap(claim);
      await t.pumpAndSettle();
      final first = h.requests.single;
      h.available = true;
      h.send = () async => success;
      await t.pumpWidget(const SizedBox());
      await mount(t, h);
      expect(enabled(t), isTrue);
      expect(find.text('Donation availability changed'), findsNothing);
      await t.tap(claim);
      await t.pumpAndSettle();
      expect(h.requests.length, 2);
      expect(h.requests.last, isNot(first));
    },
  );

  testWidgets('refresh failure removes eligible display and stays disabled', (
    t,
  ) async {
    final h = Harness();
    h.send = () async {
      h.failRead = true;
      return conflict;
    };
    await mount(t, h);
    await t.tap(claim);
    await t.pumpAndSettle();
    expect(enabled(t), isFalse);
    expect(find.text('Unable to verify availability'), findsWidgets);
    expect(find.textContaining('Eligible in the latest'), findsNothing);
    expect(find.textContaining('private diagnostic'), findsNothing);
  });

  testWidgets('uncertain network error reuses UUID only on manual retry', (
    t,
  ) async {
    final h = Harness()
      ..send = (() async => throw TimeoutException('network secret'));
    await mount(t, h);
    await t.tap(claim);
    await t.pumpAndSettle();
    expect(h.requests.length, 1);
    expect(h.reads, 1);
    expect(
      find.textContaining('Claim outcome is unconfirmed.'),
      findsOneWidget,
    );
    expect(find.textContaining('network secret'), findsNothing);
    final saved = (await SharedPreferences.getInstance()).getString(key);
    expect(saved, h.requests.single);
    h.send = () async => success;
    await t.tap(claim);
    await t.pumpAndSettle();
    expect(h.requests, [saved, saved]);
  });

  testWidgets('rapid taps send one pending request', (t) async {
    final pending = Completer<Object?>();
    final h = Harness()..send = (() => pending.future);
    await mount(t, h);
    await t.tap(claim);
    await t.tap(claim);
    await t.pump();
    expect(h.requests.length, 1);
    pending.complete(success);
    await t.pumpAndSettle();
    expect(h.successes, 1);
  });

  testWidgets('rollback receipt remains distinct and preserves retry UUID', (
    t,
  ) async {
    final h = Harness()
      ..send = (() async => {
        'outcome': 'ERROR',
        'reason_code': 'CLAIM_TRANSACTION_ROLLED_BACK',
        'rollback_confirmed': true,
        'failure_audit_id': 'receipt',
      });
    await mount(t, h);
    await t.tap(claim);
    await t.pumpAndSettle();
    expect(find.textContaining('database rolled back'), findsOneWidget);
    expect(find.text('Donation availability changed'), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getString(key),
      h.requests.single,
    );
    expect(h.reads, 1);
  });

  testWidgets('initial authorized absence never enables claim', (t) async {
    final h = Harness()..available = false;
    await mount(t, h);
    expect(enabled(t), isFalse);
    expect(h.requests, isEmpty);
  });

  testWidgets('back action returns to discovery and allows list refresh', (
    t,
  ) async {
    var returns = 0;
    final h = Harness();
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => h.page()));
                returns++;
              },
              child: const Text('Donations'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Donations'));
    await t.pumpAndSettle();
    expect(find.text('Refresh availability'), findsNothing);
    expect(find.text('Back to Donations'), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
    expect(enabled(t), isTrue);
    await t.pageBack();
    await t.pumpAndSettle();
    expect(returns, 1);
    expect(find.text('Donations'), findsOneWidget);
  });

  testWidgets(
    'stale detail automatically returns and pending discovery cannot reopen it',
    (t) async {
      final h = Harness()..available = false;
      final pending = Completer<Object?>();
      var reads = 0;
      await t.pumpWidget(
        MaterialApp(
          home: EligibleListingsPage(
            listingsLoader: () async {
              reads++;
              if (reads == 1) return [listing];
              return await pending.future;
            },
            routingLoader: () async => true,
            detailsBuilder: (_) => h.page(),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Food donation'));
      await t.pump();
      // Advance both route transitions while the parent refresh remains pending.
      for (var frame = 0; frame < 12; frame++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(NgoListingDetailsPage), findsNothing);
      expect(find.textContaining('Food donation'), findsNothing);
      expect(h.requests, isEmpty);
      pending.complete([]);
      await t.pumpAndSettle();
      expect(find.textContaining('No eligible listings'), findsOneWidget);
    },
  );

  for (final response in ['timeout', 'unknown', 'malformed']) {
    testWidgets('$response on pushed details preserves navigation and UUID', (
      t,
    ) async {
      final h = Harness()
        ..send = (() async {
          if (response == 'timeout') throw TimeoutException('lost');
          if (response == 'unknown') return {'outcome': 'UNKNOWN'};
          return null;
        });
      await t.pumpWidget(
        MaterialApp(
          home: EligibleListingsPage(
            listingsLoader: () async => [listing],
            routingLoader: () async => true,
            detailsBuilder: (_) => h.page(),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Food donation'));
      await t.pumpAndSettle();
      await t.tap(claim);
      await t.pumpAndSettle();
      expect(find.byType(NgoListingDetailsPage), findsOneWidget);
      expect(
        find.textContaining('Claim outcome is unconfirmed.'),
        findsOneWidget,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(key),
        h.requests.single,
      );
    });
  }

  testWidgets('disposed details do not navigate or show a late message', (
    t,
  ) async {
    final h = Harness();
    final pending = Completer<Object?>();
    h.send = () => pending.future;
    await t.pumpWidget(
      MaterialApp(
        home: EligibleListingsPage(
          listingsLoader: () async => [listing],
          routingLoader: () async => true,
          detailsBuilder: (_) => h.page(),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.textContaining('Food donation'));
    await t.pumpAndSettle();
    await t.tap(claim);
    await t.pump();
    await t.pageBack();
    await t.pumpAndSettle();
    pending.complete(conflict);
    await t.pumpAndSettle();
    expect(find.byType(EligibleListingsPage), findsOneWidget);
    expect(find.textContaining('Donation availability changed'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('initial read failure keeps claim disabled', (t) async {
    final h = Harness()..failRead = true;
    await mount(t, h);
    expect(enabled(t), isFalse);
    expect(find.text('Unable to verify availability'), findsWidgets);
  });

  testWidgets('actual discovery page refreshes after rejected details return', (
    t,
  ) async {
    final h = Harness();
    var discoveryReads = 0;
    await t.pumpWidget(
      MaterialApp(
        home: EligibleListingsPage(
          listingsLoader: () async {
            discoveryReads++;
            return h.available ? [listing] : [];
          },
          routingLoader: () async => true,
          detailsBuilder: (_) => h.page(),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.textContaining('Food donation'));
    await t.pumpAndSettle();
    h.send = () async {
      h.available = false;
      return conflict;
    };
    await t.tap(claim);
    await t.pumpAndSettle();
    expect(find.byType(NgoListingDetailsPage), findsNothing);
    expect(
      find.textContaining('Donation availability changed'),
      findsOneWidget,
    );
    expect(discoveryReads, 2);
    expect(find.textContaining('Food donation'), findsNothing);
    expect(find.textContaining('No eligible listings'), findsOneWidget);
  });
}
