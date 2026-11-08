// Rule: this file stays free of Flutter imports, so the install and remove rules are tested on their own (test/discover_ledger_test).

import 'recipe.dart';

/// What Discover does to the device, for the ledger: the real one works on the Library, Regions, Notebooks and Settings
/// (discover_ports.dart); tests use a fake.
abstract interface class DiscoverPorts {
  /// The item is on this device now, or on its way (a download running or paused).
  Future<bool> isPresent(RecipeItem item);

  /// Puts the item on the device (starts its download, makes its notebook) and returns what is needed to remove it again
  /// (the region's id, the notebook's id). [handle] is what an earlier add returned, when another activity added it before: the
  /// add then only makes sure every part [item] asks for is there.
  Future<Map<String, Object?>> add(RecipeItem item, Map<String, Object?>? handle);

  /// The person uses what the item made (a notebook with entries in it): it is theirs now and is never removed.
  Future<bool> personUses(RecipeItem item, Map<String, Object?> handle);

  /// Removes the item from the device.
  Future<void> drop(RecipeItem item, Map<String, Object?> handle);

  /// A setting's value now (see [isKnownSettingKey] and `live:<id>`).
  Object? readSetting(String key);
  Future<void> writeSetting(String key, Object? value);
}

/// One setting an activity changed: the value before and the value it set.
class SettingChange {
  const SettingChange(this.key, this.before, this.after);

  final String key;
  final Object? before;
  final Object? after;

  Map<String, dynamic> toJson() => {'key': key, 'before': before, 'after': after};
  static SettingChange fromJson(Map j) => SettingChange('${j['key']}', j['before'], j['after']);
}

/// What one added activity holds.
class ActivityRecord {
  ActivityRecord({required this.id, required this.revision, required this.at, List<String>? items, List<String>? settings, List<SettingChange>? changed, Set<String>? leftOut})
    : items = items ?? [],
      settings = settings ?? [],
      changed = changed ?? [],
      leftOut = leftOut ?? {};

  final String id;

  /// The recipe's revision when it was added (a newer recipe shows Update).
  int revision;

  /// When it was added (ms since the epoch).
  final int at;

  /// The item keys it holds (downloads, notebooks, checklists, starter questions).
  final List<String> items;

  /// The setting keys it holds (live sources it switched on, and its settings).
  final List<String> settings;

  /// The settings it actually changed, with each one's value before (one it found already set is held, not changed).
  final List<SettingChange> changed;

  /// The items the person switched off in Customize.
  final Set<String> leftOut;

  Map<String, dynamic> toJson() => {
    'id': id,
    'revision': revision,
    'at': at,
    'items': items,
    'settings': settings,
    'changed': [for (final c in changed) c.toJson()],
    'left_out': leftOut.toList()..sort(),
  };

  static ActivityRecord fromJson(Map j) => ActivityRecord(
    id: '${j['id']}',
    revision: j['revision'] is int ? j['revision'] as int : 1,
    at: j['at'] is int ? j['at'] as int : 0,
    items: [for (final x in (j['items'] as List? ?? const [])) '$x'],
    settings: [for (final x in (j['settings'] as List? ?? const [])) '$x'],
    changed: [for (final x in (j['changed'] as List? ?? const [])) if (x is Map) SettingChange.fromJson(x)],
    leftOut: {for (final x in (j['left_out'] as List? ?? const [])) '$x'},
  );
}

/// One item on the device that activities hold: downloaded once, kept while any activity (or the person) uses it.
class ItemEntry {
  ItemEntry({required this.item, required this.preexisting, required this.handle, Set<String>? holders}) : holders = holders ?? {};

  /// The item as the recipe named it when it was added (so it can be removed after the recipe has changed).
  final RecipeItem item;

  /// It was on the device before any activity added it: the person's, never removed by Discover.
  final bool preexisting;
  Map<String, Object?> handle;

  /// The activities that hold it.
  final Set<String> holders;

  Map<String, dynamic> toJson() => {'item': item.toJson(), 'preexisting': preexisting, 'handle': handle, 'holders': holders.toList()..sort()};

  static ItemEntry fromJson(Map j) => ItemEntry(
    item: RecipeItem.fromJson(j['item']),
    preexisting: j['preexisting'] == true,
    handle: ((j['handle'] as Map?) ?? const {}).cast<String, Object?>(),
    holders: {for (final x in (j['holders'] as List? ?? const [])) '$x'},
  );
}

/// One setting activities changed: the value it had before the first of them changed it, and the value they set.
class SettingEntry {
  SettingEntry({required this.before, required this.set, Set<String>? holders}) : holders = holders ?? {};

  final Object? before;
  final Object? set;
  final Set<String> holders;

  Map<String, dynamic> toJson() => {'before': before, 'set': set, 'holders': holders.toList()..sort()};
  static SettingEntry fromJson(Map j) => SettingEntry(before: j['before'], set: j['set'], holders: {for (final x in (j['holders'] as List? ?? const [])) '$x'});
}

/// An item as the Get sheet and Customize show it before anything installs.
class PlannedItem {
  const PlannedItem(this.item, {this.isNew = true, this.sharedWith = const [], this.already = false});

