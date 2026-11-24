import 'dart:async';

import 'package:flutter/foundation.dart';

import '../roads/road_sources.dart';
import '../weather/connector.dart';
import '../weather/weather_state.dart';
import 'app_settings.dart';
import 'web_search_setup.dart';

/// The one key registry: every provider a person can give a key to, with its steps, page, what uses it, its check and its rate. The master
/// list (Settings > API keys), the shortcut rows, the key sheet, "Used by" and the sync list are all made from these records, so a new keyed
/// source is a record and shows up everywhere. The records come from the connector catalogue (a source's `key_alias`), the road sources
/// (one key per 511 site and WZDx feed), Kagi, the person's own sources.

enum KeyKind { catalogue, road, kagi, own }

/// A feature that uses a key.
class KeyUse {
  const KeyUse(this.label, {this.on = false});

  final String label;

  /// Its switch is on now.
  final bool on;
}

/// One provider's key.
class KeyProvider {
  const KeyProvider({
    required this.id,
    required this.kind,
    required this.provider,
    required this.title,
    required this.getKeyUrl,
    required this.steps,
    required this.stepsChecked,
    required this.uses,
    required this.storageName,
    this.costLine,
    this.rate,
    this.creditText,
    this.canSync = true,
    this.sourceId,
  });

  /// The storage alias (`live.key.<id>`); Kagi: `kagi`.
  final String id;
  final KeyKind kind;

  /// "NASA FIRMS", "Kagi".
  final String provider;

  /// The row's title: "NASA FIRMS API key", "511 key (511.idaho.gov)".
  final String title;
  final String getKeyUrl;
  final List<String> steps;

  /// The steps were checked against the provider (false: a draft, or the generic ones).
  final bool stepsChecked;
  final List<KeyUse> uses;

  /// The name the key is kept under in secure storage.
  final String storageName;
  final String? costLine;
  final String? rate;
  final String? creditText;

  final bool canSync;

  /// A connector id that checks the key (catalogue, road and own sources).
  final String? sourceId;

  /// "Place details and Fuel prices": the features, in words.
  String get usesWords {
    final l = [for (final u in uses) u.label];
    if (l.isEmpty) return '';
    if (l.length == 1) return l.single;
    return '${l.sublist(0, l.length - 1).join(', ')} and ${l.last}';
  }
}

/// The state of a saved key, from the last real use and the last save or Test (nothing is asked of the provider in the background).
enum KeyState { notSet, savedUnchecked, working, refused, limit }

class KeyStatus {
  const KeyStatus(this.state, {this.at});

  final KeyState state;

  /// When it was last known to work.
  final DateTime? at;

  bool get set => state != KeyState.notSet;
}

/// The words of a list row: Set, Not set, Not accepted, Limit reached.
String keyWord(KeyState s) => switch (s) {
  KeyState.notSet => 'Not set',
  KeyState.savedUnchecked || KeyState.working => 'Set',
  KeyState.refused => 'Not accepted',
  KeyState.limit => 'Limit reached',
};

String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// The master list's controller: the records, each key's state and the actions on it.
class ApiKeys extends ChangeNotifier {
  ApiKeys({required this.weather, required this.webSearch, required this.settings}) {
    weather.addListener(_note);
    webSearch.addListener(_note);
  }

  final WeatherState weather;
  final WebSearchSetup webSearch;
  final AppSettings settings;

  final Map<String, (DateTime, bool)> _tested = {};
  bool _disposed = false;

