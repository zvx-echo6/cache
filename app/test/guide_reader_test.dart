import 'dart:convert';
import 'dart:io';

import 'package:cache/guide/app_links.dart';
import 'package:cache/guide/guide_book.dart';
import 'package:cache/guide/guide_reader.dart';
import 'package:cache/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs Python (python3, python, or the Windows launcher py -3) with [args].
ProcessResult _python(List<String> args) {
  for (final (exe, pre) in [('python3', <String>[]), ('python', <String>[]), ('py', ['-3'])]) {
    try {
      return Process.runSync(exe, [...pre, ...args]);
    } on ProcessException {
      continue;
    }
  }
  throw StateError('Python 3 is needed to check the guide against tools/guide');
}

/// Taps the Markdown link whose words contain [text] (a link is a span of the rendered text, with its own tap).
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

List<String> _chapters() => [for (var i = 1; i <= kGuideChapterCount; i++) File('assets/guide/chapters/ch$i.md').readAsStringSync()];

void main() {
  late GuideBook book;
  setUpAll(() => book = GuideBook.parse(_chapters()));

  group('the guide that ships in the app', () {
    test('its chapters are the guide the search library is built from (docs/guide), byte for byte', () {
      final docs = Directory('../docs/guide').listSync().whereType<File>().where((f) => RegExp(r'ch\d+\.md$').hasMatch(f.path)).length;
      expect(docs, kGuideChapterCount);
      for (var i = 1; i <= kGuideChapterCount; i++) {
        expect(File('assets/guide/chapters/ch$i.md').readAsStringSync(), File('../docs/guide/ch$i.md').readAsStringSync(), reason: 'ch$i.md: copy docs/guide again');
      }
    });

    test('its sections are exactly the titles tools/guide/guide_titles.py gives', () {
      final r = _python(['-I', '../tools/guide/guide_titles.py']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final titles = ((jsonDecode(r.stdout as String) as Map)['titles'] as List).cast<String>();
      expect([for (final s in book.sections) s.title], titles);
    });

    test('a citation of a section (its library address) finds it, as the library\'s own ids are made', () {
      final s = book.byTitle('Cache guide: 1. Getting started: Choose a model')!;
      final r = _python(['-I', '-c', "import uuid;print(uuid.uuid5(uuid.UUID('c4b95b91-e641-5c16-91a0-13ba2f6f7970'),'getting-started--choose-a-model:1:0'))"]);
      expect(s.address, 'lib:cache-guide/${(r.stdout as String).trim()}');
      expect(book.byAddress(s.address), same(s));
    });

    test('every cache:// link in the guide goes to a place in this version', () {
      final links = <String>[];
      for (final f in Directory('../docs/guide').listSync().whereType<File>().where((f) => f.path.endsWith('.md'))) {
        links.addAll(RegExp(r'\]\((cache://[^)]*)\)').allMatches(f.readAsStringSync()).map((m) => m.group(1)!));
      }
      expect(links, isNotEmpty, reason: 'the example link in "Storage"');
      for (final l in links) {
        expect(appPlaceOf(l), isNotNull, reason: l);
      }
      expect(appPlaceOf('cache://settings/storage'), AppPlace.storage);
      expect(appPlaceOf('cache://no/such/place'), isNull);
    });

    test('"the section X" names become links to that section', () {
      final s = book.linkSections('A source that needs a key. See the section Keys for data sources.');
      expect(s, contains('[Keys for data sources](#'));
      expect(book.bySlug(RegExp(r'\(#([^)]+)\)').firstMatch(s)!.group(1)!)!.heading, 'Keys for data sources');
    });
  });

  group('the reader', () {
    Future<void> show(WidgetTester tester, Widget page) async {
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: page));
      await tester.pumpAndSettle();
    }

    tearDown(() {
      appPlaceScreen = null;
      openAppPlace = null;
      askCacheInstead = null;
    });

    testWidgets('contents: chapters open to their sections; a section opens on its own page', (tester) async {
      await show(tester, GuideReaderScreen(book: book));
      final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
      expect(find.text('Cache guide'), findsOneWidget);
      final first = book.chapters.first.sections.first;
      expect(find.byKey(ValueKey('guide-toc-${first.slug}')), findsOneWidget, reason: 'the first chapter starts open');
      final second = book.chapters[1];
      expect(find.byKey(ValueKey('guide-toc-${second.sections.first.slug}')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('guide-chapter-2')), 300, scrollable: list);
      await tester.tap(find.byKey(const ValueKey('guide-chapter-2')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(ValueKey('guide-toc-${second.sections.first.slug}')), 200, scrollable: list);
      await tester.tap(find.byKey(ValueKey('guide-toc-${second.sections.first.slug}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('guide-section-${second.sections.first.slug}')), findsOneWidget);
      expect(find.text('1 of ${second.sections.length}'), findsOneWidget);
    });

    testWidgets('a section page: Previous, where it is in its chapter, Next; search and contents in the top bar', (tester) async {
      final c = book.chapters.first;
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: GuideReaderScreen(book: book)));
      await tester.tap(find.byKey(ValueKey('guide-toc-${c.sections[1].slug}')));
      await tester.pumpAndSettle();
      expect(find.text('2 of ${c.sections.length}'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guide-next')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('guide-section-${c.sections[2].slug}')), findsOneWidget);
      expect(find.text('3 of ${c.sections.length}'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guide-previous')));
      await tester.pumpAndSettle();
      expect(find.text('2 of ${c.sections.length}'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guide-section-contents')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-search')), findsOneWidget, reason: 'back on the contents');
      expect(find.byType(GuideSectionScreen), findsNothing);
    });

    testWidgets('search: one line per match with the words around it; nothing found offers Ask Cache instead', (tester) async {
      String? asked;
      askCacheInstead = (q) => asked = q;
      await show(tester, GuideReaderScreen(book: book));
      await tester.enterText(find.byKey(const ValueKey('guide-search')), 'kagi');
      await tester.pump();
      final kagi = book.byTitle('Cache guide: 4. Services and keys: Web search with Kagi')!;
      await tester.tap(find.byKey(ValueKey('guide-hit-${kagi.slug}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('guide-section-${kagi.slug}')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('guide-search')), 'zzqx nothing like this');
      await tester.pump();
      expect(find.byKey(const ValueKey('guide-no-hits')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guide-ask-instead')));
      expect(asked, 'zzqx nothing like this');
    });

    test('a search line shows the words around the match, without Markdown', () {
      final b = GuideBook.parse(['# 9. Test\n\n## Space\n\nOpen [Storage](cache://settings/storage) and tap "Clean up" to free storage on the phone.\n']);
      final line = guideSnippet(b.sections.single, 'storage')!;
      expect(line.map((p) => p.$1).join(), 'Open Storage and tap Clean up to free storage on the phone.');
      expect([for (final p in line) if (p.$2) p.$1], ['Storage', 'storage']);
    });

    test('quoted labels are marked as labels, never inside code', () {
      final b = GuideBook.parse(['# 9. Test\n\n## A\n\nx\n']);
      expect(guideMarkdown(b, 'Tap "Set up Cache" on "Home".'), 'Tap ~~Set up Cache~~ on ~~Home~~.');
      expect(guideMarkdown(b, 'Type `"quoted"` then "Save".'), 'Type `"quoted"` then ~~Save~~.');
      expect(guideMarkdown(b, '```\n"left alone"\n```'), '```\n"left alone"\n```');
      expect(guideMarkdown(b, 'A quote " with spaces " stays.'), 'A quote " with spaces " stays.');
      expect(guideMarkdown(b, 'Go to ["Settings" > "Storage"](cache://settings/storage).'), 'Go to [Settings > Storage](cache://settings/storage).');
    });

    testWidgets('labels show without their quotes, as bold chips in the line; links are underlined in the text', (tester) async {
      final b = GuideBook.parse(['# 9. Test\n\n## Labels\n\nOn "Home", open [the "Storage" page](cache://settings/storage).\n']);
      await show(tester, GuideSectionScreen(book: b, section: b.sections.single));
      final spans = <InlineSpan>[];
      for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
        rt.text.visitChildren((s) {
          spans.add(s);
          return true;
        });
      }
      final text = spans.whereType<TextSpan>().map((s) => s.text ?? '').join();
      expect(text, isNot(contains('"')));
      expect(spans.whereType<WidgetSpan>(), hasLength(1), reason: 'Home is a chip in the line');
      final chip = tester.widget<Text>(find.text('Home'));
      expect(chip.style?.fontWeight, FontWeight.w600);
      // A label inside a link stays part of the link: its words, one tap.
      final link = spans.whereType<TextSpan>().firstWhere((s) => (s.text ?? '').contains('the Storage page'));
      expect(link.style?.decoration, TextDecoration.underline);
    });

    testWidgets('a screenshot shows its picture with the caption under it, and the caption is what a screen reader says', (tester) async {
      final semantics = tester.ensureSemantics();
      final b = GuideBook.parse(['# 9. Test\n\n## Shots\n\nBefore.\n\n![The Regions sheet](shot:regions-sheet)\n\nAfter.\n']);
      await show(tester, GuideSectionScreen(book: b, section: b.sections.single));
      await tester.runAsync(() => precacheImage(const AssetImage('$kGuideShotsDir/regions-sheet.png'), tester.element(find.byType(GuideSectionScreen))));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-shot-regions-sheet')), findsOneWidget);
      expect(find.text('The Regions sheet'), findsOneWidget);
      expect(find.bySemanticsLabel('The Regions sheet'), findsOneWidget, reason: 'read once, as the picture');
      semantics.dispose();
    });

    testWidgets('a picture missing from the build leaves nothing, not a caption on its own', (tester) async {
      final b = GuideBook.parse(['# 9. Test\n\n## Shots\n\nBefore.\n\n![Not in this build](shot:no-such-picture)\n\nAfter.\n']);
      await show(tester, GuideSectionScreen(book: b, section: b.sections.single));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.text('Not in this build'), findsNothing);
      expect(find.textContaining('After.', findRichText: true), findsOneWidget);
    });

    test('every screenshot a chapter shows is bundled', () {
      final ids = {
        for (final c in _chapters())
          for (final m in RegExp(r'!\[[^\]]*\]\(shot:([^)]*)\)').allMatches(c)) m.group(1)!,
      };
      for (final id in ids) {
        expect(File('$kGuideShotsDir/$id.png').existsSync(), isTrue, reason: 'assets/guide/shots/$id.png');
      }
    });

    testWidgets('an app link opens that screen over the guide; Back to the guide returns to the same place', (tester) async {
      var opened = 0;
      appPlaceScreen = (p) {
        opened++;
        return p == AppPlace.storage ? const Scaffold(body: Center(child: Text('Storage screen'))) : null;
      };
      final b = GuideBook.parse(['# 9. Test\n\n## Long\n\n${'A line of text.\n\n' * 60}Open [Storage](cache://settings/storage).\n']);
      await show(tester, GuideSectionScreen(book: b, section: b.sections.single));
      final page = tester.state<GuideSectionScreenState>(find.byType(GuideSectionScreen));
      await tester.scrollUntilVisible(find.textContaining('Storage', findRichText: true), 300);
      final at = page.scroll.offset;
      expect(at, greaterThan(0));
      _tapLink(tester, 'Storage');
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(find.text('Storage screen'), findsOneWidget);
      expect(find.text('Back to the guide'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('back-to-guide')));
      await tester.pumpAndSettle();
      expect(find.text('Storage screen'), findsNothing);
      expect(page.scroll.offset, at, reason: 'the same section, scrolled to the same place');
    });

    testWidgets('a link to a place this version does not have says so, and nothing breaks', (tester) async {
      final b = GuideBook.parse(['# 9. Test\n\n## Somewhere\n\nGo to [Nowhere](cache://no/such/place).\n']);
      await show(tester, GuideSectionScreen(book: b, section: b.sections.single));
      _tapLink(tester, 'Nowhere');
      await tester.pump();
      expect(find.text(kUnknownAppLink), findsOneWidget);
    });
  });
}