  final RecipeItem item;

  /// It is added by this activity (downloaded or made).
  final bool isNew;

  /// The other activities that hold it already.
  final List<String> sharedWith;

  /// It is on the device already (the person's, or another activity's).
  final bool already;
}

/// What getting an activity would do: what it adds, what it shares, and what it changes.
class InstallPlan {
  const InstallPlan({required this.items, required this.changes});

  /// The items switched on, in the recipe's order.
  final List<PlannedItem> items;

  /// The settings it would change, with their values now.
  final List<SettingChange> changes;

  Iterable<PlannedItem> get adds => items.where((p) => p.isNew);
}

/// What removing an activity would do.
class RemovePlan {
  const RemovePlan({required this.goes, required this.kept, required this.restores, required this.keptSettings});

  /// Items that go (no other activity holds them, the person did not have them and does not use them).
  final List<RecipeItem> goes;

  /// Items that stay, and why ("Used by Ready", "Yours").
  final List<(RecipeItem, String)> kept;

  /// Settings put back to their value before.
  final List<SettingChange> restores;

  /// Settings left as they are because the person changed them since (or another activity holds them).
  final List<String> keptSettings;
}

/// The settings keys an item stands for: a live source is switched on by its item.
String? settingKeyOf(RecipeItem i) => i.kind == ItemKind.liveSource ? 'live:${i.id}' : null;

/// What every added activity holds on this device, and how to add and remove them. Shared items are downloaded once and counted:
/// an item goes only when no activity holds it, the person did not have it before, and the person does not use it; a setting is
/// put back only when the person has not changed it since. Notes, places and other personal data are never touched (notebooks
/// with entries count as used).
class Ledger {
  Ledger({Map<String, ActivityRecord>? activities, Map<String, ItemEntry>? items, Map<String, SettingEntry>? settings})
    : activities = activities ?? {},
      items = items ?? {},
      settings = settings ?? {};

  final Map<String, ActivityRecord> activities;
  final Map<String, ItemEntry> items;
  final Map<String, SettingEntry> settings;

  static const int kVersion = 1;

  bool has(String activityId) => activities.containsKey(activityId);

  Map<String, dynamic> toJson() => {
    'v': kVersion,
    'activities': {for (final e in activities.entries) e.key: e.value.toJson()},
    'items': {for (final e in items.entries) e.key: e.value.toJson()},
    'settings': {for (final e in settings.entries) e.key: e.value.toJson()},
  };

  static Ledger fromJson(Object? j) {
    if (j is! Map || j['v'] != kVersion) return Ledger();
    Map<String, T> read<T>(String k, T Function(Map) f) {
      final out = <String, T>{};
      for (final e in ((j[k] as Map?) ?? const {}).entries) {
        try {
          if (e.value is Map) out['${e.key}'] = f(e.value as Map);
        } catch (_) {}
      }
      return out;
    }

    return Ledger(activities: read('activities', ActivityRecord.fromJson), items: read('items', ItemEntry.fromJson), settings: read('settings', SettingEntry.fromJson));
  }

  /// The activities other than [except] that hold [key] (an item or a setting).
  List<String> holdersOf(String key, {String? except}) =>
      [for (final h in items[key]?.holders ?? settings[key]?.holders ?? const <String>{}) if (h != except) h]..sort();

  static List<RecipeItem> _chosen(Activity a, Set<String> leftOut) => [for (final i in a.items) if (!leftOut.contains(i.key)) i];

  static List<RecipeSetting> _settingsOf(Activity a, Set<String> leftOut) => [
    for (final i in _chosen(a, leftOut)) if (settingKeyOf(i) case final k?) RecipeSetting(k, true),
    ...a.settings,
  ];

  /// The items the person leaves out by default (switched off in the recipe).
  static Set<String> defaultLeftOut(Activity a) => {for (final i in a.items) if (!i.defaultOn) i.key};

  /// What getting [a] with [leftOut] switched off would do, from what is on the device now.
  Future<InstallPlan> plan(Activity a, DiscoverPorts ports, {Set<String>? leftOut}) async {
    final out = leftOut ?? defaultLeftOut(a);
    final planned = <PlannedItem>[];
    for (final i in _chosen(a, out)) {
      final key = settingKeyOf(i) ?? i.key;
      final others = holdersOf(key, except: a.id);
      if (i.kind == ItemKind.liveSource) {
        final on = ports.readSetting(key) == true;
        planned.add(PlannedItem(i, isNew: !on, sharedWith: others, already: on));
        continue;
      }
      final e = items[key];
      final present = await ports.isPresent(i);
      final held = e != null && (e.holders.contains(a.id) || others.isNotEmpty);
      planned.add(PlannedItem(i, isNew: !present && !held, sharedWith: others, already: present));
    }
    return InstallPlan(items: planned, changes: [
      for (final s in _settingsOf(a, out))
        if (ports.readSetting(s.key) != s.value) SettingChange(s.key, ports.readSetting(s.key), s.value),
    ]);
  }

