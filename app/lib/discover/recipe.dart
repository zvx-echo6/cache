import 'dart:convert';

/// Discover's catalogue: the activities (recipes) and collections Cache's own repository offers, as one JSON file published on
/// data.cached.info so it changes without an app release (docs/discover-recipes.md). The app carries a copy for first run and
/// offline. A file of another format, or a newer version than this build reads, is not used.
const String kDiscoverFormat = 'cache-discover';

/// The version of the format this build reads. A file with a higher version is ignored (the copy in the app is used instead).
const int kDiscoverVersion = 1;

/// Why a catalogue file could not be used, in words for people.
class RecipeException implements Exception {
  const RecipeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What kind of thing an item of a recipe is.
enum ItemKind {
  /// A library from the Kiwix catalogue, by its machine name and variant.
  library('library'),

  /// The map region for the person's place: map, road routing, places and optionally off-road.
  mapRegion('map_region'),

  /// A live data source (weather, alerts, fires) from the connector catalogue, by its id. Switching it on is a setting.
  liveSource('live_source'),

  /// A notebook made from one of the app's notebook templates or starter logs, by id.
  notebook('notebook'),

  /// A checklist: a notebook entry of task lines. The format reads them; Cache's own file ships none yet.
  checklist('checklist'),

  /// Ask starter questions. The format reads them; Cache's own file ships none yet.
  askStarters('ask_starters');

  const ItemKind(this.id);
  final String id;

  static ItemKind? byId(Object? id) {
    for (final k in values) {
      if (k.id == id) return k;
    }
    return null;
  }

  /// Items of this kind are downloaded or made (not just switched on).
  bool get downloads => this == library || this == mapRegion;
}

/// The parts of a map region an item may ask for.
const Set<String> kRegionParts = {'map', 'routing', 'places', 'offroad'};

final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

/// One item of a recipe. Only the fields of its [kind] are used.
class RecipeItem {
  const RecipeItem({
    required this.kind,
    this.name = '',
    this.flavour = '',
    this.id = '',
    this.title = '',
    this.subtitle = '',
    this.approxBytes = 0,
    this.parts = const {'map', 'routing', 'places'},
    this.defaultOn = true,
    this.lines = const [],
    this.provider = '',
  });

  /// [ItemKind.liveSource]: who the source is, in plain words ("National Weather Service"), for Connects to; the connector's own
  /// provider when empty.
  final String provider;

  final ItemKind kind;

  /// [ItemKind.library]: Kiwix's machine name ("wikipedia_en_medicine") and variant ("maxi", "nopic", "mini" or "").
  final String name;
  final String flavour;

  /// [ItemKind.liveSource]: the connector id; [ItemKind.notebook]: the template or starter id; [ItemKind.checklist] and
  /// [ItemKind.askStarters]: the item's own id.
  final String id;

  /// What the item is called on Discover's pages; a library's title from the catalogue is used when this is empty.
  final String title;

  /// A short second line (a library's "Army and FEMA").
  final String subtitle;

  /// The size the file says, used until the live catalogue gives the real one (0: not known).
  final int approxBytes;

  /// [ItemKind.mapRegion]: the parts it downloads.
  final Set<String> parts;

  /// Switched on in Customize at first. False: offered, left out unless the person switches it on.
  final bool defaultOn;

  /// [ItemKind.checklist]: its task lines; [ItemKind.askStarters]: its questions.
  final List<String> lines;

  /// The key that names this item across every activity: the same library, region, source or notebook in two activities is one
  /// item, downloaded once.
  String get key => switch (kind) {
    ItemKind.library => 'library:$name${flavour.isEmpty ? '' : ':$flavour'}',
    ItemKind.mapRegion => 'region:here',
    ItemKind.liveSource => 'live:$id',
    ItemKind.notebook => 'notebook:$id',
    ItemKind.checklist => 'checklist:$id',
    ItemKind.askStarters => 'ask:$id',
  };

