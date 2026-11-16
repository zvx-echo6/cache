// The 17 settings that go between linked devices, read and written by key straight from the files in the support folder, with no
// Flutter and no state class: the Cache Server helper (plain Dart) keeps a server's settings this way. The value of a key is the
// one the setting's read() in synced_settings.dart gives (the log's value form), so phones and the server read each other's lines.
//
// What this does NOT do is what a state class does beyond saving its file: it does not tell listeners, it does not apply anything
// to the running app (the core, the model, the live sources), and it does not check what only Flutter code can check. See each
// key in [kSettingsFileMap] and the notes at the write of each setting.
//
// Imports: dart:convert, dart:io, package:crypto and files.dart (as settings_log.dart does). Nothing here may import Flutter or a
// file that does (the state classes, theme.dart, modules.dart, weather/catalogue.dart, which reaches net/fetch.dart).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../files.dart';

// ------------------------------------------------------------------ names the app's enums have (a parity test keeps them equal)

/// `CacheThemeId` names, the first is the default (theme.dart).
const List<String> kThemeNames = ['dark', 'light', 'parchment', 'tactical'];

/// `ModuleId` names (layout/modules.dart).
const List<String> kModuleNames = ['ask', 'library', 'maps', 'videos', 'weather', 'discover', 'notebooks', 'settings'];

/// The most modules the bar holds (`kMaxPinned`).
const int kMaxPinnedModules = 3;

/// The bar before the person changes it (`LayoutState.defaultPinned`).
const List<String> kDefaultPinnedNames = ['ask', 'maps', 'library'];

/// `LayoutState.defaultBlocks`, in their default order.
const List<String> kHomeBlockNames = ['setup', 'ask', 'weather', 'shortcuts'];

/// `PopUpFor` names; the first is the default.
const List<String> kPopUpNames = ['serious', 'all', 'none'];

/// `ShortcutKind` names.
const List<String> kShortcutKindNames = ['module', 'place', 'page', 'chat', 'notebook'];

// ------------------------------------------------------------------ where each key lives

/// Which file holds a setting under the support folder, and which of its top-level JSON fields (a write changes only these and
/// leaves every other field as it is).
class SettingsFileSpec {
  const SettingsFileSpec(this.file, this.fields, {this.also = const []});

  final String file;
  final List<String> fields;

  /// Other files a write of the setting makes (your own sources are a folder).
  final List<String> also;
}

/// What your own weather sources are kept under: the folder of the list `cache:own` in `live-catalogues/` (CatalogueStore.folderOf).
final String kOwnSourcesFolder = 'live-catalogues/${sha256.convert(utf8.encode(_ownListUrl)).toString().substring(0, 12)}';
const String _ownListUrl = 'cache:own';

/// Every synced setting, by key: the file and the fields.
final Map<String, SettingsFileSpec> kSettingsFileMap = {
  'appearance.theme': const SettingsFileSpec('settings.json', ['theme']),
  'appearance.module_icons': const SettingsFileSpec('settings.json', ['moduleIcons']),
  'appearance.dark_pdf_pages': const SettingsFileSpec('settings.json', ['pdfDarkPages']),
  'home.bar': const SettingsFileSpec('layout.json', ['pinned']),
  // setupHidden is the note of a version before Set up Cache was a block; the phone drops it when it saves the blocks.
  'home.blocks': const SettingsFileSpec('layout.json', ['blocks', 'off', 'setupHidden']),
  'home.shortcuts': const SettingsFileSpec('layout.json', ['shortcuts']),
  'weather.sources_on': const SettingsFileSpec('preferences.json', ['liveSourcesOn']),
  'weather.watch_here': const SettingsFileSpec('preferences.json', ['watchedPlaces', 'weatherWatch']),
  'weather.watch_regions': const SettingsFileSpec('preferences.json', ['watchedPlaces', 'weatherWatch']),
  'weather.watch_places': const SettingsFileSpec('preferences.json', ['watchedPlaces', 'weatherWatch']),
  'weather.own_sources': SettingsFileSpec('$kOwnSourcesFolder/catalogue.json', const ['connectors'], also: ['$kOwnSourcesFolder/defs/<id>.json', '$kOwnSourcesFolder/meta.json']),
  'weather.source_links': const SettingsFileSpec('preferences.json', ['extraCatalogues']),
  'alerts.pop_up': const SettingsFileSpec('preferences.json', ['popUpFor']),
  'alerts.quiet_hours': const SettingsFileSpec('preferences.json', ['quiet']),
  'maps.layers_on': const SettingsFileSpec('maps.json', ['enabled']),
  'ask.model': const SettingsFileSpec('settings.json', ['lastModel']),
  'ask.web_search': const SettingsFileSpec('preferences.json', ['webSearchOn']),
};

