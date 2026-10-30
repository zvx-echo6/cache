import 'package:cache_search/cache_search.dart' show GeoPoint, MapPlace;
import 'package:flutter/material.dart';

import '../browse/zim_urls.dart';
import '../maps/layers/layer_def.dart';
import '../maps/maps_state.dart';
import '../nav/nav_backend.dart';
import '../sources/sources_state.dart';
import 'app_search.dart';

/// A result found by a search that ranks its own results: the best keeps most of its place, later ones less, and a name that
/// matches what was typed counts as much as its own rank.
double _ranked(int i, String title, String query) {
  final rank = (0.7 - 0.04 * i).clamp(0.2, 0.7);
  final m = textMatch(title, query);
  return m > rank ? m : rank;
}

/// The Library: the items by name, and the pages that match (the search core's search of the ZIMs and libraries).
class LibrarySearchProvider implements AppSearchProvider {
  LibrarySearchProvider({required this.sources, required this.openZim, required this.openAddress});

  final SourcesState sources;
  final void Function(ZimFile z) openZim;

  /// Opens a `zim:` page address in the reader.
  final void Function(String address) openAddress;

  @override
  String get module => 'Library';

  @override
  IconData get icon => Icons.menu_book_outlined;

  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) async {
    final out = <AppSearchResult>[
      for (final z in sources.zims)
        if (textMatch(sources.titleOf(z), query) case final m when m > 0)
          AppSearchResult(title: sources.titleOf(z), module: module, icon: icon, score: m, open: () => openZim(z)),
    ];
    if (!sources.coreReady) return out;
    final r = await sources.searchIn(query, k: limit);
    final hits = [for (final h in r.results) if (isZimAddress(h.address)) h];
    for (var i = 0; i < hits.length; i++) {
      final h = hits[i];
      out.add(AppSearchResult(
        title: h.title,
        module: module,
        icon: icon,
        detail: [h.sourceTitle, if (h.page != null) 'p. ${h.page}'].where((s) => s.isNotEmpty).join(', '),
        score: _ranked(i, h.title, query),
        open: () => openAddress(h.address),
      ));
    }
    return out;
  }
}

/// Places and addresses: the map's own place search, nearest to where the phone is.
class PlacesSearchProvider implements AppSearchProvider {
  PlacesSearchProvider({required this.backend, required this.near, required this.open, this.distance});

  final MapBackend backend;
  final GeoPoint? Function() near;
  final void Function(MapPlace p) open;

  /// "2.1 mi" for a distance in metres.
  final String Function(double metres)? distance;

  @override
  String get module => 'Places';

  @override
  IconData get icon => Icons.place_outlined;

  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) async {
    if (!backend.available) return const [];
    final r = await backend.search(query, near: near(), limit: limit);
    return [
      for (var i = 0; i < r.results.length; i++)
        () {
          final p = r.results[i];
          final d = p.distanceM;
          return AppSearchResult(
            title: p.name,
            module: module,
            icon: icon,
            detail: [if (p.address.isNotEmpty) p.address else if (p.kind.isNotEmpty) p.kind, if (d != null && distance != null) distance!(d)].join(' · '),
            score: _ranked(i, p.name, query),
            open: () => open(p),
          );
        }(),
    ];
  }
}

/// Maps: the layers by name (opening one shows it on the map).
class LayersSearchProvider implements AppSearchProvider {
  LayersSearchProvider({required this.maps, required this.open});

  final MapsState maps;
  final void Function(LayerDef layer) open;

  @override
  String get module => 'Maps';

  @override
  IconData get icon => Icons.layers_outlined;

  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) async => [
    for (final l in maps.catalogueLayers)
      if (_score(l, query) case final m when m > 0)
        AppSearchResult(title: l.title, module: module, icon: icon, detail: 'layer', score: m, open: () => open(l)),
  ].take(limit).toList();

  /// The name first; the description counts for less.
  static double _score(LayerDef l, String query) {
    final t = textMatch(l.title, query);
    return t > 0 ? t : textMatch(l.description, query) * 0.6;
  }
}
