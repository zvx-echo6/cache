import 'dart:io';

import 'package:cache/layout/adaptive.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The desktop width class: from 1280 the list is 380 and the detail up to 1400, a TwoPane with nothing chosen can open a page,
/// pages can take two columns and reading text keeps to about 70 characters. Below 1280 nothing changes.

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

class _List extends StatelessWidget {
  const _List();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Things')),
    body: ListView(children: [ListTile(title: const Text('Alpha'), onTap: () => openDetail(context, key: 'Alpha', builder: (_) => const _Page('Alpha')))]),
  );
}

class _Page extends StatelessWidget {
  const _Page(this.name);
  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(key: ValueKey('page-$name'), appBar: AppBar(title: Text('$name page')));
}

Future<void> _pumpPanes(WidgetTester tester, Size size) async {
  _window(tester, size);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(CacheThemeId.light),
    home: TwoPane(list: const _List(), desktopInitial: (_) => const _Page('Start')),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => PanePrefs.testDir = Directory.systemTemp.createTempSync('desk-panes-'));
  tearDown(() {
    PanePrefs.testDir?.deleteSync(recursive: true);
    PanePrefs.testDir = null;
  });

  test('the width classes and their names', () {
    expect(kDesktopMinWidth, 1280);
    expect(kDesktopListWidth, 380);
    expect(kDesktopDetailMaxWidth, 1400);
    expect(widthClassFor(639), WidthClass.compact);
    expect(widthClassFor(640), WidthClass.regular);
    expect(widthClassFor(1279), WidthClass.regular);
    expect(widthClassFor(1280), WidthClass.desktop);
    // A 12.9" iPad Pro held sideways is a desktop window.
    expect(widthClassFor(1366), WidthClass.desktop);
    expect(widthClassFor(1920), WidthClass.desktop);
  });

  testWidgets('under 1280 the panes are as before: list 340, detail 640, the placeholder while nothing is chosen', (tester) async {
    await _pumpPanes(tester, const Size(1279, 800));
    expect(tester.getSize(find.byType(_List)).width, kWideListWidth);
    expect(find.text('Choose an item'), findsOneWidget);
    expect(find.byKey(const ValueKey('page-Start')), findsNothing);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('page-Alpha'))).width, kDetailMaxWidth);
  });

  for (final size in [const Size(1920, 1080), const Size(1440, 900), const Size(1366, 1024)]) {
    testWidgets('at ${size.width.toInt()}x${size.height.toInt()}: list 380, the starting page, the detail up to 1400', (tester) async {
      await _pumpPanes(tester, size);
      expect(tester.getSize(find.byType(_List)).width, kDesktopListWidth);
      expect(find.text('Choose an item'), findsNothing);
      expect(find.byKey(const ValueKey('page-Start')), findsOneWidget);
      final detail = (size.width - kDesktopListWidth - 1).clamp(0, kDesktopDetailMaxWidth).toDouble();
      expect(tester.getSize(find.byKey(const ValueKey('page-Start'))).width, detail);
      // Choosing an item replaces the starting page.
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-Start')), findsNothing);
      expect(tester.getSize(find.byKey(const ValueKey('page-Alpha'))).width, detail);
    });
  }

  Future<void> pumpColumns(WidgetTester tester, Size window, double pageWidth) async {
    _window(tester, window);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: pageWidth,
            height: 400,
            child: const TwoColumn(left: SizedBox.expand(key: ValueKey('L')), right: SizedBox.expand(key: ValueKey('R')), narrow: SizedBox.expand(key: ValueKey('N'))),
          ),
        ),
      ),
    ));
  }

  testWidgets('TwoColumn: left about 36% (at least 380), right the rest; one column where it does not fit', (tester) async {
    await pumpColumns(tester, const Size(1920, 1080), 1400);
    expect(tester.getSize(find.byKey(const ValueKey('L'))).width, closeTo(1400 * 0.36, 0.01));
    expect(tester.getSize(find.byKey(const ValueKey('R'))).width, closeTo(1400 - 1400 * 0.36 - kTwoColumnGap, 0.01));
    expect(find.byKey(const ValueKey('N')), findsNothing);
    // A page of 1000 (36% would be 360): the left column is its minimum.
    await pumpColumns(tester, const Size(1440, 900), 1000);
    expect(tester.getSize(find.byKey(const ValueKey('L'))).width, kTwoColumnLeftMinWidth);
    expect(tester.getSize(find.byKey(const ValueKey('R'))).width, 1000 - kTwoColumnLeftMinWidth - kTwoColumnGap);
    // Too narrow a page, or any window under 1280: the page's own one column.
    await pumpColumns(tester, const Size(1920, 1080), kTwoColumnMinWidth - 1);
    expect(find.byKey(const ValueKey('N')), findsOneWidget);
    expect(find.byKey(const ValueKey('L')), findsNothing);
    await pumpColumns(tester, const Size(1279, 800), 900);
    expect(find.byKey(const ValueKey('N')), findsOneWidget);
  });

  Future<double> readingBoxWidth(WidgetTester tester, Size window) async {
    _window(tester, window);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ReadingWidth(style: TextStyle(fontSize: 16), child: SizedBox(key: ValueKey('text'), height: 20, width: double.infinity))),
    ));
    return tester.getSize(find.byKey(const ValueKey('text'))).width;
  }

  testWidgets('ReadingWidth keeps text to about 70 characters on a desktop window and leaves narrower windows alone', (tester) async {
    expect(await readingBoxWidth(tester, const Size(1279, 800)), 1279);
    final w = await readingBoxWidth(tester, const Size(1920, 1080));
    // 70 widths of "0" at 16 px (the test font's characters are about 16 px wide).
    expect(w, inInclusiveRange(70 * 15, 70 * 17));
    final ctx = tester.element(find.byKey(const ValueKey('text')));
    expect(ReadingWidth.maxWidthOf(ctx, style: const TextStyle(fontSize: 16)), closeTo(w, 0.5));
    expect(ReadingWidth.padFor(ctx, 1920, style: const TextStyle(fontSize: 16)).left, closeTo((1920 - w) / 2, 0.5));
    expect(ReadingWidth.padFor(ctx, 600, style: const TextStyle(fontSize: 16)).left, 16, reason: 'never less than the usual margin');
  });
}
