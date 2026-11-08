import 'package:flutter/widgets.dart';

import '../browse/browse_state.dart';
import '../browse/free_space.dart';
import '../browse/opds.dart';
import '../browse/zim_dl.dart' show zimActions, zimDl;
import '../downloads/download_row.dart';
import '../layout/layout_state.dart';
import '../location/location_service.dart';
import '../notebook/notebook_model.dart' show NotebookDef;
import '../notebook/notebook_state.dart';
import '../notebook/notebook_text.dart' show CheckItem, joinChecklist;
import '../notebook/templates.dart';
import '../platform/app_log.dart';
import '../regions/region_catalogue.dart' show RegionRecord;
import '../regions/regions_state.dart';
import '../search/index_scheduler.dart';
import '../search/index_status.dart' show indexRowWords, zimIndexKeys;
import '../settings/app_settings.dart';
import '../sources/sources_state.dart';
import '../weather/weather_state.dart';
import 'discover_state.dart';
import 'recipe.dart';

/// Discover on the app's own state: libraries from the Kiwix catalogue through the Library's downloads, the map region through
/// Regions, live sources and Home blocks through Settings and the layout, notebooks through Notebooks. Nothing here talks to a
/// server of its own: every download is the one the rest of the app starts.
class AppDiscoverDevice implements DiscoverDevice {
  AppDiscoverDevice({
    required this.browse,
    required this.settings,
    required this.weather,
    required this.layout,
    this.regions,
    this.notebooks,
    this.location,
    this.indexing,
  });

  final BrowseState browse;
  final AppSettings settings;
  final WeatherState weather;
  final LayoutState layout;
  final RegionsState? regions;
  final NotebookState? notebooks;
  final LocationService? location;
  final IndexScheduler? indexing;

  SourcesState get sources => browse.sources;

  @override
  Listenable get changes => Listenable.merge([browse, sources, weather, layout, ?regions, ?notebooks, ?location, ?indexing]);

  DiscoverPlace? _chosen;

  @override
  DiscoverPlace? get place {
    final c = _chosen;
    if (c != null && !c.here) return c;
    final f = location?.fix;
    if (f != null) return DiscoverPlace(lat: f.lat, lon: f.lon, here: true);
    return c;
  }

  @override
  set place(DiscoverPlace? p) => _chosen = p;

  // ---- the Kiwix catalogue

  /// The newest catalogue entry of each library, by its key.
  final Map<String, CatalogEntry> _entries = {};

  static String _libKey(String name, String flavour) => 'library:$name${flavour.isEmpty ? '' : ':$flavour'}';

  Future<CatalogEntry?> _entryFor(RecipeItem i) async {
    final known = _entries[i.key];
    if (known != null) return known;
    final page = await browse.catalog.entries(name: i.name, count: 20);
    CatalogEntry? best;
    for (final e in page.entries) {
      if (e.name != i.name || e.flavour != i.flavour) continue;
      if (best == null || e.release.compareTo(best.release) > 0) best = e;
    }
    if (best != null) _entries[i.key] = best;
    return best;
  }

  ZimFile? _zimOf(RecipeItem i) {
    for (final z in sources.zims) {
      final o = sources.originOf(z);
      if (o != null && _libKey(o.name, o.flavour) == i.key) return z;
    }
    return null;
  }

  ZimTransfer? _transferOf(RecipeItem i) {
    for (final t in browse.transfers.values) {
      if (_libKey(t.entry.name, t.entry.flavour) == i.key) return t;
    }
    return null;
  }

  // ---- the map region

  RegionRecord? _home;
  List<RegionRecord> _near = const [];

  Future<RegionRecord?> _homeRecord() async {
    final r = regions, p = place;
    if (r == null || p == null) return null;
    await r.catalogue.readShardAt(p.lat, p.lon);
    _near = r.catalogue.regionsAt(p.lat, p.lon, limit: 4);
    return _home = r.catalogue.regionAt(p.lat, p.lon) ?? _near.firstOrNull;
  }