  factory RecipeItem.fromJson(Object? j) {
    if (j is! Map) throw const RecipeException('An item of a recipe is not an object.');
    final kind = ItemKind.byId(j['kind']);
    if (kind == null) throw RecipeException('"${j['kind']}" is not a kind of item this version of Cache knows.');
    String s(String k) => j[k] is String ? (j[k] as String).trim() : '';
    final bytes = j['approx_bytes'] is num ? (j['approx_bytes'] as num).toInt() : 0;
    final lines = [for (final l in (j['lines'] is List ? j['lines'] as List : const [])) if (l is String && l.trim().isNotEmpty) l.trim()];
    final item = RecipeItem(
      kind: kind,
      name: s('name'),
      flavour: s('flavour'),
      id: s('id'),
      title: s('title'),
      subtitle: s('subtitle'),
      approxBytes: bytes < 0 ? 0 : bytes,
      parts: j['parts'] is List ? {for (final p in j['parts'] as List) if (p is String && kRegionParts.contains(p)) p} : const {'map', 'routing', 'places'},
      defaultOn: j['default_on'] != false,
      lines: lines,
      provider: s('provider'),
    );
    switch (kind) {
      case ItemKind.library:
        if (item.name.isEmpty) throw const RecipeException('A library item has no "name".');
      case ItemKind.mapRegion:
        if (item.parts.isEmpty) throw const RecipeException('A map region item asks for no parts.');
      case ItemKind.liveSource || ItemKind.notebook:
        if (!_idPattern.hasMatch(item.id)) throw RecipeException('"${item.id}" is not a valid id.');
      case ItemKind.checklist || ItemKind.askStarters:
        if (!_idPattern.hasMatch(item.id)) throw RecipeException('"${item.id}" is not a valid id.');
        if (item.lines.isEmpty) throw RecipeException('"${item.id}" has no lines.');
        if (kind == ItemKind.checklist && item.title.isEmpty) throw RecipeException('The checklist "${item.id}" has no title.');
    }
    return item;
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.id,
    if (name.isNotEmpty) 'name': name,
    if (flavour.isNotEmpty) 'flavour': flavour,
    if (id.isNotEmpty) 'id': id,
    if (title.isNotEmpty) 'title': title,
    if (subtitle.isNotEmpty) 'subtitle': subtitle,
    if (approxBytes > 0) 'approx_bytes': approxBytes,
    if (kind == ItemKind.mapRegion) 'parts': parts.toList()..sort(),
    if (!defaultOn) 'default_on': false,
    if (lines.isNotEmpty) 'lines': lines,
    if (provider.isNotEmpty) 'provider': provider,
  };
}

/// The settings a recipe may change, by key. A recipe that names another key is refused (only these are known to restore).
/// - `home:<block>`: a Home block shown (true) or hidden, such as `home:weather`;
/// - `watch:here`: weather and alerts watch where the device is.
/// Live sources are switched on by their items (key `live:<id>`), not listed here.
bool isKnownSettingKey(String key) => key == 'watch:here' || RegExp(r'^home:(weather|shortcuts|ask)$').hasMatch(key);

/// One setting a recipe changes, and the value it sets.
class RecipeSetting {
  const RecipeSetting(this.key, this.value);

  final String key;
  final Object value;

  factory RecipeSetting.fromJson(Object? j) {
    if (j is! Map || j['key'] is! String) throw const RecipeException('A setting of a recipe has no "key".');
    final key = j['key'] as String;
    if (!isKnownSettingKey(key)) throw RecipeException('"$key" is not a setting a recipe may change.');
    final v = j['value'];
    if (v is! bool) throw RecipeException('The setting "$key" has no true or false value.');
    return RecipeSetting(key, v);
  }

  Map<String, dynamic> toJson() => {'key': key, 'value': value};
}

/// An activity: a recipe of items Cache already offers, and the settings it turns on.
class Activity {
  const Activity({
    required this.id,
    required this.revision,
    required this.title,
    required this.tagline,
    this.description = '',
    this.icon = '',
    required this.items,
    this.settings = const [],
  });

  final String id;

  /// Goes up when the recipe changes; an activity added at a lower revision shows Update.
  final int revision;
  final String title;

  /// One line under the title ("Home and emergency basics").
  final String tagline;

  /// A sentence or two on its page.
  final String description;

  /// One of the icon names Discover draws (shield, peak, sprout, radio, book, map, stack); anything else gets a plain tile.
  final String icon;
  final List<RecipeItem> items;
  final List<RecipeSetting> settings;

  Iterable<RecipeItem> of(ItemKind k) => items.where((i) => i.kind == k);

