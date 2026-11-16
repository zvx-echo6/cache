// Web links in the guide and in Credits follow the same rule as books and ZIM pages: online the phone's browser opens;
// offline it says "You're offline" with "Copy link", in place. Section links and app links keep working as before.

import 'package:cache/guide/app_links.dart';
import 'package:cache/guide/guide_book.dart';
import 'package:cache/guide/guide_reader.dart';
import 'package:cache/net/web_link.dart';
import 'package:cache/screens/settings/about_pages.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe implements ConnectionProbe {
  _Probe(this.kind);
  ConnectionKind kind;
  @override
  Future<ConnectionKind> current() async => kind;
  @override
  Stream<ConnectionKind> get changes => const Stream.empty();
}

void _tapLink(WidgetTester tester, String text) {
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    TapGestureRecognizer? hit;
    rt.text.visitChildren((span) {
      if (span is TextSpan && (span.text ?? '').contains(text) && span.recognizer is TapGestureRecognizer) {
        hit = span.recognizer as TapGestureRecognizer;
        return false;
      }
      return true;
    });
    if (hit != null) {
      hit!.onTap!();
      return;
    }
  }
  fail('no link with "$text"');
}

void main() {
  final opened = <String>[];
  final copied = <String>[];
  late _Probe probe;

  setUp(() {
    opened.clear();
    copied.clear();
    probe = _Probe(ConnectionKind.wifi);
    WebLinks.probe = probe;
    WebLinks.open = (u) async => opened.add(u);
    WebLinks.copy = (t) async => copied.add(t);
  });

  tearDown(() {
    appPlaceScreen = null;
    openAppPlace = null;
  });

  Future<void> show(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: page));
    await tester.pumpAndSettle();
  }

  Future<void> offlineChecks(WidgetTester tester, String url) async {
    expect(opened, isEmpty);
    expect(find.text("You're offline"), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copied, [url]);
  }

  GuideBook book() => GuideBook.parse(['# 9. Test\n\n## One\n\nSee [a site](https://example.org/page) and [Two](#test--two).\n\n## Two\n\nSecond.\n']);

  group('the guide', () {
    testWidgets('online: a web link opens in the phone\'s browser', (tester) async {
      final b = book();
      await show(tester, GuideSectionScreen(book: b, section: b.sections.first));
      _tapLink(tester, 'a site');
      await tester.pump();
      await tester.pump();
      expect(opened, ['https://example.org/page']);
      expect(find.text("You're offline"), findsNothing);
    });

    testWidgets('offline: "You\'re offline" with Copy link, in place; the browser is not called', (tester) async {
      probe.kind = ConnectionKind.none;
      final b = book();
      await show(tester, GuideSectionScreen(book: b, section: b.sections.first));
      _tapLink(tester, 'a site');
      await tester.pump();
      await tester.pump();
      await offlineChecks(tester, 'https://example.org/page');
    });

    testWidgets('a #section link still opens that section, and no web link is opened', (tester) async {
      final b = book();
      await show(tester, GuideSectionScreen(book: b, section: b.sections.first));
      _tapLink(tester, 'Two');
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('guide-section-${b.sections.last.slug}')), findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('an app link still opens that part of Cache, and no web link is opened', (tester) async {
      var screens = 0;
      appPlaceScreen = (p) {
        screens++;
        return p == AppPlace.storage ? const Scaffold(body: Center(child: Text('Storage screen'))) : null;
      };
      final b = GuideBook.parse(['# 9. Test\n\n## One\n\nOpen [Storage](cache://settings/storage).\n']);
      await show(tester, GuideSectionScreen(book: b, section: b.sections.single));
      _tapLink(tester, 'Storage');
      await tester.pumpAndSettle();
      expect(screens, greaterThan(0));
      expect(find.text('Storage screen'), findsOneWidget);
      expect(opened, isEmpty);
    });
  });

  group('credits', () {
    Future<void> showCredits(WidgetTester tester) => show(tester, CreditsPage(loader: () async => '[a site](https://example.org/x)'));

    testWidgets('online: a web link opens in the phone\'s browser', (tester) async {
      await showCredits(tester);
      _tapLink(tester, 'a site');
      await tester.pump();
      await tester.pump();
      expect(opened, ['https://example.org/x']);
      expect(find.text("You're offline"), findsNothing);
    });

    testWidgets('offline: "You\'re offline" with Copy link, in place; the browser is not called', (tester) async {
      probe.kind = ConnectionKind.none;
      await showCredits(tester);
      _tapLink(tester, 'a site');
      await tester.pump();
      await tester.pump();
      await offlineChecks(tester, 'https://example.org/x');
    });
  });

  group('Credits and licenses: the Source code address', () {
    Future<void> showAbout(WidgetTester tester) => show(tester, AboutPage(version: () async => '1.1.0'));

    testWidgets('online: the address opens in the phone\'s browser', (tester) async {
      await showAbout(tester);
      _tapLink(tester, kSourceUrl);
      await tester.pump();
      await tester.pump();
      expect(opened, [kSourceUrl]);
      expect(find.text("You're offline"), findsNothing);
    });

    testWidgets('offline: "You\'re offline" with Copy link, in place; the browser is not called', (tester) async {
      probe.kind = ConnectionKind.none;
      await showAbout(tester);
      _tapLink(tester, kSourceUrl);
      await tester.pump();
      await tester.pump();
      await offlineChecks(tester, kSourceUrl);
    });
  });
}