  Future<bool> _regionHere() async {
    final rec = await _homeRecord().catchError((_) => null);
    return rec != null && regions?.regionOf(rec.id) != null;
  }

  @override
  Future<void> resolve(Iterable<RecipeItem> items) async {
    final seen = <String>{};
    for (final i in items) {
      if (i.kind != ItemKind.library || !seen.add(i.key)) continue;
      try {
        await _entryFor(i);
      } catch (_) {
        return; // offline: the recipe's sizes stand
      }
    }
    try {
      await _homeRecord();
    } catch (_) {}
  }

  // ---- DiscoverPorts

  @override
  Future<bool> isPresent(RecipeItem i) async => switch (i.kind) {
    ItemKind.library => _zimOf(i) != null || _transferOf(i) != null,
    ItemKind.mapRegion => await _regionHere(),
    ItemKind.liveSource => weather.isOn(i.id),
    ItemKind.notebook => await _notebookOf(i.id) != null,
    ItemKind.checklist || ItemKind.askStarters => false,
  };

  Future<String?> _notebookOf(String templateId) async {
    final nb = notebooks;
    if (nb == null) return null;
    await nb.start();
    for (final n in nb.notebooks) {
      final ref = n.templateRef ?? '';
      if (ref.startsWith('starters/$templateId@') || ref.startsWith('templates/$templateId@')) return n.id;
    }
    return null;
  }

  @override
  Future<Map<String, Object?>> add(RecipeItem i, Map<String, Object?>? handle) async {
    switch (i.kind) {
      case ItemKind.library:
        if (_zimOf(i) != null || _transferOf(i) != null) return handle ?? {};
        try {
          final e = await _entryFor(i);
          if (e == null) return {'failed': 'not in the catalogue'};
          await browse.download(e);
          return {'entry': e.id};
        } catch (e) {
          logInfo('Discover could not start a library download', detail: '${i.name}: $e');
          return {'failed': '$e'};
        }
      case ItemKind.mapRegion:
        final r = regions;
        final rec = await _homeRecord().catchError((_) => null);
        if (r == null || rec == null) return handle ?? {'failed': 'no place'};
        final o = r.offer(rec);
        try {
          if (o.kind == RegionOfferKind.download) {
            await r.download(rec, routing: i.parts.contains('routing') && o.routing, map: i.parts.contains('map') && o.map, places: i.parts.contains('places') && o.places, offroad: i.parts.contains('offroad') && o.offroad);
          } else if (o.kind == RegionOfferKind.addParts && ((i.parts.contains('offroad') && o.offroad) || (i.parts.contains('places') && o.places))) {
            await r.addParts(rec, offroad: i.parts.contains('offroad') && o.offroad, places: i.parts.contains('places') && o.places);
          }
        } catch (e) {
          logInfo('Discover could not start the map region', detail: '$e');
        }
        return {'region': rec.id, 'name': rec.name};
      case ItemKind.notebook:
        final nb = notebooks;
        final have = await _notebookOf(i.id);
        if (nb == null) return {'failed': 'no notebooks'};
        if (have != null) return handle ?? {'notebook': have};
        final t = await loadTemplates();
        final tpl = [...t.starters, ...t.notebooks].where((x) => x.id == i.id).firstOrNull;
        if (tpl == null) return {'failed': 'no such template'};
        final made = await nb.saveNotebook(template: tpl.template, def: tpl.def, private: tpl.private, map: tpl.map, templateRef: tpl.ref);
        return {'notebook': made.id};
      case ItemKind.checklist:
        final nb = notebooks;
        if (nb == null) return {'failed': 'no notebooks'};
        if (handle?['notebook'] is String) return handle!;
        final t = await loadTemplates();
        final notes = t.byId('notes');
        if (notes == null) return {'failed': 'no notes template'};
        final made = await nb.saveNotebook(template: notes.template, def: NotebookDef(name: i.title, fields: notes.def.fields, sort: notes.def.sort, quickAdd: notes.def.quickAdd, meta: notes.def.meta), private: false, map: false, templateRef: notes.ref);
        final entry = await nb.saveEntry(
          notebookId: made.id,
          occurredAt: DateTime.now().toUtc().toIso8601String(),
          title: i.title,
          body: joinChecklist('', [for (final l in i.lines) CheckItem(l)]),
        );
        return {'notebook': made.id, 'entry': entry.id, 'updated': entry.updated};
      case ItemKind.askStarters:
        return {'questions': i.lines};
      case ItemKind.liveSource:
        return {};
    }
  }

