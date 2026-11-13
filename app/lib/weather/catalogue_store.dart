import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../net/fetch.dart' as net;
import '../platform.dart' as plat;
import 'catalogue.dart';
import 'connector.dart';
import 'weather_files.dart';

/// The answer to an address: the bytes. Throws [NetworkProblem] when the address cannot be read.
typedef FetchBytes = Future<List<int>> Function(Uri url);

/// Checks one definition with the core. Throws [CatalogueException] saying why it is refused.
typedef DefinitionChecker = Future<void> Function(String definitionText);

/// The address could not be read (no connection, a server error): the catalogue that was there stays as it is.
class NetworkProblem extends CatalogueException {
  const NetworkProblem(super.message);
}

/// The real fetch (net/fetch.dart: HTTPS or this phone, timeouts, a size cap, no key or cookie), its failures said as weather says them.
Future<List<int>> fetchBytes(Uri url, {int maxBytes = 4 * 1024 * 1024}) async {
  try {
    try {
      return await net.fetchBytes(url, maxBytes: maxBytes);
    } on net.FetchException catch (e) {
      // In a browser Cache Server reads only the published catalogue hosts for this call. A list, or a definition in it, that the
      // person pointed at another https address is an address they typed: read it as that kind (the phone reads any https itself).
      if (!plat.isWeb || e.failure != net.FetchFailure.notAllowed) rethrow;
      return await net.fetchBytes(url, maxBytes: maxBytes, scope: net.FetchScope.user);
    }
  } on net.FetchException catch (e) {
    throw NetworkProblem(switch (e.failure) {
      net.FetchFailure.notAllowed => 'Cache only reads https addresses.',
      net.FetchFailure.status => '${url.host} answered with an error (HTTP ${e.status}).',
      net.FetchFailure.tooLarge => 'The file is larger than expected.',
      net.FetchFailure.timedOut => "Couldn't reach ${url.host}.",
      net.FetchFailure.unreachable => "Couldn't reach ${url.host}. Check your connection.",
      net.FetchFailure.insecure => "Couldn't make a secure connection to ${url.host}.",
      net.FetchFailure.unreadable => "Couldn't read from ${url.host}.",
    });
  }
}

/// A catalogue downloaded and checked: the connectors that passed, and the ones that did not with the reason.
class LoadedCatalogue {
  LoadedCatalogue({required this.url, required this.catalogue, required this.definitions, required this.skipped, DateTime? at}) : fetchedAt = at ?? DateTime.now();

  final String url;
  final Catalogue catalogue;

  /// Entry id to the definition text, for the connectors that passed.
  final Map<String, String> definitions;

  /// Entry id to why it was left out.
  final Map<String, String> skipped;
  final DateTime fetchedAt;

  List<Connector> get connectors => [
    for (final e in catalogue.entries)
      if (definitions[e.id] != null) Connector.parse(definitions[e.id]!, entry: e, origin: Origin.catalogue(catalogue.id, catalogue.title)),
  ];
}

/// Downloads a catalogue and its definitions, checking each definition before it is accepted.
class CatalogueLoader {
  CatalogueLoader({required this.fetch, required this.check, DateTime Function()? now}) : now = now ?? DateTime.now;

  final FetchBytes fetch;
  final DefinitionChecker check;

  /// The clock the download time is taken from (the app's clock, so "more than a day old" is measured on one clock).
  final DateTime Function() now;

  /// A definition that is not valid is left out with its reason; a definition that cannot be downloaded fails the whole load
  /// ([NetworkProblem]), so a bad connection never leaves a half catalogue.
  Future<LoadedCatalogue> load(String address) async {
    final url = Uri.tryParse(address.trim());
    if (url == null || !isAllowedAddress(url)) throw const CatalogueException('Enter an address that starts with https://');
    return loadText(utf8.decode(await fetch(url), allowMalformed: true), address.trim());
  }

  /// [load] for a list already read ([text], from a file or a link): its definitions are downloaded from its base address and
  /// checked. [url] is what the list is kept under.
  Future<LoadedCatalogue> loadText(String text, String url) async {
    final cat = Catalogue.parse(text);
    final defs = <String, String>{};
    final skipped = <String, String>{};
    for (final e in cat.entries) {
      final bytes = await fetch(cat.definitionUrl(e));
      if (e.sha256 != null && sha256.convert(bytes).toString() != e.sha256) {
        skipped[e.id] = 'The file is not the one the list names (its checksum differs).';
        continue;
      }
      final defText = utf8.decode(bytes, allowMalformed: true);
      try {
        final c = Connector.parse(defText);
        if (c.id != e.id) throw CatalogueException('The file is for "${c.id}", not "${e.id}".');
        await check(defText);
      } on CatalogueException catch (x) {
        skipped[e.id] = x.message;
        continue;
      }
      defs[e.id] = defText;
    }
    return LoadedCatalogue(url: url, catalogue: cat, definitions: defs, skipped: skipped, at: now());
  }
}

