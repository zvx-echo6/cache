// Home's search shows each module's results as they arrive (PM, 2026-11-14): a slow module (a library's meaning search on a small
// server took 4.6 s) no longer hides what a fast one found, and while one is still searching Home says nothing is found only when
// every module has answered. A module that runs past the time limit just doesn't appear.

import 'dart:async';
import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/search/app_search.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A module that answers [after] the search starts with [titles] (or never, when [after] is null).
class _Module implements AppSearchProvider {
  _Module(this.module, this.titles, {this.after});
  @override
  final String module;
  final List<String> titles;
  final Duration? after;
  @override
  IconData get icon => Icons.place_outlined;
  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) {
    final found = [for (final t in titles) AppSearchResult(title: t, module: module, icon: icon, score: 0.8, open: () {})];
    final wait = after;
    if (wait == null) return Completer<List<AppSearchResult>>().future;
    return Future.delayed(wait, () => found);
  }
}

void main() {
  late Directory dir;
  late LayoutState layout;

  Future<void> show(WidgetTester tester, AppSearch search) async {
    dir = Directory.systemTemp.createTempSync('home-arrive');
    layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: HomeScreen(layout: layout, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}, search: search, askOn: true),
    ));
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }

  final field = find.byKey(const ValueKey('home-search'));
  final nothing = find.byKey(const ValueKey('search-nothing'));
  final searching = find.byKey(const ValueKey('search-searching'));

  testWidgets('a slow module does not hide what a fast one found', (tester) async {
    final slowLibrary = _Module('Library', ['A slow passage'], after: const Duration(seconds: 3));
    final places = _Module('Places', ['Hilo International Airport'], after: const Duration(milliseconds: 10));
    await show(tester, AppSearch([slowLibrary, places]));
    await tester.tap(field);
    tester.testTextInput.enterText('hilo');
    // the typing pause, then the fast module's answer
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Hilo International Airport'), findsOneWidget, reason: 'the place shows while the library is still searching');
    expect(nothing, findsNothing, reason: 'not "Nothing found" while a module is still searching');
    expect(searching, findsOneWidget, reason: 'one module is still searching');
    // the slow module answers: its result joins the list and the search is over
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('A slow passage'), findsOneWidget);
    expect(find.text('Hilo International Airport'), findsOneWidget);
    expect(searching, findsNothing);
    await done(tester);
  });

  testWidgets('"Nothing found" waits for every module; one past the time limit just does not appear', (tester) async {
    final never = _Module('Library', ['Never shown']);
    final empty = _Module('Places', const [], after: const Duration(milliseconds: 10));
    await show(tester, AppSearch([never, empty], timeout: const Duration(seconds: 4)));
    await tester.tap(field);
    tester.testTextInput.enterText('nowhere');
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump(const Duration(milliseconds: 20));
    expect(nothing, findsNothing, reason: 'the library has not answered yet');
    expect(searching, findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(nothing, findsOneWidget, reason: 'every module answered or ran out of time, and none found anything');
    expect(searching, findsNothing);
    expect(find.text('Never shown'), findsNothing);
    await done(tester);
  });
}
