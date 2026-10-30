import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'catalogue.dart';
import 'connector.dart';

/// The answer to an address: the bytes. Throws [NetworkProblem] when the address cannot be read.
typedef FetchBytes = Future<List<int>> Function(Uri url);

/// Checks one definition with the core. Throws [CatalogueException] saying why it is refused.
typedef DefinitionChecker = Future<void> Function(String definitionText);

/// The address could not be read (no connection, a server error): the catalogue that was there stays as it is.
class NetworkProblem extends CatalogueException {
  const NetworkProblem(super.message);
}

/// The real fetch: HTTPS (or this phone), a short timeout, a size cap, no key or cookie.
Future<List<int>> fetchBytes(Uri url, {int maxBytes = 4 * 1024 * 1024}) async {
  if (!isAllowedAddress(url)) throw const NetworkProblem('Cache only reads https addresses.');
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'Cache (connectors)';
  try {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 20));
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw NetworkProblem('${url.host} answered with an error (HTTP ${res.statusCode}).');
    }
    final out = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 30))) {
      out.addAll(chunk);
      if (out.length > maxBytes) throw const NetworkProblem('The file is larger than expected.');
    }
    return out;
  } on NetworkProblem {
    rethrow;
  } on TimeoutException {
    throw NetworkProblem("Couldn't reach ${url.host}.");
  } on SocketException {
    throw NetworkProblem("Couldn't reach ${url.host}. Check your connection.");
  } on HandshakeException {
    throw NetworkProblem("Couldn't make a secure connection to ${url.host}.");
  } on HttpException {
    throw NetworkProblem("Couldn't read from ${url.host}.");
  } finally {
    client.close(force: true);
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
    final text = utf8.decode(await fetch(url), allowMalformed: true);
    final cat = Catalogue.parse(text);
    final defs = <String, String>{};
    final skipped = <String, String>{};
    for (final e in cat.entries) {
      final bytes = await fetch(cat.definitionUrl(e));
      if (e.sha256 != null && sha256.convert(bytes).toString() != e.sha256) {
        skipped[e.id] = 'The file is not the one the catalogue lists (its checksum differs).';
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
    return LoadedCatalogue(url: address.trim(), catalogue: cat, definitions: defs, skipped: skipped, at: now());
  }
}

/// Catalogues kept on the phone, one folder each: the catalogue.json, its definitions and a note of what was left out. A new copy
/// replaces the old one whole; removing a catalogue removes its folder.
class CatalogueStore {
  CatalogueStore(this.root);

  final Directory root;

  String folderOf(String url) => sha256.convert(utf8.encode(url)).toString().substring(0, 12);

  Directory _dir(String url) => Directory('${root.path}/${folderOf(url)}');

  /// Replaces what is kept for [loaded.url] with [loaded].
  void save(LoadedCatalogue loaded) {
    root.createSync(recursive: true);
    final fresh = Directory('${_dir(loaded.url).path}.new');
    if (fresh.existsSync()) fresh.deleteSync(recursive: true);
    Directory('${fresh.path}/defs').createSync(recursive: true);
    File('${fresh.path}/catalogue.json').writeAsStringSync(jsonEncode(_catalogueJson(loaded.catalogue)));
    for (final e in loaded.definitions.entries) {
      File('${fresh.path}/defs/${e.key}.json').writeAsStringSync(e.value);
    }
    File('${fresh.path}/meta.json').writeAsStringSync(jsonEncode({
      'url': loaded.url,
      'fetched_at': loaded.fetchedAt.toIso8601String(),
      'skipped': loaded.skipped,
    }));
    final old = _dir(loaded.url);
    if (old.existsSync()) old.deleteSync(recursive: true);
    fresh.renameSync(old.path);
  }

  void remove(String url) {
    final d = _dir(url);
    if (d.existsSync()) d.deleteSync(recursive: true);
  }

  /// Every catalogue kept, read back from disk.
  List<LoadedCatalogue> loadAll() {
    if (!root.existsSync()) return [];
    final out = <LoadedCatalogue>[];
    for (final d in root.listSync().whereType<Directory>()) {
      if (d.path.endsWith('.new')) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
        continue;
      }
      try {
        final meta = jsonDecode(File('${d.path}/meta.json').readAsStringSync()) as Map<String, dynamic>;
        final cat = Catalogue.parse(File('${d.path}/catalogue.json').readAsStringSync());
        final defs = <String, String>{};
        for (final e in cat.entries) {
          final f = File('${d.path}/defs/${e.id}.json');
          if (f.existsSync()) defs[e.id] = f.readAsStringSync();
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
    'connectors': [
      for (final e in c.entries)
        {
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
        },
    ],
  };
}