  /// Adds [a] (or brings an added one up to its recipe): adds its chosen items not on the device, counts the ones it shares,
  /// changes its settings and records each one's value before. Items and settings an older revision held and this one does not
  /// are released as [remove] would. Returns the record.
  Future<ActivityRecord> install(Activity a, DiscoverPorts ports, {Set<String>? leftOut, int? now}) async {
    final out = leftOut ?? activities[a.id]?.leftOut ?? defaultLeftOut(a);
    final old = activities[a.id];
    final rec = ActivityRecord(id: a.id, revision: a.revision, at: old?.at ?? now ?? DateTime.now().millisecondsSinceEpoch, leftOut: out, changed: [...?old?.changed]);
    activities[a.id] = rec;
    for (final i in _chosen(a, out)) {
      if (i.kind == ItemKind.liveSource) continue;
      final key = i.key;
      final e = items[key];
      if (e == null) {
        final present = await ports.isPresent(i);
        final handle = present ? <String, Object?>{} : await ports.add(i, null);
        items[key] = ItemEntry(item: i, preexisting: present, handle: handle, holders: {a.id});
      } else {
        // Another activity added it: a region gets the parts this one asks for; anything else only when it is gone since.
        if (!e.preexisting && (i.kind == ItemKind.mapRegion || !await ports.isPresent(i))) e.handle = await ports.add(i, e.handle);
        e.holders.add(a.id);
      }
      rec.items.add(key);
    }
    for (final s in _settingsOf(a, out)) {
      final now = ports.readSetting(s.key);
      final e = settings[s.key];
      if (e != null && now == e.set && e.set == s.value) {
        e.holders.add(a.id);
      } else if (now == s.value) {
        // Already so, by the person or the app's defaults: nothing to change, nothing to put back.
        if (e != null) settings.remove(s.key);
        rec.changed.removeWhere((c) => c.key == s.key);
        continue;
      } else {
        await ports.writeSetting(s.key, s.value);
        settings[s.key] = SettingEntry(before: now, set: s.value, holders: {a.id});
        rec.changed
          ..removeWhere((c) => c.key == s.key)
          ..add(SettingChange(s.key, now, s.value));
      }
      rec.settings.add(s.key);
    }
    // An update: what the old revision held and this one does not is released.
    if (old != null) {
      await _release(a.id, [for (final k in old.items) if (!rec.items.contains(k)) k], [for (final k in old.settings) if (!rec.settings.contains(k)) k], ports);
      rec.changed.removeWhere((c) => !rec.settings.contains(c.key));
    }
    return rec;
  }

  /// What removing [activityId] would do, from what is on the device now.
  Future<RemovePlan> planRemove(String activityId, DiscoverPorts ports, {String Function(String id)? titleOf}) async {
    final rec = activities[activityId];
    if (rec == null) return const RemovePlan(goes: [], kept: [], restores: [], keptSettings: []);
    String names(List<String> ids) => ids.map(titleOf ?? (s) => s).join(', ');
    final goes = <RecipeItem>[];
    final kept = <(RecipeItem, String)>[];
    for (final k in rec.items) {
      final e = items[k];
      if (e == null) continue;
      final others = holdersOf(k, except: activityId);
      if (others.isNotEmpty) {
        kept.add((e.item, 'Used by ${names(others)}'));
      } else if (e.preexisting || await ports.personUses(e.item, e.handle)) {
        kept.add((e.item, 'Yours'));
      } else {
        goes.add(e.item);
      }
    }
    final restores = <SettingChange>[];
    final keptSettings = <String>[];
    for (final k in rec.settings) {
      final e = settings[k];
      if (e == null) continue;
      if (holdersOf(k, except: activityId).isNotEmpty || ports.readSetting(k) != e.set) {
        keptSettings.add(k);
      } else {
        restores.add(SettingChange(k, e.set, e.before));
      }
    }
    return RemovePlan(goes: goes, kept: kept, restores: restores, keptSettings: keptSettings);
  }

  /// Removes [activityId]: releases its items and settings (see [Ledger]).
  Future<void> remove(String activityId, DiscoverPorts ports) async {
    final rec = activities.remove(activityId);
    if (rec == null) return;
    await _release(activityId, rec.items, rec.settings, ports);
  }

  Future<void> _release(String activityId, List<String> itemKeys, List<String> settingKeys, DiscoverPorts ports) async {
    for (final k in itemKeys) {
      final e = items[k];
      if (e == null) continue;
      e.holders.remove(activityId);
      if (e.holders.isNotEmpty) continue;
      items.remove(k);
      if (e.preexisting || await ports.personUses(e.item, e.handle)) continue;
      await ports.drop(e.item, e.handle);
    }
    for (final k in settingKeys) {
      final e = settings[k];
      if (e == null) continue;
      e.holders.remove(activityId);
      if (e.holders.isNotEmpty) continue;
      settings.remove(k);
      // Put back only what the person has not changed since.
      if (ports.readSetting(k) == e.set) await ports.writeSetting(k, e.before);
    }
  }

  /// An item the person removed by hand (a library deleted in the Library): no activity holds it any more, and nothing is
  /// downloaded again by itself.
  void forget(String key) => items.remove(key);
}
