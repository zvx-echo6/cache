import 'dart:convert';

import 'package:cache/browse/reader_screen.dart';
import 'package:cache/browse/web/reader_frame.dart';
import 'package:cache/browse/web/zim_token.dart';
import 'package:cache/browse/zim_urls.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const id = '17e9fb54-9554-d2cd-e15f-17cf750882d1';

class _Src extends SourcesState {
  @override
  String? idOf(ZimFile z) => id;

  @override
  Future<String> zimMainPage(String zimId) async => 'zim:$id/A/Main_Page';

  @override
  Future<List<Suggestion>> suggest(String prefix, {int k = 10, List<String>? zimIds}) async =>
      [Suggestion(title: 'Atlanta', address: 'zim:$id/A/Atlanta%20GA', sourceId: id)];
}

class _Tokens extends ZimTokens {
  _Tokens({this.fail});

  final String? fail;

  @override
  Future<String> get() async => fail == null ? 'TOKEN' : throw ZimTokenException(fail!);
}

class _Frame implements ZimFrameHandle {
  final loads = <String>[];
  int backs = 0, forwards = 0;

  @override
  void load(String url) => loads.add(url);
  @override
  void back() => backs++;
  @override
  void forward() => forwards++;
}

void main() {
  group('addresses', () {
    test('a ZIM page is addressed under the token, path and query as the phone has them', () {
      expect(zimFrameUrl('T', 'zim:$id/A/Georgia'), '/zim/T/$id/A/Georgia');
      expect(zimFrameUrl('T', 'zim:$id/A/Some Page#sec'), '/zim/T/$id/A/Some%20Page');
      expect(zimFrameUrl('T', 'zim:$id/A/pic.png?x=1'), '/zim/T/$id/A/pic.png?x=1');
      expect(zimFrameUrl('T', 'https://example.com/'), isNull);
    });

    test('the frame reports its address, and it turns back into the ZIM address', () {
      expect(addressOfFramePath('/zim/T/${id.toUpperCase()}/A/Georgia'), 'zim:$id/A/Georgia');
      expect(addressOfFramePath('/zim/T/$id/A/Georgia?x=1#top'), 'zim:$id/A/Georgia?x=1');
      expect(addressOfFramePath('/api/status'), isNull);
      expect(addressOfFramePath('/zim/T/not-an-id/A/x'), isNull);
    });

    test('the frame history follows back, forward and new pages', () {
      final h = FrameHistory();
      h.reported('a');
      expect((h.canBack, h.canForward), (false, false));
      h.reported('b');
      h.reported('c');
      expect((h.index, h.canBack, h.canForward), (2, true, false));
      h.requested('back');
      h.reported('b');
      expect((h.index, h.canBack, h.canForward), (1, true, true));
      h.requested('forward');
      h.reported('c');
      expect(h.index, 2);
      h.requested('back');
      h.reported('b');
      h.reported('d'); // a new page drops what was ahead
      expect(h.pages, ['a', 'b', 'd']);
      h.reported('d'); // the same page again adds nothing
      expect(h.pages, hasLength(3));
    });
  });

  group('the token', () {
    test('it is asked for once, kept until shortly before it ends, then asked for again', () async {
      var now = DateTime(2026, 11, 1, 9);
      var asked = 0;
      final client = MockClient((req) async {
        asked++;
        expect((req.method, req.url.path), ('POST', '/api/zim/token'));
        return http.Response(jsonEncode({'ok': true, 'result': {'token': 'tok$asked', 'ttl': 12 * 3600}}), 200);
      });
      final t = ZimTokens(client: client, clock: () => now, endpoint: 'https://cache.test/api/zim/token');
      expect(await Future.wait([t.get(), t.get()]), ['tok1', 'tok1'], reason: 'two readers at once share one call');
      now = now.add(const Duration(hours: 11));
      expect(await t.get(), 'tok1');
      now = now.add(const Duration(minutes: 55));
      expect(await t.get(), 'tok2');
      t.forget();
      expect(await t.get(), 'tok3');
    });

    test('a signed-out session and an unreachable device are said in words', () async {
      final signedOut = ZimTokens(client: MockClient((_) async => http.Response('{}', 401)), endpoint: 'https://cache.test/api/zim/token');
      await expectLater(signedOut.get(), throwsA(isA<ZimTokenException>().having((e) => e.message, 'message', 'Sign in again to read this.')));
      final down = ZimTokens(client: MockClient((_) async => throw http.ClientException('no')), endpoint: 'https://cache.test/api/zim/token');
      await expectLater(down.get(), throwsA(isA<ZimTokenException>().having((e) => e.message, 'message', 'This device could not be reached.')));
    });
  });

  group('the reader in a browser', () {
    late _Src sources;
    late _Frame frame;
    late String gotUrl;
    late void Function(String, String) gotPage;
    late void Function(String) gotExternal;

    Widget reader({String? address = 'zim:$id/A/Georgia', ZimTokens? tokens}) {
      frame = _Frame();
      return MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: ZimReaderScreen(
          sources: sources,
          zim: ZimFile(path: '/z/wiki.zim', size: 1),
          address: address,
          debugWeb: true,
          zimTokens: tokens ?? _Tokens(),
          frameBuilder: ({key, required initialUrl, required onCreated, required onPage, required onExternal}) {
            gotUrl = initialUrl;
            gotPage = onPage;
            gotExternal = onExternal;
            onCreated(frame);
            return SizedBox.expand(key: key, child: const Text('the frame'));
          },
        ),
      );
    }

    setUp(() => sources = _Src());

    testWidgets('the page is the device-served frame under the token, and inappwebview is never built', (tester) async {
      await tester.pumpWidget(reader());
      await tester.pump();
      expect(gotUrl, '/zim/TOKEN/$id/A/Georgia');
      expect(find.text('the frame'), findsOneWidget);
      expect(find.byType(InAppWebView), findsNothing);
      // the same chrome as the phone: close, search, more, back, forward, main page
      expect(find.byTooltip('Search this ZIM'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-page-back')), findsOneWidget);
      expect(find.byTooltip('Main page'), findsOneWidget);
      // the page cannot be searched from outside the frame, so that one button is left out
      expect(find.byTooltip('Find in page'), findsNothing);
    });

    testWidgets('with the main page when no address is given', (tester) async {
      await tester.pumpWidget(reader(address: null));
      await tester.pump();
      expect(gotUrl, '/zim/TOKEN/$id/A/Main_Page');
    });

    testWidgets('title, back and forward follow what the frame reports; the buttons talk to the frame', (tester) async {
      await tester.pumpWidget(reader());
      await tester.pump();
      gotPage('/zim/TOKEN/$id/A/Georgia', 'Georgia');
      await tester.pump();
      expect(find.text('Georgia'), findsOneWidget);
      IconButton button(String key) => tester.widget<IconButton>(find.byKey(ValueKey(key)));
      expect(button('reader-page-back').onPressed, isNull);
      gotPage('/zim/TOKEN/$id/A/Atlanta', 'Atlanta');
      await tester.pump();
      expect(find.text('Atlanta'), findsOneWidget);
      expect(button('reader-page-back').onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('reader-page-back')));
      expect(frame.backs, 1);
      gotPage('/zim/TOKEN/$id/A/Georgia', 'Georgia');
      await tester.pump();
      expect(button('reader-page-forward').onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('reader-page-forward')));
      expect(frame.forwards, 1);
    });

    testWidgets('Main page and a search suggestion load their page in the frame', (tester) async {
      await tester.pumpWidget(reader());
      await tester.pump();
      await tester.tap(find.byTooltip('Main page'));
      await tester.pump();
      expect(frame.loads, ['/zim/TOKEN/$id/A/Main_Page']);
      await tester.tap(find.byTooltip('Search this ZIM'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'atl');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.tap(find.text('Atlanta'));
      await tester.pump();
      expect(frame.loads.last, '/zim/TOKEN/$id/A/Atlanta%20GA');
    });

    testWidgets('a link out of the ZIM is handed on, not loaded in the frame', (tester) async {
      await tester.pumpWidget(reader());
      await tester.pump();
      expect(() => gotExternal('https://example.com/'), returnsNormally);
      expect(frame.loads, isEmpty);
    });

    testWidgets('no token: the reader says so in words', (tester) async {
      await tester.pumpWidget(reader(tokens: _Tokens(fail: 'Sign in again to read this.')));
      await tester.pump();
      expect(find.text('Sign in again to read this.'), findsOneWidget);
    });
  });
}
