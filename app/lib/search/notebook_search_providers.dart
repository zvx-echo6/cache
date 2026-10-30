import 'package:flutter/material.dart';

import '../notebook/notebook_model.dart';
import '../notebook/notebook_state.dart';
import '../notebook/notebook_text.dart';
import '../notebook/places.dart';
import 'app_search.dart';

/// The rank a search hit keeps by its place in the store's list (best match first), or the name's match when that is higher.
double _ranked(int i, String title, String query) {
  final rank = (0.7 - 0.04 * i).clamp(0.2, 0.7);
  final m = textMatch(title, query);
  return m > rank ? m : rank;
}

/// Notebooks: the notebooks by name, and the entries that match (the store's keyword search), except places, which the Places
/// provider lists.
class NotebooksSearchProvider implements AppSearchProvider {
  NotebooksSearchProvider({required this.notebook, required this.openNotebook, required this.openEntry, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final NotebookState notebook;
  final void Function(Notebook n) openNotebook;
  final void Function(Notebook n, NbEntry e) openEntry;
  final DateTime Function() _now;

  @override
  String get module => 'Notebooks';

  @override
  IconData get icon => Icons.book_outlined;

  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) async {
    await notebook.start();
    final out = <AppSearchResult>[
      for (final n in notebook.notebooks)
        if (textMatch(n.name, query) case final m when m > 0)
          AppSearchResult(title: n.name, module: module, icon: icon, detail: 'notebook', score: m, open: () => openNotebook(n)),
    ];
    final hits = [for (final h in await notebook.search(query)) if (notebook.notebook(h.entry.notebookId) case final n? when !n.isPlaces) (h, n)];
    for (var i = 0; i < hits.length && i < limit; i++) {
      final (h, n) = hits[i];
      final title = entryTitle(h.entry);
      out.add(AppSearchResult(
        title: title,
        module: module,
        icon: icon,
        detail: '${n.name} · ${dayText(h.entry.when, now: _now())}',
        score: _ranked(i, title, query),
        open: () => openEntry(n, h.entry),
      ));
    }
    return out;
  }
}

/// Places: the places of the Places notebooks that match, nearest first among equals.
class NotebookPlacesSearchProvider implements AppSearchProvider {
  NotebookPlacesSearchProvider({required this.notebook, required this.open, this.here, this.distance});

  final NotebookState notebook;
  final void Function(Notebook n, NbEntry e) open;
  final ({double lat, double lon})? Function()? here;

  /// "2.1 mi" for a distance in metres.
  final String Function(double metres)? distance;

  @override
  String get module => 'Places';

  @override
  IconData get icon => Icons.place_outlined;

  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) async {
    await notebook.start();
    final h = here?.call();
    final hits = [for (final x in await notebook.search(query)) if (notebook.notebook(x.entry.notebookId) case final n? when n.isPlaces) (x, n)];
    return [
      for (var i = 0; i < hits.length && i < limit; i++)
        () {
          final (x, n) = hits[i];
          final e = x.entry;
          final title = entryTitle(e);
          final d = h == null || e.place == null || distance == null ? null : distance!(distanceM(h.lat, h.lon, e.place!.lat, e.place!.lon));
          return AppSearchResult(
            title: title,
            module: module,
            icon: icon,
            detail: [n.name, ?d].join(' · '),
            // A saved place is a name the person gave: it ranks above the map's places with the same score.
            score: (_ranked(i, title, query) + 0.05).clamp(0, 1).toDouble(),
            open: () => open(n, e),
          );
        }(),
    ];
  }
}
