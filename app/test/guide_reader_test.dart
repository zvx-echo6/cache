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
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: page));
      await tester.pumpAndSettle();
    }

    tearDown(() {
      appPlaceScreen = null;
      openAppPlace = null;
    });

    testWidgets('chapters, then a chapter with its sections; search finds a section and opens it there', (tester) async {
      await show(tester, GuideReaderScreen(book: book));
      expect(find.text('Cache guide'), findsOneWidget);
      expect(find.text(book.chapters.first.heading), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guide-chapter-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('guide-section-${book.chapters.first.sections.first.slug}')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('guide-search')), 'kagi');
      await tester.pump();
      final kagi = book.byTitle('Cache guide: 4. Services and keys: Web search with Kagi')!;
      await tester.tap(find.byKey(ValueKey('guide-hit-${kagi.slug}')));
      await tester.pumpAndSettle();
      expect(find.text(kagi.chapter.heading), findsOneWidget);
      expect(find.byKey(ValueKey('guide-section-${kagi.slug}')).hitTestable(), findsOneWidget, reason: 'opened at the section');
    });

    testWidgets('an app link opens that screen over the guide; Back to the guide returns to the same place', (tester) async {
      var opened = 0;
      appPlaceScreen = (p) {
        opened++;
        return p == AppPlace.storage ? const Scaffold(body: Center(child: Text('Storage screen'))) : null;
      };
      final storage = book.byTitle('Cache guide: 3. Settings, page by page: Storage')!;
      await show(tester, GuideChapterScreen(book: book, chapter: storage.chapter, section: storage));
      final page = tester.state<GuideChapterScreenState>(find.byType(GuideChapterScreen));
      final at = page.scroll.offset;
      expect(at, greaterThan(0), reason: 'opened at the Storage section, down the chapter');
      _tapLink(tester, '"Settings" > "Storage"');
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(find.text('Storage screen'), findsOneWidget);
      expect(find.text('Back to the guide'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('back-to-guide')));
      await tester.pumpAndSettle();
      expect(find.text('Storage screen'), findsNothing);
      expect(page.scroll.offset, at, reason: 'the same chapter, scrolled to the same place');
    });

    testWidgets('a link to a place this version does not have says so, and nothing breaks', (tester) async {
      final b = GuideBook.parse(['# 9. Test\n\n## Somewhere\n\nGo to [Nowhere](cache://no/such/place).\n']);
      await show(tester, GuideChapterScreen(book: b, chapter: b.chapters.single));
      _tapLink(tester, 'Nowhere');
      await tester.pump();
      expect(find.text(kUnknownAppLink), findsOneWidget);
    });
  });
}
