import 'dart:io';

import 'package:cache/browse/reader_screen.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';

void main() {
  group('leaving the reader', () {
    late FakeSources sources;
    late ZimFile zim;

    setUp(() {
      final dir = Directory.systemTemp.createTempSync('reader-back');
      sources = FakeSources(dir);
      zim = ZimFile(path: '${dir.path}/urban-prepper_en_all_2026-08.zim', size: 1 << 30);
      sources.zims = [zim];
      sources.titles[zim.path] = 'Urban Prepper';
    });

    Future<void> openReader(WidgetTester tester, {bool history = false}) async {
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        theme: buildTheme(CacheThemeId.light),
        home: Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => ZimReaderScreen(sources: sources, zim: zim, debugHasHistory: history))),
                child: const Text('Library'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      expect(find.byType(ZimReaderScreen), findsOneWidget);
    }

    testWidgets('the top-left arrow leaves the reader even with page history, and says so to a screen reader', (tester) async {
      await openReader(tester, history: true);
      expect(find.bySemanticsLabel('Close Urban Prepper'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('reader-page-back'))).onPressed, isNotNull, reason: 'the bottom Back is the page history');
      await tester.tap(find.byKey(const ValueKey('reader-close')));
      await tester.pumpAndSettle();
      expect(find.byType(ZimReaderScreen), findsNothing);
      expect(find.text('Library'), findsOneWidget);
    });

    testWidgets('Android system back: a page back while there is history (the reader stays), then it leaves', (tester) async {
      await openReader(tester, history: true);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ZimReaderScreen), findsOneWidget, reason: 'with history, system back is a page back');
      await openReader(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ZimReaderScreen), findsNothing, reason: 'with no history left, system back leaves the reader');
    });

    test('system back closes search, then find, then goes a page back, then leaves', () {
      expect(readerBackStep(searching: true, finding: true, hasHistory: true), ReaderBack.closeSearch);
      expect(readerBackStep(searching: false, finding: true, hasHistory: true), ReaderBack.closeFind);
      expect(readerBackStep(searching: false, finding: false, hasHistory: true), ReaderBack.pageBack);
      expect(readerBackStep(searching: false, finding: false, hasHistory: false), ReaderBack.exit);
    });
  });

  group('landing pages are never history steps', () {
    const metaRefresh = '<html><head><meta http-equiv="refresh" content="0;url=home.html"></head><body></body></html>';
    const jsRedirect = '<html><head><script>window.location.href = "home.html";</script></head><body>Loading</body></html>';
    const jsReplace = "<!doctype html><script>location.replace('videos/index.html')</script>";
    const realPage = '<html><head><script>if (a == b) { x = 1 }</script></head><body><h1>The Urban Prepper</h1><p>Videos about getting ready for emergencies, '
        'gear reviews, bug-out bags and home preparedness. Choose a video from the list below to watch it offline.</p>'
        '<ul><li>Bug out bag</li><li>Water storage</li><li>Power outage</li></ul></body></html>';

    test('a meta refresh or a short page whose script only sets the location is a landing page; a real page is not', () {
      expect(isLandingPage(metaRefresh), isTrue);
      expect(isLandingPage(jsRedirect), isTrue);
      expect(isLandingPage(jsReplace), isTrue);
      expect(isLandingPage(realPage), isFalse);
    });

    test('back from the first real page leaves the reader; from a later page it skips the landing pages', () {
      // The ZIM's main entry (a redirect, served as its target) and a landing page, then the channel's home, then a video.
      const history = ['zim:z/index.html', 'zim:z/home.html', 'zim:z/videos/bug-out-bag.html'];
      final landing = {'zim:z/index.html'};
      expect(readerBackSteps(history, 1, landing), isNull, reason: 'the first real page: back leaves');
      expect(readerBackSteps(history, 2, landing), -1);
      const twoHops = ['zim:z/A', 'zim:z/B', 'zim:z/home.html', 'zim:z/v.html', 'zim:z/A', 'zim:z/B', 'zim:z/home.html'];
      expect(readerBackSteps(twoHops, 6, {'zim:z/A', 'zim:z/B'}), -3, reason: 'over both hops to the page before them');
      expect(readerBackSteps(twoHops, 2, {'zim:z/A', 'zim:z/B'}), isNull);
      // A page that rewrites its address as it starts (a video channel's app: index.html, then index.html#/home): the reader
      // settled on the second entry, so Back from it leaves.
      const app = ['zim:z/index.html', 'zim:z/index.html', 'zim:z/index.html'];
      expect(readerBackSteps(app, 1, const {}, firstReal: 1), isNull);
      expect(readerBackSteps(app, 2, const {}, firstReal: 1), -1, reason: 'a page the person opened after it settled is a step');
    });
  });
}
