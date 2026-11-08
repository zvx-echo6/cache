import 'dart:io';

import 'package:cache/discover/discover_state.dart';
import 'package:cache/discover/recipe.dart';
import 'package:cache/downloads/download_row.dart';
import 'package:flutter/widgets.dart';

/// Discover's device on plain maps: what is on the device, the settings, sizes, downloads and maps, with every call written down.
class FakeDiscoverDevice extends ChangeNotifier implements DiscoverDevice {
  FakeDiscoverDevice({this.free = 38 << 30});

  /// Item keys on the device (or on their way).
  final Set<String> present = {};

  /// Settings by key.
  final Map<String, Object?> settings = {};

  /// Sizes by item key (else the recipe's).
  final Map<String, int> sizes = {};

  /// Downloads by item key (else done when present, idle when not).
  final Map<String, DlState> downloads = {};

  /// Item keys with a newer release out.
  final Set<String> updates = {};

  /// Item keys the person uses (a notebook with entries).
  final Set<String> used = {};

  /// Who each live source is, by id.
  final Map<String, String> providers = {
    'openmeteo-forecast': 'Open-Meteo',
    'nws-alerts-point': 'National Weather Service',
    'ipaws-alerts-near': 'FEMA IPAWS',
    'wfigs-incidents-near': 'Fire incident feed',
    'avalanche-forecast-zones': 'avalanche.org',
  };

  /// What each search index says, by item key.
  final Map<String, String> search = {};

  final List<String> added = [];
  final List<String> dropped = [];
  final List<String> writes = [];
  final List<String> own = [];

  int? free;

  @override
  List<MapOffer> maps = const [];

  @override
  DiscoverPlace? place = const DiscoverPlace(lat: 43.6, lon: -116.2, here: true);

  @override
  Listenable get changes => this;

  void changed() => notifyListeners();

  @override
  Future<void> resolve(Iterable<RecipeItem> items) async {}

  @override
  Future<bool> isPresent(RecipeItem item) async => item.kind == ItemKind.liveSource ? settings['live:${item.id}'] == true : present.contains(item.key);

  @override
  Future<Map<String, Object?>> add(RecipeItem item, Map<String, Object?>? handle) async {
    added.add(item.key);
    present.add(item.key);
    return {'made': item.key};
  }

  @override
  Future<bool> personUses(RecipeItem item, Map<String, Object?> handle) async => used.contains(item.key);

  @override
  Future<void> drop(RecipeItem item, Map<String, Object?> handle) async {
    dropped.add(item.key);
    present.remove(item.key);
  }

  @override
  Object? readSetting(String key) => settings[key] ?? false;

  @override
  Future<void> writeSetting(String key, Object? value) async {
    writes.add('$key=$value');
    settings[key] = value;
  }

  @override
  int? sizeOf(RecipeItem item) => sizes[item.key];

  @override
  String? titleOf(RecipeItem item) => item.kind == ItemKind.mapRegion ? 'Home region map and routes' : null;

  @override
  String? providerOf(RecipeItem item) => switch (item.kind) {
    ItemKind.liveSource => providers[item.id] ?? item.id,
    ItemKind.library => 'Kiwix',
    _ => null,
  };

  @override
  String providerDetail(RecipeItem item) => switch (item.kind) {
    ItemKind.liveSource => item.title.isEmpty ? 'Live data' : item.title,
    ItemKind.library => 'Library downloads',
    _ => '',
  };

  @override
  int? freeBytes() => free;

  @override
  DlState progressOf(RecipeItem item) => downloads[item.key] ?? (present.contains(item.key) ? DlState(DlPhase.done, total: sizes[item.key] ?? item.approxBytes) : const DlState(DlPhase.idle));

  @override
  DlActions actionsOf(BuildContext context, RecipeItem item) => DlActions(pause: () {}, resume: () {});

  @override
  String? searchLine(RecipeItem item) => item.kind == ItemKind.library ? search[item.key] : null;

  @override
  bool hasUpdate(RecipeItem item) => updates.contains(item.key);

  @override
  Future<void> update(RecipeItem item) async {
    updates.remove(item.key);
  }

  @override
  Future<void> getOwn(RecipeItem item) async {
    own.add(item.key);
    present.add(item.key);
  }

  @override
  Future<void> getMap(MapOffer m) async => own.add('map:${m.id}');
}

/// The catalogue file the app carries (tests run in app/).
String bundledDiscover() => File('assets/discover/catalogue.json').readAsStringSync();

/// A Discover on [device] with the app's own catalogue: its file in [dir], or in memory only without one (widget tests: no file
/// is written while a test pumps).
Future<DiscoverState> makeDiscover(FakeDiscoverDevice device, {Directory? dir, bool firstRunDone = true}) async {
  final d = DiscoverState(device: device, settingsDirOverride: dir, persist: dir != null, bundled: () async => bundledDiscover(), now: () => 1793491200000);
  await d.init();
  if (firstRunDone) await d.setFirstRunDone();
  return d;
}
