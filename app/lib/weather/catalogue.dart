import 'dart:convert';

/// Why a catalogue or a connector could not be used, in words for people.
class CatalogueException implements Exception {
  const CatalogueException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The catalogue format this version of Cache reads. A catalogue that says another number is refused.
const int kCatalogueFormat = 1;

/// Catalogue sources that replace a built-in source of the same data: the built-in one is the fallback until the catalogue has been
/// loaded, and is not listed or registered beside it. (Catalogue id to built-in id.)
const Map<String, String> liveReplaces = {
  'openmeteo-forecast': 'weather',
  'nws-alerts-point': 'alerts',
};

final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

/// Hosts a catalogue may be served from over plain HTTP: this phone itself (the app is tested against a server on the desktop through
/// adb reverse). Everything else must be https.
bool isLoopbackHost(String host) => host == 'localhost' || host == '127.0.0.1';

/// True for an address a catalogue or definition may be fetched from: https, or http to this phone.
bool isAllowedAddress(Uri u) => u.hasAuthority && u.host.isNotEmpty && (u.scheme == 'https' || (u.scheme == 'http' && isLoopbackHost(u.host)));

/// One connector as the catalogue lists it, so it can be listed without downloading its definition.
class CatalogueEntry {
  const CatalogueEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.provider,
    required this.coverage,
    required this.needsKey,
    required this.keyAlias,
    required this.defaultOn,
    this.featured = false,
    required this.path,
    required this.attribution,
    required this.license,
    required this.docs,
    required this.sha256,
  });

  final String id;
  final String title;
  final String description;
  final String category;
  final String provider;
  final String coverage;
  final bool needsKey;
  final String? keyAlias;
  final bool defaultOn;

  /// Listed first on the Weather and alerts page (the rest are under "More sources"). The catalogue says so with `featured`; a
  /// catalogue that does not use it features the sources it switches on by default.
  final bool featured;
  final String path;
  final String attribution;
  final String license;
  final String? docs;

  /// Hex SHA-256 of the definition file, or null.
  final String? sha256;

  static String _str(Map<String, dynamic> j, String k, {bool required = true, String orElse = ''}) {
    final v = j[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (required) throw CatalogueException('A connector in the catalogue has no "$k".');
    return orElse;
  }

  factory CatalogueEntry.fromJson(Map<String, dynamic> j) {
    final id = _str(j, 'id');
    if (!_idPattern.hasMatch(id)) throw CatalogueException('"$id" is not a valid connector id.');
    final path = _str(j, 'path');
    final needsKey = j['needs_key'] == true;
    final alias = j['key_alias'];
    final sha = j['sha256'];
    return CatalogueEntry(
      id: id,
      title: _str(j, 'title'),
      description: _str(j, 'description', required: false),
      category: _str(j, 'category', required: false, orElse: 'other'),
      provider: _str(j, 'provider', required: false),
      coverage: _str(j, 'coverage', required: false),
      needsKey: needsKey,
      keyAlias: needsKey && alias is String && alias.isNotEmpty ? alias : null,
      defaultOn: j['default_on'] == true,
      featured: j['featured'] is bool ? j['featured'] as bool : j['default_on'] == true,
      path: path,
      attribution: _str(j, 'attribution', required: false),
      license: _str(j, 'license', required: false),
      docs: j['docs'] is String && (j['docs'] as String).startsWith('https://') ? j['docs'] as String : null,
      sha256: sha is String && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha) ? sha.toLowerCase() : null,
    );
  }
}

/// A connector catalogue: a self-describing index of connector definitions (format 1, see connectors/README.md in cache-packs).
class Catalogue {
  const Catalogue({
    required this.id,
    required this.title,
    required this.maintainer,
    required this.homepage,
    required this.baseUrl,
    required this.updated,
    required this.entries,
  });

  final String id;
  final String title;
  final String maintainer;
  final String homepage;
  final Uri baseUrl;
  final String updated;
  final List<CatalogueEntry> entries;

  /// Reads catalogue.json. Refuses another format, a missing field, an address that is not https, and a path that leaves the base.
  factory Catalogue.parse(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      throw const CatalogueException("That address didn't give a connector catalogue.");
    }
    if (j is! Map<String, dynamic>) throw const CatalogueException("That address didn't give a connector catalogue.");
    final Map<String, dynamic> json = j;
    final format = json['format'];
    if (format != kCatalogueFormat) {
      throw CatalogueException(format is int && format > kCatalogueFormat
          ? 'This catalogue is in a newer format than this version of Cache can read. Update Cache to use it.'
          : 'This catalogue is in a format Cache does not know.');
    }
    String field(String k) {
      final v = json[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      throw CatalogueException('The catalogue has no "$k".');
    }

    final id = field('id');
    if (!_idPattern.hasMatch(id)) throw CatalogueException('"$id" is not a valid catalogue id.');
    final base = Uri.tryParse(field('base_url'));
    if (base == null || !isAllowedAddress(base)) throw const CatalogueException('The catalogue\'s base address must start with https://.');
    final list = json['connectors'];
    if (list is! List) throw const CatalogueException('The catalogue has no list of connectors.');
    final entries = <CatalogueEntry>[];
    final seen = <String>{};
    for (final e in list) {
      if (e is! Map<String, dynamic>) throw const CatalogueException('The catalogue has a connector that is not an object.');
      final entry = CatalogueEntry.fromJson(e);
      if (!seen.add(entry.id)) throw CatalogueException('The catalogue lists "${entry.id}" twice.');
      entries.add(entry);
    }
    final cat = Catalogue(
      id: id,
      title: field('title'),
      maintainer: json['maintainer'] is String ? (json['maintainer'] as String).trim() : '',
      homepage: json['homepage'] is String ? (json['homepage'] as String).trim() : '',
      baseUrl: base.path.endsWith('/') ? base : base.replace(path: '${base.path}/'),
      updated: json['updated'] is String ? json['updated'] as String : '',
      entries: entries,
    );
    for (final e in entries) {
      cat.definitionUrl(e);
    }
    return cat;
  }

  /// Where [e]'s definition is. A relative path is resolved against the base address and may not leave it; an absolute https address
  /// is allowed as it is.
  Uri definitionUrl(CatalogueEntry e) {
    final p = e.path;
    final abs = Uri.tryParse(p);
    if (abs == null) throw CatalogueException('The path of "${e.id}" is not an address.');
    if (abs.hasScheme) {
      if (!isAllowedAddress(abs)) throw CatalogueException('"${e.id}" points at an address that is not https.');
      return abs;
    }
    final segments = p.split('/');
    if (p.startsWith('/') || segments.any((s) => s == '..' || s == '.' || s.isEmpty) || p.contains('\\') || p.contains('?') || p.contains('#')) {
      throw CatalogueException('The path of "${e.id}" leaves the catalogue\'s folder.');
    }
    return baseUrl.resolve(p);
  }
}