  void _note() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    weather.removeListener(_note);
    webSearch.removeListener(_note);
    super.dispose();
  }

  static const Map<String, ({List<String> steps, String url, String? rate, String? cost})> _known = {
    'firms': (
      steps: ['Go to the MAP_KEY page and choose Get MAP_KEY.', 'Enter your email address. NASA emails you the key.', 'Copy the key from the email.'],
      url: 'https://firms.modaps.eosdis.nasa.gov/api/map_key/',
      rate: '5,000 transactions in any 10 minutes. Cache stays far below that.',
      cost: null,
    ),
    'tomtom': (
      steps: ['Sign up at my.tomtom.com.', 'Create an API key and copy it.'],
      url: 'https://my.tomtom.com/',
      rate: null,
      cost: 'Up to 20,000 traffic flow requests a month with no credit card; beyond that TomTom charges per use.',
    ),
  };

  /// Every provider: Kagi, the catalogue's keyed sources by key name, the road sites and keyed feeds, the person's own sources.
  List<KeyProvider> get providers {
    final out = <KeyProvider>[];
    out.add(KeyProvider(
      id: 'kagi',
      kind: KeyKind.kagi,
      provider: 'Kagi',
      title: 'Kagi API key',
      getKeyUrl: 'https://kagi.com/api/keys',
      steps: const ['Sign in to Kagi and add search credit.', 'Create a key on that page and copy it.'],
      stepsChecked: true,
      costLine: 'Kagi search is a paid service. You need your own key and search credit.',
      uses: [KeyUse('Web search for Ask', on: settings.webSearchOn)],
      storageName: WebSearchSetup.keyName,
    ));
    final roads = weather.roads;
    final roadAliases = <String>{};
    if (roads != null) {
      for (final s in roads.file.sites) {
        final src = roads.sourceForSite(s);
        roadAliases.add(s.keyAlias);
        final added = roads.records.any((r) => r.isSite && r.id == s.host);
        out.add(KeyProvider(
          id: s.keyAlias,
          kind: KeyKind.road,
          provider: s.name,
          title: s.keyTitle,
          getKeyUrl: s.keyPage,
          steps: roads.file.keySteps,
          stepsChecked: false,
          rate: 'Ten calls every 60 seconds on this site. Cache stays under it.',
          uses: [
            if (added && src != null) ...[for (final c in src.connectors) KeyUse(c.entry?.title ?? c.title, on: weather.isOn(c.id))] else KeyUse('Road events from ${s.host}'),
          ],
          storageName: 'live.key.${s.keyAlias}',
          sourceId: src?.connectors.first.id,
        ));
      }
      // A 511 site the person entered that the data file does not list.
      for (final r in roads.sources) {
        final s = r.site;
        if (s == null || roads.file.siteByHost(s.host) != null) continue;
        roadAliases.add(s.keyAlias);
        out.add(KeyProvider(
          id: s.keyAlias,
          kind: KeyKind.road,
          provider: s.name,
          title: s.keyTitle,
          getKeyUrl: s.keyPage,
          steps: roads.file.keySteps,
          stepsChecked: false,
          rate: 'Ten calls every 60 seconds on this site. Cache stays under it.',
          uses: [for (final c in r.connectors) KeyUse(c.entry?.title ?? c.title, on: weather.isOn(c.id))],
          storageName: 'live.key.${s.keyAlias}',
          sourceId: r.connectors.first.id,
        ));
      }
      for (final r in roads.sources) {
        final f = r.feed;
        if (f == null || r.keyAlias == null) continue;
        roadAliases.add(r.keyAlias!);
        out.add(KeyProvider(
          id: r.keyAlias!,
          kind: KeyKind.road,
          provider: f.publisher,
          title: f.keyTitle,
          getKeyUrl: f.keyPage ?? 'https://cached.info',
          steps: const ['Follow their steps to get a key, then copy it.'],
          stepsChecked: false,
          rate: f.rateLimit == null ? null : '${f.rateLimit!.calls} requests per ${f.rateLimit!.window.inHours == 1 ? 'hour' : '${f.rateLimit!.window.inSeconds} seconds'}.',
          uses: [KeyUse('Road work from ${f.publisher}', on: weather.isOn(r.connectors.first.id))],
          storageName: 'live.key.${r.keyAlias}',
          sourceId: r.connectors.first.id,
        ));
      }
    }
    // The catalogue's keyed sources (and the person's own), one record per key name.
    final byAlias = <String, List<Connector>>{};
    for (final c in weather.sources) {
      final a = c.keyAlias;
      if (a == null || roadAliases.contains(a)) continue;
      (byAlias[a] ??= []).add(c);
    }
    for (final e in byAlias.entries) {
      final cs = e.value;
      final c = cs.first;
      final own = weather.isOwn(c);
      final k = _known[e.key];
      final who = c.provider.isEmpty ? c.title : c.provider;
      out.add(KeyProvider(
        id: e.key,
        kind: own ? KeyKind.own : KeyKind.catalogue,
        provider: own ? 'Your own: ${c.title}' : who,
        title: own ? 'Your own: ${c.title}' : '$who API key',
        getKeyUrl: k?.url ?? c.docs ?? 'https://cached.info',
        steps: k?.steps ?? const ['Follow their steps to get a key, then copy it.'],
        stepsChecked: k != null,
        costLine: k?.cost,
        rate: k?.rate,
        uses: [for (final x in cs) KeyUse(_cap(x.title), on: weather.isOn(x.id))],
        storageName: WeatherState.secretName(e.key),
        sourceId: c.id,
      ));
    }
    return out;
  }

  KeyProvider? providerById(String id) => providers.where((p) => p.id == id).firstOrNull;

  bool hasKey(KeyProvider p) => p.kind == KeyKind.kagi ? webSearch.hasKey : weather.hasKey(p.id);

  KeyStatus statusOf(KeyProvider p) {
    if (!hasKey(p)) return const KeyStatus(KeyState.notSet);
    final t = _tested[p.id];
    if (p.kind == KeyKind.kagi) {
      switch (webSearch.lastFailure) {
        case SourceFailure.keyRejected || SourceFailure.keyMissing:
          return const KeyStatus(KeyState.refused);
        case SourceFailure.limit:
          return const KeyStatus(KeyState.limit);
        default:
      }
      return t != null && t.$2 ? KeyStatus(KeyState.working, at: t.$1) : const KeyStatus(KeyState.savedUnchecked);
    }
    DateTime? ok;
    for (final c in weather.sourcesUsingKey(p.id)) {
      final h = weather.healthOf(c);
      if (h == null) continue;
      if (h.failure == SourceFailure.keyRejected) return const KeyStatus(KeyState.refused);
      if (h.failure == SourceFailure.limit) return const KeyStatus(KeyState.limit);
      if (h.lastOkAt != null && (ok == null || h.lastOkAt!.isAfter(ok))) ok = h.lastOkAt;
    }
    if (t != null && t.$2 && (ok == null || t.$1.isAfter(ok))) ok = t.$1;
    return ok != null ? KeyStatus(KeyState.working, at: ok) : const KeyStatus(KeyState.savedUnchecked);
  }

  /// Providers with a key saved, then those without.
  List<KeyProvider> get saved => [for (final p in providers) if (hasKey(p)) p];
  List<KeyProvider> get available => [for (final p in providers) if (!hasKey(p)) p];

  /// A key needs attention (refused).
  int get needAttention => saved.where((p) => statusOf(p).state == KeyState.refused).length;

  Connector? _connectorFor(KeyProvider p) {
    final id = p.sourceId;
    return id == null ? null : weather.sourceById(id);
  }

  Future<KeyCheck> _check(KeyProvider p, String key) async {
    if (p.kind == KeyKind.kagi) {
      try {
        return await webSearch.check(key);
      } catch (_) {
        return const KeyCheck.failed("Couldn't check the key. Try again.");
      }
    }
    final c = _connectorFor(p);
    if (c == null) return const KeyCheck.failed("Couldn't check the key. Try again.");
    return weather.checkKey(c, key);
  }

  /// Saves [raw]: checked with the provider first (a key that fails is not saved), or kept as it is when [check] is false (offline, or a
  /// provider at its limit). Saving turns nothing on.
  Future<KeyCheck> save(KeyProvider p, String raw, {bool check = true}) async {
    final key = raw.trim();
    if (key.isEmpty) return const KeyCheck.failed('Paste your key first.');
    if (check) {
      final r = await _check(p, key);
      if (!r.ok) {
        if (p.kind == KeyKind.kagi) await webSearch.apply();
        return r;
      }
      _tested[p.id] = (DateTime.now(), true);
    } else {
      _tested.remove(p.id);
    }
    try {
      if (p.kind == KeyKind.kagi) {
        await webSearch.keepKey(key);
      } else {
        await weather.keepKey(p.id, key);
      }
    } catch (_) {
      return const KeyCheck.failed("The key was accepted but couldn't be saved on this device.");
    }
    notifyListeners();
    return const KeyCheck.ok();
  }

  /// Test key: one request with the saved key. The result is kept for the row's Status.
  Future<KeyCheck> test(KeyProvider p) async {
    final key = await _read(p);
    if (key == null || key.isEmpty) return const KeyCheck.failed('No key is saved.');
    // A key kept on a Cache server is not readable here: the server checks it (a browser has the reference only).
    final r = key.startsWith('keystore://') ? const KeyCheck.ok() : await _check(p, key);
    _tested[p.id] = (DateTime.now(), r.ok);
    notifyListeners();
    return r;
  }

  Future<String?> _read(KeyProvider p) async {
    try {
      return await weather.secrets.read(p.storageName);
    } catch (_) {
      return null;
    }
  }

  /// Removes the key on this device. It turns nothing off: the features keep their switches and quietly use what is on the device.
  Future<void> remove(KeyProvider p) async {
    if (p.kind == KeyKind.kagi) {
      await webSearch.removeKey();
    } else {
      await weather.removeKey(p.id);
    }
    _tested.remove(p.id);
    notifyListeners();
  }
}

/// "Working, checked 2 hours ago" and the other status lines of an open row.
String keyStatusLine(KeyStatus s, String Function(DateTime) ago) => switch (s.state) {
  KeyState.notSet => '',
  KeyState.savedUnchecked => 'Saved, not checked yet',
  KeyState.working => s.at == null ? 'Working' : 'Working, checked ${ago(s.at!)}',
  KeyState.refused => 'Not accepted',
  KeyState.limit => 'Limit reached. Cache tries again later.',
};

/// What the key's data credit names (About > Credit).
String? keyCreditOf(KeyProvider p) => p.creditText;

/// For the sync list.
List<KeyProvider> syncableProviders(ApiKeys k) => [for (final p in k.saved) if (p.canSync) p];

/// The data file's site of a road key, or null.
RoadSite? siteOf(ApiKeys k, KeyProvider p) => p.kind == KeyKind.road ? k.weather.roads?.file.sites.where((s) => s.keyAlias == p.id).firstOrNull : null;