/// The group of each synced setting, as the link record names it in `off_groups` (the phone's `SettingsGroupId` names), by the
/// key's first part; `alerts.*` is the Notifications group. settings_sync.dart cannot be imported by the helper (it needs Flutter),
/// so a test keeps this equal to `appSyncedSettings`' groups.
const Map<String, String> kGroupOfPrefix = {
  'appearance': 'appearance',
  'home': 'home',
  'weather': 'weather',
  'alerts': 'notifications',
  'maps': 'maps',
  'ask': 'ask',
};

/// The group name of [key] ('' for a key that is in no group).
String settingsGroupOf(String key) => kGroupOfPrefix[key.split('.').first] ?? '';

// ------------------------------------------------------------------ file access

/// The file access the settings need, paths relative to the support folder (with '/'), so the server helper can use its support
/// folder and a test a temp folder.
abstract interface class SettingsFileAccess {
  /// The file's text, or null when it is not there.
  Future<String?> read(String path);

  /// Writes [text] whole (a temp file next to it, then a rename), making the folders on the way.
  Future<void> writeAtomic(String path, String text);

  /// Copies the file to [to] (nothing happens when it is missing).
  Future<void> copy(String from, String to);

  /// Removes a folder with what is in it (nothing happens when it is missing).
  Future<void> deleteFolder(String path);

  /// Renames a folder to [to] (which is not there).
  Future<void> renameFolder(String from, String to);

  Future<bool> exists(String path);
}

/// [SettingsFileAccess] on dart:io, under [root].
class IoSettingsFileAccess implements SettingsFileAccess {
  const IoSettingsFileAccess(this.root);

  final Directory root;

  String _p(String path) => '${root.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}';

