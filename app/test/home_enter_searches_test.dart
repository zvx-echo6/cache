// Enter in Home's search box searches (owner, 2026-11-13): the results show at once, the keyboard closes, the text stays, and Cache
// is not asked. Asking is the "Ask Cache" row of the results, or Ask itself.

import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/search/app_search.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A module that finds one book for any query, and counts the searches.
class _Books implements AppSearchProvider {
  var searches = <String>[];
  @override
  String get module => 'Library';
  @override
  IconData get icon => Icons.menu_book;
  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) async {
    searches.add(query);
    return [AppSearchResult(title: 'Water storage guide', module: module, icon: icon, score: 0.9, open: () {})];
  }
}

void main() {
  late Directory dir;
  late LayoutState layout;
  late _Books books;
  late List<String> asked;

  Future<void> show(WidgetTester tester, {bool askOn = true}) async {
    dir = Directory.systemTemp.createTempSync('home-enter');
    layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    books = _Books();
    asked = [];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: HomeScreen(
        layout: layout,
        onAsk: asked.add,
        onOpenSettings: () {},
        onOpenShortcut: (_) {},
        search: AppSearch([books]),
        askOn: askOn,
      ),
    ));
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }

  final field = find.byKey(const ValueKey('home-search'));

  testWidgets('Enter searches: the results show, the keyboard closes, the text stays, nothing is asked', (tester) async {
    await show(tester);
    expect(tester.widget<TextField>(field).textInputAction, TextInputAction.search, reason: "the keyboard's search key");
    await tester.tap(field);
    await tester.pump();
    tester.testTextInput.enterText('water storage');
    // Enter before the typing pause is over: the search runs at once
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    expect(asked, isEmpty, reason: 'Enter never asks Cache');
    expect(books.searches, contains('water storage'));
    expect(find.text('Water storage guide'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse, reason: 'the keyboard closes so the results can be seen');
    expect(tester.widget<TextField>(field).controller!.text, 'water storage');
    // the typing pause's own search finds nothing new and changes nothing
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Water storage guide'), findsOneWidget);
    expect(asked, isEmpty);
    await done(tester);
  });

  testWidgets('asking is still there: the "Ask Cache" row asks exactly what was typed', (tester) async {
    await show(tester);
    await tester.tap(field);
    await tester.pump();
    tester.testTextInput.enterText('how much water per person');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    expect(asked, isEmpty);
    final row = find.byKey(const ValueKey('search-ask'));
    expect(find.descendant(of: row, matching: find.text('Enter')), findsNothing, reason: 'no "Enter" hint on the row: Enter searches');
    await tester.tap(row);
    await tester.pump();
    expect(asked, ['how much water per person']);
    await done(tester);
  });

  testWidgets('with no chat model the box is the same: Enter searches', (tester) async {
    await show(tester, askOn: false);
    expect(tester.widget<TextField>(field).textInputAction, TextInputAction.search);
    await tester.tap(field);
    await tester.pump();
    tester.testTextInput.enterText('water');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    expect(find.text('Water storage guide'), findsOneWidget);
    expect(asked, isEmpty);
    await done(tester);
  });
}
