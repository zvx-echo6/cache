import 'dart:io';

import 'package:cache/screens/videos/external_sign_in.dart';
import 'package:cache/screens/videos/instance_sheet.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_prefs.dart';
import 'package:cache/video/video_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_fake.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<(VideoState, MemoryTokenStore)> _site(WidgetTester tester, String auth) async {
  final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('video-signin')))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  final tokens = MemoryTokenStore();
  final v = VideoState(dirOverride: dir, nativeFactory: seededVideoNative(const [], auth: auth), tokens: tokens, prefs: VideoPrefs());
  await tester.runAsync(v.init);
  await tester.runAsync(() => v.addInstance('tube.example.org'));
  addTearDown(v.dispose);
  return (v, tokens);
}

/// The sign-in sheet of the site, open.
Future<void> _openSheet(WidgetTester tester, VideoState v) async {
  tester.view.physicalSize = const Size(430, 932) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(CacheThemeId.dark),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(onPressed: () => showInstanceSheet(context, video: v, instance: v.instances.single), child: const Text('open')),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await settle(tester);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => externalSignInForTests = null);

  test('The end of an external sign-in is read from the site\'s /login page only', () {
    const prefix = 'https://tube.example.org/login';
    final done = externalSignInResult(Uri.parse('https://tube.example.org/login?externalAuthToken=abc&username=bob'), prefix);
    expect(done, isA<ExternalSignInDone>().having((d) => d.token, 'token', 'abc').having((d) => d.username, 'username', 'bob'));
    expect(externalSignInResult(Uri.parse('https://tube.example.org/login?externalAuthError=true'), prefix), isA<ExternalSignInFailed>());
    expect(externalSignInResult(Uri.parse('https://gitlab.example.com/oauth/authorize?externalAuthToken=x&username=y'), prefix), isNull,
        reason: 'another site: the sign-in goes on');
    expect(externalSignInResult(Uri.parse('https://tube.example.org/plugins/auth-openid-connect/1.2.0/auth/openid-connect'), prefix), isNull);
    expect(externalSignInResult(Uri.parse('https://tube.example.org/login'), prefix), isNull);
  });

  testWidgets('A site with only its own accounts: the user name and password form, no other method', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final (v, _) = await _site(tester, 'local');
    await _openSheet(tester, v);
    expect(find.widgetWithText(TextField, 'User name'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    expect(find.textContaining('Sign in with'), findsNothing);
  });

  testWidgets('A site with only an external method: its button under the site\'s own name, no password form', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final (v, _) = await _site(tester, 'external');
    await _openSheet(tester, v);
    expect(find.text('Sign in with GitLab'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsNothing);
    expect(find.text('Or with your user name and password'), findsNothing);
  });

  testWidgets('A site with both: one button per method, then the form', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final (v, _) = await _site(tester, 'both');
    await _openSheet(tester, v);
    expect(find.text('Sign in with GitLab'), findsOneWidget);
    expect(find.text('Sign in with University login'), findsOneWidget);
    expect(find.text('Or with your user name and password'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
  });

  testWidgets('External sign-in: cancel, failure and a used token each say so; the retry signs in and keeps the tokens', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final (v, tokens) = await _site(tester, 'external');
    await _openSheet(tester, v);
    final answers = <ExternalSignIn?>[null, const ExternalSignInFailed(), const ExternalSignInDone('bob', 'OLD'), const ExternalSignInDone('bob', 'EXT1')];
    final opened = <String>[];
    externalSignInForTests = (auth) async {
      opened.add(auth.url);
      return answers.removeAt(0);
    };

    Future<void> tapSignIn() async {
      await tester.tap(find.text('Sign in with GitLab'));
      await settle(tester);
    }

    await tapSignIn();
    expect(find.text('Sign-in with GitLab was canceled.'), findsOneWidget);
    await tapSignIn();
    expect(find.text("Example PeerTube couldn't sign you in with GitLab. Try again."), findsOneWidget);
    await tapSignIn();
    expect(find.text('That sign-in took too long or was already used. Try again.'), findsOneWidget);
    expect(v.userOf('tube.example.org'), isNull);
    await tapSignIn();
    expect(find.text('Signed in as bob'), findsOneWidget);
    expect(opened.toSet(), {'https://tube.example.org/plugins/auth-openid-connect/1.2.0/auth/openid-connect'});
    expect(tokens.values['video.tube.example.org.access'], 'A1');
    expect(tokens.values['video.tube.example.org.refresh'], 'R1', reason: 'refreshed like a password login');
  });
}
