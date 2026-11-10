import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

import '../app_fs.dart';
import '../downloads/download_row.dart' show DlActions, DlState, DlPhase;
import '../platform/app_log.dart';
import '../search/core_config.dart' show kDataBaseUrl;
import 'ledger.dart';
import 'recipe.dart';

/// Where Cache's own Discover file is published, so activities and collections change without an app release.
const String kDiscoverUrl = '$kDataBaseUrl/discover/catalogue.json';

/// The copy built into the app (docs/discover-catalogue.json in the repository; a test keeps them equal), used on first run,
/// offline and when the published file cannot be read.
const String kDiscoverAsset = 'assets/discover/catalogue.json';

/// A place Discover gets maps and weather for: where the device is, or one the person chose.
class DiscoverPlace {
  const DiscoverPlace({required this.lat, required this.lon, this.name = '', this.here = false});

  final double lat;
  final double lon;
  final String name;

  /// The device's own position (Where I am now).
  final bool here;

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon, if (name.isNotEmpty) 'name': name, if (here) 'here': true};
  static DiscoverPlace? fromJson(Object? j) => j is Map && j['lat'] is num && j['lon'] is num
      ? DiscoverPlace(lat: (j['lat'] as num).toDouble(), lon: (j['lon'] as num).toDouble(), name: '${j['name'] ?? ''}', here: j['here'] == true)
      : null;
}

/// A map region Discover offers in its Maps row.
class MapOffer {
  const MapOffer({required this.id, required this.title, required this.subtitle, this.bytes, this.onDevice = false, this.home = false});

  final String id;
  final String title;
  final String subtitle;
  final int? bytes;
  final bool onDevice;

  /// The region of the person's place (the one activities add).
  final bool home;
}

/// Everything Discover reads from and does to the device besides the ledger's own calls: sizes, titles, progress, updates and
/// the person's own Gets (Libraries, Maps, Collections). The app's is discover_device.dart; tests and renders use a fake.
abstract interface class DiscoverDevice implements DiscoverPorts {
  /// Fires when anything Discover shows may have changed (a download moved, a library arrived).
  Listenable get changes;

  /// Looks up the real sizes and titles of [items] (the Kiwix catalogue, the region list); quiet when offline.
  Future<void> resolve(Iterable<RecipeItem> items);

  /// The item's size from the live catalogue; null while not known (the recipe's approx_bytes is used).
  int? sizeOf(RecipeItem item);

  /// The item's name from the live catalogue or the device; null: the recipe's title.
  String? titleOf(RecipeItem item);

  /// Who an outside source is ("National Weather Service"), for Connects to; null for an item that connects to nothing.
  String? providerOf(RecipeItem item);

  /// What an outside source gives ("Forecast and alerts").
  String providerDetail(RecipeItem item);

  /// Free space on the device as the screens show it (free now); null when it cannot be told.
  int? freeBytes();

  /// What a download may use: the allowance (free now, and on iPhone half of what iOS can purge) less what Cache leaves for the
  /// phone. The Get sheet, the wizard and the activity page check sizes against this, not against [freeBytes].
  int? usableBytes();

  /// The item's download as the app's download rows show it.
  DlState progressOf(RecipeItem item);

  /// What the item's row controls do (pause, resume, remove a download).
  DlActions actionsOf(BuildContext context, RecipeItem item);

  /// The item's search index work in the app's words ("Waits for its download"); null when there is none.
  String? searchLine(RecipeItem item);

  /// A newer release of the item is out (a library's newer month, a region's newer build).
  bool hasUpdate(RecipeItem item);
  Future<void> update(RecipeItem item);

  /// The person's own Get, from a tile (not an activity's): theirs, as if got from the Library.
  Future<void> getOwn(RecipeItem item);

  /// The map regions for the person's place, and the ones on the device.
  List<MapOffer> get maps;
  Future<void> getMap(MapOffer m);

  /// The place maps and weather are for; null until one is known.
  DiscoverPlace? get place;
  set place(DiscoverPlace? p);
}

/// How an activity stands on this device.
enum ActivityStatus { notAdded, adding, added, update }

/// Discover: Cache's own catalogue of activities and collections, what is added, and the first-run wizard's progress. Kept in
/// discover.json in the support folder (the ledger of what each activity added and changed, and whether first run is done).
class DiscoverState extends ChangeNotifier {
  DiscoverState({
    required this.device,
    this.settingsDirOverride,
    Future<String> Function()? bundled,
    this.fetch,
    this.now,
    this.persist = true,
  }) : _bundled = bundled ?? (() => rootBundle.loadString(kDiscoverAsset)) {
    device.changes.addListener(notifyListeners);
  }

  /// The one Discover of the app, for the places that open it without the frame's objects (the Library's Add to Library). Null in
  /// tests that do not set it.
  static DiscoverState? shared;

  final DiscoverDevice device;
  final Directory? settingsDirOverride;
  final Future<String> Function() _bundled;

  /// Reads the published file; null: only the copy in the app.
  final Future<String> Function()? fetch;
  final int Function()? now;