  @override
  Future<bool> personUses(RecipeItem i, Map<String, Object?> handle) async {
    final nb = notebooks, id = handle['notebook'];
    if (nb == null || id is! String) return false;
    if (nb.notebook(id) == null) return true; // gone already: nothing to remove
    final entries = await nb.entries(id);
    if (i.kind == ItemKind.checklist) {
      // Its own entry, unchanged, is not the person's.
      return entries.length != 1 || entries.first.id != handle['entry'] || entries.first.updated != handle['updated'];
    }
    return entries.isNotEmpty;
  }

  @override
  Future<void> drop(RecipeItem i, Map<String, Object?> handle) async {
    switch (i.kind) {
      case ItemKind.library:
        final t = _transferOf(i);
        if (t != null) await browse.cancel(t.entry);
        final z = _zimOf(i);
        if (z != null) await sources.remove(z);
      case ItemKind.mapRegion:
        final id = handle['region'];
        if (id is String && regions?.regionOf(id) != null) await regions!.remove(id);
      case ItemKind.notebook || ItemKind.checklist:
        final id = handle['notebook'];
        if (id is String && notebooks?.notebook(id) != null) await notebooks!.deleteNotebook(id);
      case ItemKind.liveSource || ItemKind.askStarters:
        break;
    }
  }

  @override
  Object? readSetting(String key) {
    if (key.startsWith('live:')) return weather.isOn(key.substring(5));
    if (key.startsWith('home:')) {
      final b = HomeBlock.byName(key.substring(5));
      return b == null ? null : layout.isOn(b);
    }
    if (key == 'watch:here') return settings.watchHere;
    return null;
  }

  @override
  Future<void> writeSetting(String key, Object? value) async {
    final on = value == true;
    if (key.startsWith('live:')) {
      final id = key.substring(5);
      final c = weather.sourceById(id);
      if (c != null) {
        await weather.setSourceOn(c, on);
      } else {
        settings.setLiveSourcesOn([id], on);
        await weather.sourcesChanged();
      }
    } else if (key.startsWith('home:')) {
      final b = HomeBlock.byName(key.substring(5));
      if (b != null) layout.setBlockOn(b, on);
    } else if (key == 'watch:here') {
      settings.setWatchHere(on);
    }
  }

  // ---- what Discover shows

  @override
  int? sizeOf(RecipeItem i) => switch (i.kind) {
    ItemKind.library => _entries[i.key]?.size ?? _zimOf(i)?.size,
    ItemKind.mapRegion => _home == null ? null : regions?.offer(_home!).bytes ?? regions?.regionOf(_home!.id)?.bytes,
    _ => null,
  };

  @override
  String? titleOf(RecipeItem i) => switch (i.kind) {
    ItemKind.library when i.title.isEmpty => _entries[i.key]?.title,
    ItemKind.liveSource => weather.sourceById(i.id)?.title,
    ItemKind.mapRegion => _home == null ? null : '${_home!.name} map and routes',
    _ => null,
  };

  @override
  String? providerOf(RecipeItem i) => switch (i.kind) {
    ItemKind.liveSource => switch (weather.sourceById(i.id)?.provider) {
      final p? when p.isNotEmpty => p,
      _ => i.id,
    },
    ItemKind.library => 'Kiwix',
    _ => null,
  };