  @override
  Future<String?> read(String path) async {
    final f = File(_p(path));
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  @override
  Future<void> writeAtomic(String path, String text) async {
    final f = File(_p(path));
    await f.parent.create(recursive: true);
    await writeStringAtomic(f, text);
  }

  @override
  Future<void> copy(String from, String to) async {
    final f = File(_p(from));
    if (await f.exists()) await f.copy(_p(to));
  }

  @override
  Future<void> deleteFolder(String path) async {
    final d = Directory(_p(path));
    if (await d.exists()) await d.delete(recursive: true);
  }

  @override
  Future<void> renameFolder(String from, String to) async {
    await Directory(_p(from)).rename(_p(to));
  }

  @override
  Future<bool> exists(String path) async => await File(_p(path)).exists() || await Directory(_p(path)).exists();
}

// ------------------------------------------------------------------ read and write by key

/// Reads and writes the synced settings by key. One writer at a time per folder (the host's sync is that one writer); each write
/// reads the file, changes the setting's fields and writes the whole file again.
class SettingsFiles {
  SettingsFiles(this.files, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final SettingsFileAccess files;
  final DateTime Function() _now;

  /// True for a key this maps.
  bool handles(String key) => kSettingsFileMap.containsKey(key);

  /// The setting's value as the setting's read() gives it, from the files (the defaults of a new install where a file or a field is
  /// not there).
  Future<Object?> read(String key) async {
    switch (key) {
      case 'appearance.theme':
        final t = (await _json('settings.json'))['theme'];
        return kThemeNames.contains(t) ? t : kThemeNames.first;
      case 'appearance.module_icons':
        return (await _json('settings.json'))['moduleIcons'] == 'large' ? 'large' : 'small';
      case 'appearance.dark_pdf_pages':
        return (await _json('settings.json'))['pdfDarkPages'] == true;
      case 'ask.model':
        final m = (await _json('settings.json'))['lastModel'];
        return m is String ? m : null;
      case 'home.bar':
        return _layout(await _json('layout.json')).pinned;
      case 'home.blocks':
        final l = _layout(await _json('layout.json'));
        return {'order': l.order, 'off': l.off};
      case 'home.shortcuts':
        return _layout(await _json('layout.json')).shortcuts;
      case 'weather.sources_on':
        return (_strings((await _json('preferences.json'))['liveSourcesOn']).toSet().toList()..sort());
      case 'weather.watch_here':
        return _watched(await _json('preferences.json')).contains('here');
      case 'weather.watch_regions':
        return [for (final id in _watched(await _json('preferences.json'))) if (id.startsWith('region:')) id.substring(7)]..sort();
      case 'weather.watch_places':
        return [for (final id in _watched(await _json('preferences.json'))) if (id.startsWith('place:')) id.substring(6)]..sort();
      case 'weather.own_sources':
        return _readOwn();
      case 'weather.source_links':
        return _strings((await _json('preferences.json'))['extraCatalogues']);
      case 'alerts.pop_up':
        final j = await _json('preferences.json');
        return _popUp(j['popUpFor'] ?? (j['alertPopups'] == false ? 'none' : 'serious'));
      case 'alerts.quiet_hours':
        return _quiet((await _json('preferences.json'))['quiet']);
      case 'maps.layers_on':
        final e = (await _json('maps.json'))['enabled'];
        return e is List ? ({for (final x in e) if (x is String) x}.toList()..sort()) : <String>[];
      case 'ask.web_search':
        return (await _json('preferences.json'))['webSearchOn'] == true;
    }
    throw ArgumentError.value(key, 'key', 'not a synced setting');
  }

  /// Sets the setting to [value] (as the setting's write() takes it), changing only its fields of the file. A value of the wrong
  /// kind is treated as the setting's write() treats it (a theme the app does not know changes nothing).
  Future<void> write(String key, Object? value) async {
    switch (key) {
      case 'appearance.theme':
        if (!kThemeNames.contains(value)) return;
        return _update('settings.json', (j) => j['theme'] = value);
      case 'appearance.module_icons':
        return _update('settings.json', (j) => j['moduleIcons'] = value == 'large' ? 'large' : 'small');
      case 'appearance.dark_pdf_pages':
        return _update('settings.json', (j) => j['pdfDarkPages'] = value == true);
      case 'ask.model':
        // The plain file part only: the phone also checks the file is on the device, loads it, and answers false when it is not.
        if (value is! String) return;
        return _update('settings.json', (j) => j['lastModel'] = value);
      case 'home.bar':
        final next = _pinnedOf(value);
        return _update('layout.json', (j) => j['pinned'] = next);
      case 'home.blocks':
        final b = _blocksOf(value);
        return _update('layout.json', (j) {
          j['blocks'] = b.order;
          j['off'] = b.off;
          j.remove('setupHidden');
        });
      case 'home.shortcuts':
        final s = _shortcutsOf(value);
        return _update('layout.json', (j) => j['shortcuts'] = s);
      case 'weather.sources_on':
        final next = _strings(value).toSet().toList()..sort();
        return _update('preferences.json', (j) => j['liveSourcesOn'] = next);
      case 'weather.watch_here':
        return _setWatched('here', (id) => id == 'here', [if (value == true) 'here']);
      case 'weather.watch_regions':
        return _setWatched('region:', (id) => id.startsWith('region:'), [for (final r in _strings(value)) 'region:$r']);
      case 'weather.watch_places':
        return _setWatched('place:', (id) => id.startsWith('place:'), [for (final k in _strings(value)) 'place:$k']);
      case 'weather.own_sources':
        return _writeOwn(value);
      case 'weather.source_links':
        final next = _strings(value);
        return _update('preferences.json', (j) => j['extraCatalogues'] = next);
      case 'alerts.pop_up':
        final p = _popUp(value);
        return _update('preferences.json', (j) => j['popUpFor'] = p);
      case 'alerts.quiet_hours':
        if (value is! Map) return;
        int at(Object? x, int d) => x is int ? x.clamp(0, 1439) : d;
        final q = {'on': value['on'] != false, 'from': at(value['from'], 22 * 60), 'to': at(value['to'], 6 * 60)};
        return _update('preferences.json', (j) => j['quiet'] = q);
      case 'maps.layers_on':
        final next = _strings(value).toSet().toList()..sort();
        return _update('maps.json', (j) {
          j['enabled'] = next;
          // The phone reads maps.json with the opacities there: a file made here has them empty.
          j.putIfAbsent('opacity', () => <String, dynamic>{});
        });
      case 'ask.web_search':
        return _update('preferences.json', (j) => j['webSearchOn'] = value == true);
    }
    throw ArgumentError.value(key, 'key', 'not a synced setting');
  }

  // ---------------------------------------------------------------- the files

  /// The file as a JSON object; empty when it is not there or not readable.
  Future<Map<String, dynamic>> _json(String name) async {
    try {
      final text = await files.read(name);
      if (text == null) return {};
      return (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  /// Reads [name], lets [change] set the setting's fields, writes the whole file back whole. A file that cannot be read is kept
  /// beside it as `<name>.unreadable` before it is written over (as preferences.json is), and a new file starts empty.
  Future<void> _update(String name, void Function(Map<String, dynamic> j) change) async {
    Map<String, dynamic> j = {};
    final text = await files.read(name);
    if (text != null) {
      try {
        j = (jsonDecode(text) as Map).cast<String, dynamic>();
      } catch (_) {
        try {
          await files.copy(name, '$name.unreadable');
        } catch (_) {}
        j = {};
      }
    }
    change(j);
    await files.writeAtomic(name, jsonEncode(j));
  }

  static List<String> _strings(Object? v) => v is List ? [for (final e in v) if (e is String && e.isNotEmpty) e] : <String>[];

  // ---------------------------------------------------------------- layout.json

  /// layout.json as LayoutState reads it.
  static ({List<String> pinned, List<String> order, List<String> off, List<Map<String, dynamic>> shortcuts}) _layout(Map<String, dynamic> j) {
    if (j.isEmpty) return (pinned: [...kDefaultPinnedNames], order: [...kHomeBlockNames], off: <String>[], shortcuts: <Map<String, dynamic>>[]);
    try {
      final pinned = _pinnedOf(j['pinned']);
      final order = _orderOf(j['blocks']);
      final off = <String>{for (final n in (j['off'] as List? ?? const [])) if (kHomeBlockNames.contains(n)) n as String};
      if (j['setupHidden'] == true) off.add('setup');
      return (pinned: pinned, order: order, off: off.toList()..sort(), shortcuts: _shortcutsOf(j['shortcuts']));
    } catch (_) {
      return (pinned: [...kDefaultPinnedNames], order: [...kHomeBlockNames], off: <String>[], shortcuts: <Map<String, dynamic>>[]);
    }
  }

  static List<String> _pinnedOf(Object? names) {
    final next = <String>[];
    for (final n in (names is List ? names : const [])) {
      if (n is String && kModuleNames.contains(n) && !next.contains(n) && next.length < kMaxPinnedModules) next.add(n);
    }
    return next;
  }

  /// The order of the blocks: those listed, then those this version has that the list lacks (Set up Cache first, the rest last).
  static List<String> _orderOf(Object? names) {
    final order = <String>[];
    for (final n in (names is List ? names : const [])) {
      if (n is String && kHomeBlockNames.contains(n) && !order.contains(n)) order.add(n);
    }
    for (final b in kHomeBlockNames) {
      if (!order.contains(b)) b == 'setup' ? order.insert(0, b) : order.add(b);
    }
    return order;
  }

  static ({List<String> order, List<String> off}) _blocksOf(Object? v) {
    final m = v is Map ? v : const {};
    final off = <String>{for (final n in (m['off'] as List? ?? const [])) if (n is String && kHomeBlockNames.contains(n)) n};
    return (order: _orderOf(m['order']), off: off.toList()..sort());
  }

  /// The Shortcuts as LayoutState keeps them (Shortcut.toJson), one for each thing, one that has no target dropped.
  static List<Map<String, dynamic>> _shortcutsOf(Object? list) {
    final out = <Map<String, dynamic>>[];
    final keys = <String>{};
    for (final s in (list is List ? list : const [])) {
      final sc = _shortcut(s);
      if (sc == null) continue;
      final data = sc['data'] as Map<String, dynamic>;
      final key = '${sc['kind']}:${switch (sc['kind']) {
        'module' => data['module'],
        'page' => data['address'],
        _ => data['id'],
      }}';
      if (keys.add(key)) out.add(sc);
    }
    return out;
  }

  static Map<String, dynamic>? _shortcut(Object? j) {
    if (j is! Map) return null;
    final kind = j['kind'];
    final data = j['data'];
    if (kind is! String || !kShortcutKindNames.contains(kind) || data is! Map) return null;
    final d = Map<String, dynamic>.from(data);
    final ok = switch (kind) {
      'module' => d['module'] is String && kModuleNames.contains(d['module']),
      'place' => d['lat'] is num &&
          d['lon'] is num &&
          [d['id'], d['type'], d['kind'], d['address'], d['matched']].every((x) => x == null || x is String) &&
          (d['formats'] == null || d['formats'] is Map),
      'page' => d['address'] is String,
      'chat' => d['id'] is num,
      'notebook' => d['id'] is String,
      _ => false,
    };
    if (!ok) return null;
    return {'kind': kind, 'title': '${j['title'] ?? ''}', 'subtitle': '${j['subtitle'] ?? ''}', 'data': d};
  }

  // ---------------------------------------------------------------- preferences.json

  /// The watched places as AppSettings reads them: weatherWatch (format 1) first, else the older watchedPlaces list; "Where I am" is
  /// `here`, the others `region:<name>` and `place:<key>`.
  static Set<String> _watched(Map<String, dynamic> j) {
    var watched = <String>{'here'};
    try {
      final ww = j['weatherWatch'];
      if (ww is Map && ww['format'] == 1) {
        watched = {
          if (ww['here'] != false) 'here',
          for (final r in _strings(ww['regions'])) 'region:$r',
          for (final k in _strings(ww['places'])) 'place:$k',
        };
      } else if (j['watchedPlaces'] is List) {
        watched = _strings(j['watchedPlaces']).toSet();
      }
    } catch (_) {}
    return watched;
  }

  /// Replaces the watched places that [isKind] says are of one kind with [ids]; the others stay. Writes `watchedPlaces` and
  /// `weatherWatch` together, as AppSettings does (nothing is written when nothing changes).
  Future<void> _setWatched(String kind, bool Function(String id) isKind, List<String> ids) async {
    final j = await _json('preferences.json');
    final now = _watched(j);
    final next = {for (final id in now) if (!isKind(id)) id, ...ids};
    if (next.length == now.length && next.containsAll(now)) return;
    await _update('preferences.json', (j) {
      j['watchedPlaces'] = next.toList()..sort();
      j['weatherWatch'] = {
        'format': 1,
        'here': next.contains('here'),
        'regions': [for (final id in next) if (id.startsWith('region:')) id.substring(7)]..sort(),
        'places': [for (final id in next) if (id.startsWith('place:')) id.substring(6)]..sort(),
      };
    });
  }

  static String _popUp(Object? n) => kPopUpNames.contains(n) ? n as String : kPopUpNames.first;

  static Map<String, Object?> _quiet(Object? q) {
    var on = true;
    var from = 22 * 60;
    var to = 6 * 60;
    try {
      if (q is Map) {
        final nf = ((q['from'] as num?)?.toInt() ?? 22 * 60).clamp(0, 1439);
        final nt = ((q['to'] as num?)?.toInt() ?? 6 * 60).clamp(0, 1439);
        on = q['on'] != false;
        from = nf;
        to = nt;
      }
    } catch (_) {}
    return {'on': on, 'from': from, 'to': to};
  }

  // ---------------------------------------------------------------- your own weather sources

  static final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  /// A text field of a source list's entry (CatalogueEntry.fromJson): trimmed; a missing required one throws.
  static String _str(Map<String, dynamic> j, String k, {bool required = true, String orElse = ''}) {
    final v = j[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (required) throw FormatException('A source in the list has no "$k".');
    return orElse;
  }

  /// One entry read the way CatalogueEntry.fromJson reads it, in the list's format (catalogueEntryJson); [own] makes it an entry of
  /// "Your own" (not featured, not on by default, its definition beside it).
  static Map<String, dynamic> _entry(Map<String, dynamic> j, {required bool own}) {
    final id = _str(j, 'id');
    if (!_idPattern.hasMatch(id)) throw FormatException('"$id" is not a valid connector id.');
    final path = _str(j, 'path');
    final needsKey = j['needs_key'] == true;
    final alias = j['key_alias'];
    final sha = j['sha256'];
    final docs = j['docs'];
    return {
      'id': id,
      'title': _str(j, 'title'),
      'description': _str(j, 'description', required: false),
      'category': _str(j, 'category', required: false, orElse: 'other'),
      'provider': _str(j, 'provider', required: false),
      'coverage': _str(j, 'coverage', required: false),
      'needs_key': needsKey,
      if (needsKey && alias is String && alias.isNotEmpty) 'key_alias': alias,
      'default_on': own ? false : j['default_on'] == true,
      'featured': own ? false : (j['featured'] is bool ? j['featured'] as bool : j['default_on'] == true),
      'path': own ? 'defs/$id.json' : path,
      'attribution': _str(j, 'attribution', required: false),
      'license': _str(j, 'license', required: false),
      if (docs is String && docs.startsWith('https://')) 'docs': docs,
      if (!own && sha is String && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) 'sha256': sha.toLowerCase(),
    };
  }

  /// ownSourcesJson from the files: each source's entry and definition, sorted by id; none when the list is not kept (or is
  /// damaged, as the phone ignores a damaged folder).
  Future<List<Map<String, dynamic>>> _readOwn() async {
    try {
      final meta = jsonDecode((await files.read('$kOwnSourcesFolder/meta.json'))!) as Map<String, dynamic>;
      if (meta['url'] is! String) return const [];
      final cat = jsonDecode((await files.read('$kOwnSourcesFolder/catalogue.json'))!) as Map<String, dynamic>;
      if (cat['format'] != 1 || cat['connectors'] is! List) return const [];
      final entries = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final e in cat['connectors'] as List) {
        if (e is! Map<String, dynamic>) return const [];
        final entry = _entry(e, own: false);
        if (!seen.add(entry['id'] as String)) return const [];
        entries.add(entry);
      }
      entries.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      final out = <Map<String, dynamic>>[];
      for (final e in entries) {
        final def = await files.read('$kOwnSourcesFolder/defs/${e['id']}.json');
        if (def != null) out.add({'entry': e, 'definition': def});
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Keeps exactly [list] as your own sources, the way the phone's CatalogueStore keeps a list: a new folder made whole beside the
  /// old one, then swapped in. A source with an entry the list format refuses, or that is not an entry and a definition text, or
  /// that comes twice, is left out. Not done here: the core's check of each definition (Connector.parse and the layer check), the
  /// keys, and telling the running app.
  Future<void> _writeOwn(Object? list) async {
    final entries = <Map<String, dynamic>>[];
    final defs = <String, String>{};
    for (final x in (list is List ? list : const [])) {
      if (x is! Map || x['entry'] is! Map || x['definition'] is! String) continue;
      try {
        final e = _entry((x['entry'] as Map).cast<String, dynamic>(), own: true);
        if (defs.containsKey(e['id'])) continue;
        entries.add(e);
        defs[e['id'] as String] = x['definition'] as String;
      } catch (_) {}
    }
    final dir = kOwnSourcesFolder;
    final tmp = '$dir.new';
    await files.deleteFolder(tmp);
    await files.writeAtomic('$tmp/catalogue.json', jsonEncode({
      'format': 1,
      'id': 'own',
      'title': 'Your own',
      'maintainer': '',
      'homepage': '',
      'base_url': 'https://localhost/own/',
      'updated': '',
      'connectors': entries,
    }));
    for (final e in defs.entries) {
      await files.writeAtomic('$tmp/defs/${e.key}.json', e.value);
    }
    await files.writeAtomic('$tmp/meta.json', jsonEncode({'url': _ownListUrl, 'fetched_at': _now().toIso8601String(), 'skipped': <String, String>{}}));
    await files.deleteFolder(dir);
    await files.renameFolder(tmp, dir);
  }
}