/// Catalogues kept on the phone, one folder each: the catalogue.json, its definitions and a note of what was left out. A new copy
/// replaces the old one whole; removing a catalogue removes its folder.
class CatalogueStore {
  CatalogueStore(Directory root) : files = IoFiles(root), _root = root;

  /// The folder kept in a browser: on Cache Server, reached through [WeatherFiles].
  CatalogueStore.files(this.files) : _root = null;

  /// Where the catalogues and the small files beside them (the saved places, what was last shown) are kept.
  final WeatherFiles files;
  final Directory? _root;

  /// The folder on a phone; a browser keeps its files on the server and has none.
  Directory get root => _root ?? (throw UnsupportedError('The catalogues are kept on Cache Server'));

  String folderOf(String url) => sha256.convert(utf8.encode(url)).toString().substring(0, 12);

  /// Replaces what is kept for [loaded.url] with [loaded].
  void save(LoadedCatalogue loaded) {
    files.makeFolder('');
    final dir = folderOf(loaded.url);
    final fresh = '$dir.new';
    if (files.exists(fresh)) files.delete(fresh);
    files.makeFolder('$fresh/defs');
    files.write('$fresh/catalogue.json', jsonEncode(_catalogueJson(loaded.catalogue)));
    for (final e in loaded.definitions.entries) {
      files.write('$fresh/defs/${e.key}.json', e.value);
    }
    files.write('$fresh/meta.json', jsonEncode({
      'url': loaded.url,
      'fetched_at': loaded.fetchedAt.toIso8601String(),
      'skipped': loaded.skipped,
    }));
    if (files.exists(dir)) files.delete(dir);
    files.rename(fresh, dir);
  }

  void remove(String url) => files.delete(folderOf(url));

  /// Every catalogue kept, read back from disk.
  List<LoadedCatalogue> loadAll() {
    final out = <LoadedCatalogue>[];
    for (final d in files.folders('')) {
      if (d.endsWith('.new')) {
        try {
          files.delete(d);
        } catch (_) {}
        continue;
      }
      try {
        final meta = jsonDecode(files.read('$d/meta.json')!) as Map<String, dynamic>;
        final cat = Catalogue.parse(files.read('$d/catalogue.json')!);
        final defs = <String, String>{};
        for (final e in cat.entries) {
          final text = files.read('$d/defs/${e.id}.json');
          if (text != null) defs[e.id] = text;
        }
        out.add(LoadedCatalogue(
          url: meta['url'] as String,
          catalogue: cat,
          definitions: defs,
          skipped: ((meta['skipped'] as Map?) ?? const {}).cast<String, String>(),
          at: DateTime.tryParse(meta['fetched_at'] as String? ?? ''),
        ));
      } catch (_) {
        // A damaged folder is ignored; the next refresh writes it again.
      }
    }
    return out;
  }

  Map<String, dynamic> _catalogueJson(Catalogue c) => {
    'format': kCatalogueFormat,
    'id': c.id,
    'title': c.title,
    'maintainer': c.maintainer,
    'homepage': c.homepage,
    'base_url': c.baseUrl.toString(),
    'updated': c.updated,
    'connectors': [for (final e in c.entries) catalogueEntryJson(e)],
  };
}

/// One source of a list in the list's format (CatalogueEntry.fromJson reads it back).
Map<String, dynamic> catalogueEntryJson(CatalogueEntry e) => {
  'id': e.id,
  'title': e.title,
  'description': e.description,
  'category': e.category,
  'provider': e.provider,
  'coverage': e.coverage,
  'needs_key': e.needsKey,
  if (e.keyAlias != null) 'key_alias': e.keyAlias,
  'default_on': e.defaultOn,
  'featured': e.featured,
  'path': e.path,
  'attribution': e.attribution,
  'license': e.license,
  if (e.docs != null) 'docs': e.docs,
  if (e.sha256 != null) 'sha256': e.sha256,
};