  factory Activity.fromJson(Object? j) {
    if (j is! Map) throw const RecipeException('An activity is not an object.');
    final id = j['id'];
    if (id is! String || !_idPattern.hasMatch(id)) throw RecipeException('"$id" is not a valid activity id.');
    final title = j['title'];
    if (title is! String || title.trim().isEmpty) throw RecipeException('The activity "$id" has no title.');
    final items = [for (final i in (j['items'] is List ? j['items'] as List : const [])) RecipeItem.fromJson(i)];
    if (items.isEmpty) throw RecipeException('The activity "$id" has no items.');
    final keys = <String>{};
    for (final i in items) {
      if (!keys.add(i.key)) throw RecipeException('The activity "$id" lists ${i.key} twice.');
    }
    return Activity(
      id: id,
      revision: j['revision'] is int ? j['revision'] as int : 1,
      title: title.trim(),
      tagline: j['tagline'] is String ? (j['tagline'] as String).trim() : '',
      description: j['description'] is String ? (j['description'] as String).trim() : '',
      icon: j['icon'] is String ? j['icon'] as String : '',
      items: items,
      settings: [for (final s in (j['settings'] is List ? j['settings'] as List : const [])) RecipeSetting.fromJson(s)],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'revision': revision,
    'title': title,
    'tagline': tagline,
    if (description.isNotEmpty) 'description': description,
    if (icon.isNotEmpty) 'icon': icon,
    'items': [for (final i in items) i.toJson()],
    if (settings.isNotEmpty) 'settings': [for (final s in settings) s.toJson()],
  };
}

/// A collection: a hand-picked set of libraries, got together. What it adds belongs to the person (as a library they got
/// themselves), not to an activity.
class Collection {
  const Collection({required this.id, required this.title, this.tagline = '', this.icon = 'stack', required this.items});

  final String id;
  final String title;
  final String tagline;
  final String icon;

  /// Library items only.
  final List<RecipeItem> items;

  factory Collection.fromJson(Object? j) {
    if (j is! Map) throw const RecipeException('A collection is not an object.');
    final id = j['id'];
    if (id is! String || !_idPattern.hasMatch(id)) throw RecipeException('"$id" is not a valid collection id.');
    final items = [for (final i in (j['items'] is List ? j['items'] as List : const [])) RecipeItem.fromJson(i)];
    if (items.isEmpty || items.any((i) => i.kind != ItemKind.library)) throw RecipeException('The collection "$id" must list libraries only.');
    return Collection(
      id: id,
      title: j['title'] is String ? (j['title'] as String).trim() : id,
      tagline: j['tagline'] is String ? (j['tagline'] as String).trim() : '',
      icon: j['icon'] is String ? j['icon'] as String : 'stack',
      items: items,
    );
  }
}

/// The whole file: its activities, collections and the libraries Discover features in its Libraries row.
class DiscoverCatalogue {
  const DiscoverCatalogue({required this.updated, required this.activities, required this.collections, required this.libraries});

  /// The date the file was published ("2026-11-08"); a fetched file older than the app's copy is not used.
  final String updated;
  final List<Activity> activities;
  final List<Collection> collections;

  /// Libraries for the Libraries row (library items).
  final List<RecipeItem> libraries;

  static const empty = DiscoverCatalogue(updated: '', activities: [], collections: [], libraries: []);

  Activity? activity(String id) => activities.where((a) => a.id == id).firstOrNull;
  Collection? collection(String id) => collections.where((c) => c.id == id).firstOrNull;

  /// Reads a catalogue file. Refuses another format, a newer version than this build reads, and anything malformed.
  factory DiscoverCatalogue.parse(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      throw const RecipeException("That isn't a Discover file.");
    }
    if (j is! Map || j['format'] != kDiscoverFormat) throw const RecipeException("That isn't a Discover file.");
    final v = j['version'];
    if (v is! int || v < 1) throw const RecipeException('The Discover file has no version.');
    if (v > kDiscoverVersion) throw const RecipeException('The Discover file needs a newer version of Cache.');
    final acts = [for (final a in (j['activities'] is List ? j['activities'] as List : const [])) Activity.fromJson(a)];
    final ids = <String>{};
    for (final a in acts) {
      if (!ids.add(a.id)) throw RecipeException('The activity "${a.id}" is listed twice.');
    }
    final libs = [for (final i in (j['libraries'] is List ? j['libraries'] as List : const [])) RecipeItem.fromJson(i)];
    if (libs.any((i) => i.kind != ItemKind.library)) throw const RecipeException('The Libraries list must list libraries only.');
    return DiscoverCatalogue(
      updated: j['updated'] is String ? j['updated'] as String : '',
      activities: acts,
      collections: [for (final c in (j['collections'] is List ? j['collections'] as List : const [])) Collection.fromJson(c)],
      libraries: libs,
    );
  }
}
