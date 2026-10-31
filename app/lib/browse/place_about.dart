import '../sources/sources_state.dart';

/// Where a place's Wikipedia article is on this phone.
enum AboutState {
  /// In an installed English Wikipedia: "Read about it" opens it.
  here,

  /// A Wikipedia is installed but none has the article (an older or a smaller one): the card shows no button.
  missing,

  /// No English Wikipedia on the phone: the summary stays, with "Get Wikipedia" instead of the button.
  noWikipedia,
}

/// "Read about it" on a place card: finds a place's article (its Wikipedia title) in the phone's Wikipedia, the way the
/// assistant's `read` does (S14: the first installed English Wikipedia that has it; the title with spaces as underscores is the
/// article's path), and opens it in the Library's reader.
abstract class PlaceAbout {
  /// Where the article [title] is, and its `zim:` address when it is [AboutState.here].
  Future<({AboutState state, String? address})> lookUp(String title);

  /// Opens [address] in the reader (back returns to the map with the card).
  Future<void> open(String address);

  /// Library > Add, where Wikipedia is downloaded.
  void getWikipedia();

  /// The Library (to update Wikipedia).
  void openLibrary();
}

/// The `zim:` address of [path] in ZIM [id], escaped as the core writes them (a % or # in a path).
String zimArticleAddress(String id, String path) => 'zim:$id/${path.replaceAll('%', '%25').replaceAll('#', '%23')}';

/// [PlaceAbout] over the phone's Library.
class LibraryPlaceAbout implements PlaceAbout {
  LibraryPlaceAbout({required this.sources, required this.openReader, required this.onGetWikipedia, required this.onOpenLibrary});

  final SourcesState sources;
  final Future<void> Function(ZimFile zim, String address) openReader;
  final void Function() onGetWikipedia;
  final void Function() onOpenLibrary;

  /// The installed English Wikipedias (Kiwix's book name starts with `wikipedia_en`: the whole one or a subset), in Library order.
  List<ZimFile> get wikipedias => [
    for (final z in sources.zims)
      if ((sources.originOf(z)?.name ?? z.name).toLowerCase().startsWith('wikipedia_en')) z,
  ];

  @override
  Future<({AboutState state, String? address})> lookUp(String title) async {
    final list = wikipedias;
    if (list.isEmpty) return (state: AboutState.noWikipedia, address: null);
    final path = title.replaceAll(' ', '_');
    for (final z in list) {
      final id = sources.idOf(z);
      if (id == null) continue;
      final address = zimArticleAddress(id, path);
      try {
        await sources.zimGet(address);
        return (state: AboutState.here, address: address);
      } catch (_) {
        // Not in this one: the next.
      }
    }
    return (state: AboutState.missing, address: null);
  }

  @override
  Future<void> open(String address) async {
    final id = RegExp(r'^zim:([^/]+)/').firstMatch(address)?.group(1);
    final z = id == null ? null : sources.zimById(id.toLowerCase());
    if (z == null) throw StateError('not on this phone');
    await openReader(z, address);
  }

  @override
  void getWikipedia() => onGetWikipedia();

  @override
  void openLibrary() => onOpenLibrary();
}