  /// Keeps discover.json (false: in memory only, for widget tests and renders).
  final bool persist;

  DiscoverCatalogue catalogue = DiscoverCatalogue.empty;
  Ledger ledger = Ledger();

  /// The wizard was finished or skipped (or this device was set up before Discover came).
  bool firstRunDone = false;

  /// The person chose "Choose a place" rather than "Where I am now" in the wizard.
  bool choosePlace = false;

  bool _started = false;
  bool get started => _started;
  AppFs? _fs;

  static const String _name = 'discover.json';

  @override
  void dispose() {
    device.changes.removeListener(notifyListeners);
    super.dispose();
  }

  /// Reads discover.json and the catalogue (the copy in the app, the newer copy kept from the web), then looks for a newer
  /// published file in the background. [setUpBefore]: something is on this device already (an update from before Discover), so
  /// first run counts as done.
  Future<void> init({bool setUpBefore = false}) async {
    if (persist) {
      await _read(setUpBefore);
    } else if (setUpBefore) {
      firstRunDone = true;
    }
    try {
      catalogue = DiscoverCatalogue.parse(await _bundled());
    } catch (e) {
      logError('The Discover file in the app could not be read', error: e);
    }
    try {
      final kept = await _fs?.readString(AppRoot.support, 'discover-catalogue.json');
      if (kept != null) _useIfNewer(kept);
    } catch (_) {}
    _started = true;
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> _read(bool setUpBefore) async {
    try {
      final fs = createAppFs(supportOverride: settingsDirOverride);
      await fs.mkdir(AppRoot.support, '');
      _fs = fs;
      final text = await fs.readString(AppRoot.support, _name);
      if (text == null) {
        // An update from before Discover: kept, so the wizard never comes for a device that was set up.
        if (setUpBefore) {
          firstRunDone = true;
          await _save();
        }
        return;
      }
      final j = jsonDecode(text);
      if (j is! Map) return;
      ledger = Ledger.fromJson(j['ledger']);
      firstRunDone = j['first_run_done'] == true;
      choosePlace = j['choose_place'] == true;
      final p = DiscoverPlace.fromJson(j['place']);
      if (p != null && (choosePlace || device.place == null)) device.place = p;
    } catch (e) {
      logError('Discover could not read its file', error: e);
    }
  }

  bool _useIfNewer(String text) {
    try {
      final c = DiscoverCatalogue.parse(text);
      if (c.updated.compareTo(catalogue.updated) < 0) return false;
      catalogue = c;
      return true;
    } catch (e) {
      logInfo('A Discover file was not used', detail: '$e');
      return false;
    }
  }

  /// Fetches the published file and keeps it when it is newer and this build reads it; then looks up the live sizes.
  Future<void> refresh() async {
    final f = fetch;
    if (f != null) {
      try {
        final text = await f();
        if (_useIfNewer(text)) await _fs?.writeStringAtomic(AppRoot.support, 'discover-catalogue.json', text);
      } catch (e) {
        logInfo('The published Discover file could not be read', detail: '$e');
      }
    }
    notifyListeners();
    try {
      await device.resolve([for (final a in catalogue.activities) ...a.items, for (final c in catalogue.collections) ...c.items, ...catalogue.libraries]);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    final fs = _fs;
    if (fs == null) return;
    try {
      await fs.writeStringAtomic(
        AppRoot.support,
        _name,
        jsonEncode({'v': 1, 'first_run_done': firstRunDone, 'choose_place': choosePlace, 'place': ?device.place?.toJson(), 'ledger': ledger.toJson()}),
      );
    } catch (e) {
      logError('Discover could not save its file', error: e);
    }
  }

  // ---- first run

  Future<void> setFirstRunDone() async {
    firstRunDone = true;
    notifyListeners();
    await _save();
  }

  Future<void> setPlace(DiscoverPlace? p, {required bool chosen}) async {
    device.place = p;
    choosePlace = chosen;
    notifyListeners();
    await _save();
  }

  // ---- what is shown

  /// The item's size: the live catalogue's, else the recipe's.
  int bytesOf(RecipeItem i) => device.sizeOf(i) ?? i.approxBytes;

  String titleOf(RecipeItem i) => device.titleOf(i) ?? (i.title.isNotEmpty ? i.title : i.name);

  /// The item of any recipe with [key] (a live source's title for a setting's words).
  RecipeItem? itemByKey(String key) {
    for (final a in catalogue.activities) {
      for (final i in a.items) {
        if (i.key == key) return i;
      }
    }
    return ledger.items[key]?.item;
  }

  String activityTitle(String id) => catalogue.activity(id)?.title ?? id;

  ActivityStatus status(Activity a) {
    final rec = ledger.activities[a.id];
    if (rec == null) return ActivityStatus.notAdded;
    if (progress(a).any((p) => p.$2.active)) return ActivityStatus.adding;
    if (rec.revision < a.revision || a.items.any((i) => rec.items.contains(i.key) && device.hasUpdate(i))) return ActivityStatus.update;
    return ActivityStatus.added;
  }

  /// The first activity not added yet; null when every one is.
  Activity? get featured => catalogue.activities.where((a) => !ledger.has(a.id)).firstOrNull;

  /// The items the person switched off before Get (Customize), by activity; the recipe's defaults when not changed.
  final Map<String, Set<String>> _drafts = {};

  Set<String> leftOutOf(Activity a) => _drafts[a.id] ?? ledger.activities[a.id]?.leftOut ?? Ledger.defaultLeftOut(a);

  void setLeftOut(Activity a, String key, bool leftOut) {
    final s = {...leftOutOf(a)};
    leftOut ? s.add(key) : s.remove(key);
    _drafts[a.id] = s;
    notifyListeners();
  }

  Future<InstallPlan> plan(Activity a, {Set<String>? leftOut}) => ledger.plan(a, device, leftOut: leftOut ?? leftOutOf(a));

  /// What the plan downloads.
  int addsBytes(InstallPlan p) => p.adds.where((x) => x.item.kind.downloads).fold(0, (s, x) => s + bytesOf(x.item));

  /// Every item of [a] as switched on, with its size: what the activity holds once added.
  int totalBytes(Activity a) => [for (final i in a.items) if (!leftOutOf(a).contains(i.key) && i.kind.downloads) bytesOf(i)].fold(0, (s, b) => s + b);

  /// An activity's size, the one figure every page shows for it (tile, featured card, listing, wizard, Get sheet): what it holds
  /// once added, else what getting it downloads now (what other activities or the person have already is not counted again).
  Future<int> sizeOf(Activity a) async => ledger.has(a.id) ? totalBytes(a) : addsBytes(await plan(a));

  /// The outside sources the plan connects to, once each ("National Weather Service").
  List<(String, String)> connectsTo(Iterable<RecipeItem> items) {
    final seen = <String>{};
    return [
      for (final i in items)
        if (device.providerOf(i) case final p? when seen.add(p)) (p, device.providerDetail(i)),
    ];
  }

  /// The items of an activity in progress, each with its download (done items included).
  List<(RecipeItem, DlState)> progress(Activity a) {
    final rec = ledger.activities[a.id];
    if (rec == null) return const [];
    return [
      for (final i in a.items)
        if (rec.items.contains(i.key)) (i, i.kind.downloads ? device.progressOf(i) : const DlState(DlPhase.done)),
    ];
  }

  /// How many updates wait: added activities with a newer recipe or a newer release of what they hold, and the person's own
  /// libraries Discover lists.
  int get updateCount {
    final acts = catalogue.activities.where((a) => status(a) == ActivityStatus.update).length;
    final libs = catalogue.libraries.where((i) => !_heldByActivity(i) && device.hasUpdate(i)).length;
    return acts + libs;
  }

  bool _heldByActivity(RecipeItem i) => ledger.items[i.key]?.holders.isNotEmpty ?? false;

  /// Get on a tile, an activity's page or the wizard: adds it with the person's choices.
  Future<void> get(Activity a) async {
    final out = leftOutOf(a);
    await ledger.install(a, device, leftOut: out, now: now?.call());
    _drafts.remove(a.id);
    notifyListeners();
    await _save();
  }

  /// Update: the newer recipe, and the newer releases of what it holds.
  Future<void> updateActivity(Activity a) async {
    await ledger.install(a, device, now: now?.call());
    for (final i in a.items) {
      if (ledger.activities[a.id]!.items.contains(i.key) && device.hasUpdate(i)) await device.update(i);
    }
    notifyListeners();
    await _save();
  }

  /// Try again on an item whose download could not start (no connection then).
  Future<void> retry(Activity a, RecipeItem i) async {
    final e = ledger.items[i.key];
    if (e == null || e.preexisting) return;
    e.handle = await device.add(i, null);
    notifyListeners();
    await _save();
  }

  Future<RemovePlan> planRemove(Activity a) => ledger.planRemove(a.id, device, titleOf: activityTitle);

  Future<void> remove(Activity a) async {
    await ledger.remove(a.id, device);
    notifyListeners();
    await _save();
  }

  /// The items of the person's own Get on a library tile or a collection that are not on the device yet.
  Future<List<RecipeItem>> missing(Iterable<RecipeItem> items) async => [for (final i in items) if (!await device.isPresent(i)) i];

  Future<void> getOwn(Iterable<RecipeItem> items) async {
    for (final i in items) {
      await device.getOwn(i);
    }
    notifyListeners();
  }

  /// Every item and activity whose words hold [query] (titles and lines), for Search Discover.
  ({List<Activity> activities, List<Collection> collections, List<RecipeItem> libraries}) search(String query) {
    final q = query.trim().toLowerCase();
    bool hit(String s) => s.toLowerCase().contains(q);
    return (
      activities: [for (final a in catalogue.activities) if (hit(a.title) || hit(a.tagline) || hit(a.description)) a],
      collections: [for (final c in catalogue.collections) if (hit(c.title) || hit(c.tagline)) c],
      libraries: [for (final l in catalogue.libraries) if (hit(titleOf(l)) || hit(l.subtitle)) l],
    );
  }
}
