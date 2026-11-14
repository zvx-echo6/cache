// AppSearch hands each module's answer over as it arrives (PM, 2026-11-14), so Home can show a fast module's results while a slow
// one is still searching.

import 'package:cache/search/app_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Module implements AppSearchProvider {
  _Module(this.module, this.titles, {required this.after});
  @override
  final String module;
  final List<String> titles;
  final Duration after;
  @override
  IconData get icon => Icons.place_outlined;
  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) =>
      Future.delayed(after, () => [for (final t in titles) AppSearchResult(title: t, module: module, icon: icon, score: 0.8, open: () {})]);
}

void main() {
  test('AppSearch hands over each answer as it arrives, best first, and returns the whole list', () async {
    final slow = _Module('Library', ['Slow'], after: const Duration(milliseconds: 40));
    final fast = _Module('Places', ['Fast'], after: const Duration(milliseconds: 5));
    final partial = <List<String>>[];
    final all = await AppSearch([slow, fast]).search('q', onPartial: (l) => partial.add([for (final r in l) r.title]));
    expect(partial, [
      ['Fast'],
      ['Fast', 'Slow'],
    ]);
    expect([for (final r in all) r.title], ['Fast', 'Slow']);
  });
}
