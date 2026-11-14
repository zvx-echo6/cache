import 'dart:async';

import 'package:flutter/widgets.dart';

/// One thing Home's search found: shown with its module's icon, its name, and the module's name on the second line.
class AppSearchResult {
  const AppSearchResult({required this.title, required this.module, required this.icon, required this.score, required this.open, this.detail = ''});

  final String title;

  /// The module it comes from, in words ("Library", "Places", "Maps").
  final String module;
  final IconData icon;

  /// What follows the module's name on the second line ("Survival manuals, p. 112", "Idaho Falls · 2.1 mi").
  final String detail;

  /// 0..1, higher first. Results from every module are sorted together by it.
  final double score;
  final VoidCallback open;
}

/// One module's part of Home's search. A module adds itself by adding a provider; the search itself is app UI only and never a tool
/// the assistant has.
abstract class AppSearchProvider {
  /// The module's name, shown on each result's second line.
  String get module;

  /// The module's icon, shown on each result.
  IconData get icon;

  /// What this module has for [query], at most [limit]. A provider that cannot search right now (no core yet, no data) returns none.
  Future<List<AppSearchResult>> search(String query, {int limit = 8});
}

/// Home's search across every module: each provider is asked at once (in list order), and the results come back as one list, best
/// match first. A provider that fails, or runs past [timeout], adds nothing.
class AppSearch {
  AppSearch(this.providers, {this.timeout = const Duration(seconds: 4)});

  final List<AppSearchProvider> providers;
  final Duration timeout;

  /// [onPartial] gets the list so far each time a provider answers with something, so a fast module's results show while a slow
  /// one is still searching (a library's meaning search on a small server took 4.6 s and hid the places found in 6 ms). The
  /// returned list is the last of them, once every provider has answered or run out of time.
  Future<List<AppSearchResult>> search(String query, {int limit = 12, void Function(List<AppSearchResult> soFar)? onPartial}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final found = <AppSearchResult>[];
    List<AppSearchResult> best() {
      // equal scores keep the order they arrived in
      final order = {for (var i = 0; i < found.length; i++) found[i]: i};
      final all = [...found]..sort((a, b) => b.score == a.score ? order[a]!.compareTo(order[b]!) : b.score.compareTo(a.score));
      return all.take(limit).toList();
    }

    await Future.wait([
      for (final p in providers)
        p.search(q).timeout(timeout, onTimeout: () => const <AppSearchResult>[]).catchError((Object _) => const <AppSearchResult>[]).then((l) {
          if (l.isEmpty) return;
          found.addAll(l);
          onPartial?.call(best());
        }),
    ]);
    return best();
  }
}

/// How well [text] matches what was typed: 1 for the whole name, then a name that starts with it, a word that starts with it, and
/// a name that holds it; 0 for none. Every typed word must be there.
double textMatch(String text, String query) {
  final t = text.toLowerCase();
  final q = query.trim().toLowerCase();
  if (q.isEmpty || t.isEmpty) return 0;
  if (t == q) return 1;
  if (t.startsWith(q)) return 0.9;
  final words = q.split(RegExp(r'\s+'));
  if (!words.every(t.contains)) return 0;
  final starts = RegExp('(^|[^a-z0-9])${RegExp.escape(words.first)}');
  return starts.hasMatch(t) ? 0.75 : 0.6;
}