  @override
  String providerDetail(RecipeItem i) => switch (i.kind) {
    ItemKind.liveSource => weather.sourceById(i.id)?.title ?? 'Live data',
    ItemKind.library => 'Library downloads',
    _ => '',
  };

  @override
  int? freeBytes() {
    final dir = sources.zimsDir;
    return dir == null ? null : freeBytesOnDisk(dir.path);
  }

  @override
  DlState progressOf(RecipeItem i) {
    switch (i.kind) {
      case ItemKind.library:
        final z = _zimOf(i);
        if (z != null) return DlState(DlPhase.done, total: z.size);
        final t = _transferOf(i);
        if (t != null) return zimDl(browse.deviceTransfer(t.entry) ?? t);
        return DlState(DlPhase.failed, reason: DlReason.noConnection, total: sizeOf(i) ?? i.approxBytes);
      case ItemKind.mapRegion:
        final l = _home == null ? null : regions?.regionOf(_home!.id);
        if (l == null) return const DlState(DlPhase.waiting, waitLine: 'Waits for your place');
        return switch (l.phase) {
          RegionPhase.ready => DlState(DlPhase.done, total: l.bytes),
          RegionPhase.downloading => DlState(DlPhase.running, done: l.bytes, total: regions!.totalBytesOf(l) ?? 0),
          RegionPhase.paused => DlState(DlPhase.paused, done: l.bytes, total: regions!.totalBytesOf(l) ?? 0),
          RegionPhase.stopped || RegionPhase.failed => DlState(DlPhase.failed, done: l.bytes, total: regions!.totalBytesOf(l) ?? 0, reasonText: l.error),
        };
      default:
        return const DlState(DlPhase.done);
    }
  }

  @override
  DlActions actionsOf(BuildContext context, RecipeItem i) {
    final t = i.kind == ItemKind.library ? _transferOf(i) : null;
    return t == null ? const DlActions() : zimActions(context, browse, t.entry);
  }

  @override
  String? searchLine(RecipeItem i) {
    if (i.kind != ItemKind.library) return null;
    final z = _zimOf(i);
    if (z == null) return 'Waits for its download';
    final id = sources.idOf(z), s = indexing;
    if (id == null || s == null) return null;
    return indexRowWords(s, zimIndexKeys(id));
  }

  @override
  bool hasUpdate(RecipeItem i) {
    if (i.kind != ItemKind.library) return false;
    final z = _zimOf(i);
    return z != null && browse.updates.containsKey(z.path);
  }

  @override
  Future<void> update(RecipeItem i) async {
    final z = _zimOf(i);
    if (z != null) await browse.update(z);
  }

  @override
  Future<void> getOwn(RecipeItem i) async {
    if (i.kind == ItemKind.library) await add(i, null);
  }

  @override
  List<MapOffer> get maps {
    final r = regions;
    if (r == null) return const [];
    final out = <MapOffer>[];
    final seen = <String>{};
    for (final rec in [?_home, ..._near]) {
      if (!seen.add(rec.id)) continue;
      out.add(MapOffer(
        id: rec.id,
        title: rec.name,
        subtitle: 'Roads and places',
        bytes: r.offer(rec).bytes,
        onDevice: r.regionOf(rec.id) != null,
        home: rec.id == _home?.id,
      ));
    }
    for (final l in r.local) {
      if (seen.add(l.id)) out.add(MapOffer(id: l.id, title: l.name, subtitle: 'Roads and places', bytes: l.bytes, onDevice: true));
    }
    return out;
  }

  @override
  Future<void> getMap(MapOffer m) async {
    final r = regions;
    if (r == null) return;
    final rec = await r.recordOf(m.id);
    if (rec == null) return;
    final o = r.offer(rec);
    if (o.kind == RegionOfferKind.download) await r.download(rec, routing: o.routing, map: o.map, places: o.places);
  }
}
