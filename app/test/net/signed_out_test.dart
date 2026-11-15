// Every "Sign in again" in the browser build leads to the sign-in page (the owner's rule: everything that points to something
// links to it). A 401 from the server shows one banner whose words go there.

import 'package:cache/browse/web/device_api.dart';
import 'package:cache/net/signed_out.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() => signedOut.value = false);

  testWidgets('a 401 from the server shows "Sign in again." at the top, and it goes to the sign-in page', (tester) async {
    var went = 0;
    final before = signInAgain;
    signInAgain = () => went++;
    addTearDown(() => signInAgain = before);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: const Scaffold(body: Column(children: [SignedOutBanner(), Expanded(child: Text('page'))])),
    ));
    expect(find.text('Sign in again.'), findsNothing);
    final api = HttpDeviceApi(client: MockClient((_) async => http.Response('', 401)));
    await tester.runAsync(() async {
      await expectLater(api.jobs(), throwsA(isA<DeviceException>()));
    });
    await tester.pump();
    expect(find.text('Sign in again.'), findsOneWidget);
    await tester.tap(find.text('Sign in again.'));
    expect(went, 1);
  });

  testWidgets('the banner\'s words are in the banner\'s own text colour, readable on it (the accent was not)', (tester) async {
    signedOut.value = true;
    final theme = buildTheme(CacheThemeId.dark);
    await tester.pumpWidget(MaterialApp(theme: theme, home: const Scaffold(body: SignedOutBanner())));
    final words = tester.widget<Text>(find.text('Sign in again.'));
    expect(words.style?.color, theme.colorScheme.onErrorContainer);
  });
}
