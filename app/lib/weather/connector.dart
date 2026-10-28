import 'dart:convert';

import 'catalogue.dart';

/// Where a source came from: shipped in the app, or a catalogue.
class Origin {
  const Origin.builtIn() : catalogueId = null, catalogueTitle = 'Built in';
  const Origin.catalogue(String this.catalogueId, this.catalogueTitle);

  final String? catalogueId;
  final String catalogueTitle;

  bool get isBuiltIn => catalogueId == null;
}

/// One live data source the app can use: its definition (data, never code) and what is known about it. The core reads the definition;
/// the app reads the same file for the words it shows.
class Connector {
  Connector._(this.id, this.defText, this.def, this.entry, this.origin);

  /// Reads a definition. The id comes from the file; [entry] is the catalogue's own description of it, when there is one.
  factory Connector.parse(String defText, {CatalogueEntry? entry, Origin origin = const Origin.builtIn()}) {
    final Object? j;
    try {
      j = jsonDecode(defText);
    } catch (_) {
      throw const CatalogueException('The definition is not readable.');
    }
    if (j is! Map<String, dynamic>) throw const CatalogueException('The definition is not readable.');
    final id = j['id'];
    if (id is! String || id.isEmpty) throw const CatalogueException('The definition has no id.');
    return Connector._(id, defText, j, entry, origin);
  }

  final String id;
  final String defText;
  final Map<String, dynamic> def;
  final CatalogueEntry? entry;
  final Origin origin;

  String _s(String k) => def[k] is String ? (def[k] as String).trim() : '';

  /// The name shown: the catalogue's title when it has one, else the definition's.
  String get title => entry?.title ?? (_s('title').isEmpty ? id : _s('title'));
  String get provider => _s('provider').isNotEmpty ? _s('provider') : (entry?.provider ?? '');
  String get description => entry?.description.isNotEmpty == true ? entry!.description : _s('description');
  String get attribution => _s('attribution').isNotEmpty ? _s('attribution') : (entry?.attribution ?? '');
  String get license => entry?.license ?? '';
  String get coverage => entry?.coverage ?? '';
  String get category => entry?.category ?? 'other';
  String? get docs => entry?.docs;

  /// Minutes between downloads (the source's refresh interval).
  int get refreshMinutes {
    final v = def['refresh_minutes'];
    return v is num && v > 0 ? v.toInt() : 60;
  }

  Map<String, dynamic>? get _apiKey => def['api_key'] is Map ? (def['api_key'] as Map).cast<String, dynamic>() : null;

  /// The name the key is kept under (several sources can share one key), or null when the source needs none.
  String? get keyAlias {
    final a = _apiKey?['alias'];
    return a is String && a.isNotEmpty ? a : null;
  }

  /// The source cannot be fetched without its key.
  bool get needsKey => keyAlias != null && _apiKey?['required'] != false;
}
