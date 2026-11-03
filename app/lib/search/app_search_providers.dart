import 'package:cache_search/cache_search.dart' show GeoPoint, MapPlace, SearchHit;
import 'package:flutter/material.dart';

import '../browse/zim_urls.dart';
import '../pdf/pdf_address.dart';
import '../maps/layers/layer_def.dart';
import '../maps/maps_state.dart';
import '../nav/nav_backend.dart';
import '../sources/sources_state.dart';
import 'app_search.dart';
import '../platform/app_log.dart';

/// A result found by a search that ranks its own results: the best keeps most of its place, later ones less, and a name that
/// matches what was typed counts as much as its own rank.
double _ranked(int i, String title, String query) {
  final rank = (0.7 - 0.04 * i).clamp(0.2, 0.7);
  final m = textMatch(title, query);
  return m > rank ? m : rank;
}

/// A caption hit of the search core: a saved video's captions (`cap:`) or a ZIM's (`zimcap:`).
bool isCaptionHit(String address) => address.startsWith('cap:') || address.startsWith('zimcap:');

/// An EPUB hit of the search core (`zimepub:`): a passage of a book in a ZIM.
bool isEpubHit(String address) => address.startsWith('zimepub:');

/// The Library: the items by name, and the pages that match (the search core's search of the ZIMs and libraries): ZIM
/// pages, passages of PDFs, words said in videos (their captions) and passages of EPUB books.
class LibrarySearchProvider implements AppSearchProvider {
  LibrarySearchProvider({required this.sources, required this.openZim, required this.openAddress, this.openVideo, this.openPassage});

  final SourcesState sources;
  final void Function(ZimFile z) openZim;

  /// Opens a `zim:` page address in the reader.
  final void Function(String address) openAddress;

  /// Opens a video at a moment with that cue marked, as a cited video moment does (the hit's link, seconds and language).
  /// Null leaves caption hits out.
  final void Function(String link, double time, String? lang)? openVideo;

  /// Opens a reader address with a passage marked, as a cited passage does (an EPUB chapter at its `#cache-b` anchor and the
  /// passage's first words). Null leaves EPUB hits out.
  final void Function(String address, String quote)? openPassage;

  /// Where [h] opens, or null when this search cannot open it (it is then left out).
  VoidCallback? _opener(SearchHit h) {
    final link = h.link;
    if (isCaptionHit(h.address)) {
      final (open, time) = (openVideo, h.time);
      return open == null || link == null || time == null ? null : () => open(link, time, h.lang);
    }
    if (isEpubHit(h.address)) {
      final (open, quote) = (openPassage, h.quote);
      return open == null || link == null || quote == null ? null : () => open(link, quote);
    }
    if (!isZimAddress(h.address) && pdfEntryOfIndexHit(h.address) == null) return null;
    // A passage of a ZIM's PDF opens as its citation does: the PDF at the page with the passage marked ("Cited passage").
    if (pdfEntryOfIndexHit(h.address) != null && link != null && h.quote != null && openPassage != null) {
      final (open, quote) = (openPassage!, h.quote!);
      return () => open(link, quote);
    }
    // A hit on a page of a PDF entry opens the PDF at that page (a hit in a ZIM's PDF index: its PDF, at the printed page
    // when that is a number).
    return () {
      final a = pdfEntryOfIndexHit(h.address) ?? h.address;
      // The real PDF page the passage is on when the core says it (a ZIM's PDF index), else the printed page.
      final page = h.pdfPage ?? h.page;
      openAddress(page != null && isPdfAddress(a) && pdfPageOfAddress(a) == null ? withPdfPage(a, page) : a);
    };
  }

  /// The row's second line after the module: the collection the hit is in (the ZIM, or the saved video). A PDF passage's
  /// page is in its title already ("Handbook, p. 47"), and a saved video's name begins its caption hit's title ("<video>, at
  /// 1:04"), so neither is said twice.
  static String _detail(SearchHit h) => h.sourceTitle.isEmpty || h.title.startsWith(h.sourceTitle) ? '' : h.sourceTitle;

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
    final sw = Stopwatch()..start();
    final r = await sources.searchIn(query, k: limit);
    // the timing and count (Detailed); the words searched only at Everything
    logDetail('Library search: ${r.results.length} results in ${sw.elapsedMilliseconds} ms');
    logContent('Library search for "$query"');
    final hits = [
      for (final h in r.results)
        if (_opener(h) case final open?) (h, open),
    ];
    for (var i = 0; i < hits.length; i++) {
      final (h, open) = hits[i];
      out.add(AppSearchResult(title: h.title, module: module, icon: icon, detail: _detail(h), score: _ranked(i, h.title, query), open: open));
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
