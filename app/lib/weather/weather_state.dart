import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../actions/setup_status.dart' show setupAge;
import '../chat/system_prompt.dart' show isoWithOffset;
import '../files.dart';
import '../settings/app_settings.dart';
import '../settings/data_policy.dart';
import '../settings/web_search_setup.dart' show KeyCheck;
import '../video/token_store.dart';
import 'catalogue.dart';
import 'catalogue_store.dart';
import 'connector.dart';
import 'curated.dart';
import 'live_core.dart';
import 'live_folder.dart';
import 'alert_notifier.dart';
import 'alert_watch.dart';
import 'live_view.dart';
import 'own_source.dart';
import 'place_alerts.dart';
import 'places.dart';
import 'words.dart';
import '../platform/app_log.dart';

/// Where the phone is, as far as weather is concerned.
typedef Position = ({double lat, double lon});

/// What the one status line at the top of Weather and alerts says.
class WeatherStatus {
  const WeatherStatus({required this.headline, required this.tone});

  /// The age, and the reason when the data is old: "Updated 1 hour ago", "Updated 3 days ago · No connection since Friday".
  final String headline;
  final StatusTone tone;
}

enum StatusTone { ok, warn, quiet }

/// Home's Weather and alerts card while the weather part is starting and sources are on (the same placeholder Home shows while it
/// reads the card).
const String kWeatherStarting = '…';

/// What the Weather and alerts card on Home shows (see [WeatherState.homeCard]).
class HomeWeather {
  const HomeWeather({
    this.message,
    this.off = false,
    this.place = '',
    this.temperature,
    this.conditions,
    this.period,
    this.high,
    this.low,
    this.age,
    this.expired = false,
    this.forecastMissing = false,
    this.alerts = const [],
    this.alertsKnown = false,
    this.alertsExpired = false,
    this.checked,
  });

  /// Words in place of the card's data: "Not set up yet", "Waiting for your position", "Choose a place to watch in Settings".
  final String? message;

  /// Weather was on and every source is off now: the card says "Weather is off" with Turn on (Settings > Weather and alerts).
  final bool off;
  final String place;

  /// "45 °F" and "clear sky", as the forecast source writes them.
  final String? temperature;
  final String? conditions;

  /// The label of the forecast period [conditions], [high] and [low] are for ("Wed Nov 11"), when they are not a reading taken
  /// now: the source's "Now" has ended and this is its forecast for the period that covers now. Home writes it before them, as
  /// the Weather screen lists a period under its label. Null for a reading.
  final String? period;
  final String? high;
  final String? low;

  /// "1 hour old".
  final String? age;

  /// The forecast is past its time and needs a connection.
  final bool expired;

  /// A forecast source is on but nothing is downloaded for the place yet.
  final bool forecastMissing;

  /// Warnings first, then fires.
  final List<HomeAlert> alerts;

  /// Something is known about alerts here (a source is on and has downloaded for the place).
  final bool alertsKnown;
  final bool alertsExpired;

  /// How old the alert data is ("20 minutes old").
  final String? checked;
}

/// One warning or fire on the Home card: its name and one line of detail.
class HomeAlert {
  const HomeAlert({required this.fire, required this.label, required this.detail});

  final bool fire;
  final String label;
  final String detail;
}

/// What one "Update now" did.
class UpdateReport {
  const UpdateReport({this.fetched = 0, this.upToDate = 0, this.failures = const [], this.offline = false, this.nothingToDo});

  /// Downloads that brought new data.
  final int fetched;

  /// Places and sources whose stored copy was still fresh.
  final int upToDate;

  /// "NWS for Home: HTTP 503" and so on, one per failed download.
  final List<String> failures;

  final bool offline;

  /// Why there was nothing to update ("Nothing is switched on", "No place is being watched").
  final String? nothingToDo;

  bool get ok => !offline && nothingToDo == null && failures.isEmpty;

  /// One sentence for the person.
  String get words {
    if (offline) return 'No connection. Update when you are online.';
    if (nothingToDo != null) return nothingToDo!;
    if (failures.isNotEmpty) return fetched + upToDate > 0 ? 'Updated, but ${failures.first}' : failures.first;
    return fetched > 0 ? 'Updated' : 'Already up to date';
  }
}

/// What is known about a source's stored data for the watched places.
class SourceInfo {
  const SourceInfo({this.age, this.fetchedAt, this.lastError, this.expired = false});

  final String? age;
  final String? fetchedAt;
  final String? lastError;
  final bool expired;
}

/// The Weather and alerts part of the app: which live data sources there are (built in and from catalogues), which are switched on,
/// their keys, the places to watch, and Update now. It tells the search core what it may fetch (the policy), gives it the keys (memory
/// only) and keeps the core's source folder holding the definitions of the sources that are on.
class WeatherState extends ChangeNotifier {
  WeatherState({
    required this.settings,
    required this.policy,
    required this.core,
    required this.secrets,
    required this.catalogueDir,
    required this.liveDir,
    required this.builtIns,
    this.position,
    this.regions,
    this.notifier,
    this.told,
    this.onPlacesChanged,
    FetchBytes? fetch,
    OwnFetch? ownFetch,
    this.ownTimeout = const Duration(seconds: 20),
    DateTime Function()? clock,
    this.hereSettle = const Duration(seconds: 45),
    this.hereGap = const Duration(minutes: 15),
  }) : _fetch = fetch ?? fetchBytes,
       _ownFetch = ownFetch ?? fetchOwnAddress,
       _now = clock ?? DateTime.now;

  final AppSettings settings;
  final DataPolicy policy;
  final LiveCore core;

  /// How long "Where I am" must stay at its key before its sources are fetched ([positionChanged]).
  final Duration hereSettle;

  /// The least time between two fetches for "Where I am" that [positionChanged] starts.
  final Duration hereGap;
  final TokenStore secrets;

  /// Called after a saved place is removed here (the assistant's list of places to watch is published again).
  final void Function()? onPlacesChanged;

  /// Where downloaded catalogues are kept.
  final Future<Directory> Function() catalogueDir;

  /// The core's source folder, or null when there is no core.
  final Future<Directory?> Function() liveDir;

  /// The text of each built-in definition.
  final Future<List<String>> Function() builtIns;
  final Position? Function()? position;
  final List<WatchRegion> Function()? regions;
  final FetchBytes _fetch;
  final OwnFetch _ownFetch;

  /// How long Try it waits for a source of your own to answer.
  final Duration ownTimeout;
  final DateTime Function() _now;

  /// Shows alert pop-ups; null where there are none (tests, or before the app sets it up).
  final AlertNotifier? notifier;

  /// What has been told about already, so a pop-up is never repeated; null with [notifier].
  final ToldStore? told;

  /// Each place's own alert rule (the Places notebook's gear); null = every place follows the alert setting.
  PlaceAlerts? placeAlerts;

  /// Set when an alert pop-up is tapped: the Weather screen shows that place and opens that item.
  final ValueNotifier<AlertFocus?> focus = ValueNotifier<AlertFocus?>(null);

  /// Where a key is kept in secure storage (by the name the definition gives it; several sources can share one).
  static String secretName(String alias) => 'live.key.$alias';

  CatalogueStore? _store;
  LiveFolder? _folder;
  List<Connector> _builtIn = [];
  List<LoadedCatalogue> _catalogues = [];
  final Set<String> _keys = {};
  Set<String> _registered = {};
  bool _started = false;
  bool _updating = false;
  bool _refreshing = false;
  final Map<String, String> _catalogueErrors = {};
  final Map<String, String> _sourceErrors = {};
  DateTime? _lastOkAt;
  DateTime? _lastRunAt;
  DateTime? _lastOnlineAt;
  String? _lastFailure;
  ConnectionKind _kind = ConnectionKind.wifi;
  StreamSubscription<ConnectionKind>? _sub;
  String _lastPolicy = '';

  bool get updating => _updating;
  bool get refreshingCatalogues => _refreshing;
  bool get started => _started;
  DateTime? get lastOkAt => _lastOkAt;
  ConnectionKind get connection => _kind;

  /// Why a catalogue (by address) could not be loaded last time, in words.
  Map<String, String> get catalogueErrors => Map.unmodifiable(_catalogueErrors);

  /// The last failure of each source in the last update, by source id.
  Map<String, String> get sourceErrors => Map.unmodifiable(_sourceErrors);

  /// The address of the main source list (Settings > Storage > Advanced > Source list address can change it).
  String get catalogueUrl => settings.catalogueUrl ?? kDefaultCatalogueUrl;

  /// The source lists in use: the main one, then links added by earlier versions that are not moved to "Your own" yet (see
  /// [_moveLinkedLists]).
  List<String> get catalogueUrls => [catalogueUrl, ...settings.extraCatalogues.where((u) => u != catalogueUrl)];

  List<LoadedCatalogue> get catalogues {
    final order = catalogueUrls;
    final out = [..._catalogues]..sort((a, b) => order.indexOf(a.url).compareTo(order.indexOf(b.url)));
    return [for (final c in out) if (order.contains(c.url)) c];
  }

  // ---------------------------------------------------------------- sources

  /// Every source that can be used, once: catalogue sources (the main catalogue first; a source id already provided is not offered
  /// again) and the built-in ones that no catalogue source replaces.
  List<Connector> get sources {
    final out = <Connector>[];
    final seen = <String>{};
    for (final c in [...catalogues, ?_own]) {
      for (final k in c.connectors) {
        if (seen.add(k.id)) out.add(k);
      }
    }
    final replaced = {for (final id in seen) if (liveReplaces[id] != null) liveReplaces[id]!};
    for (final b in _builtIn) {
      if (!replaced.contains(b.id) && seen.add(b.id)) out.add(b);
    }
    return out;
  }

  Connector? sourceById(String id) {
    for (final c in sources) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The ids that stand for [id]: itself and the built-in one it replaces (or the one that replaces it).
  Set<String> _same(String id) => {
    id,
    ?liveReplaces[id],
    for (final e in liveReplaces.entries) if (e.value == id) e.key,
  };

  bool isOn(String id) => _same(id).any(settings.liveSourcesOn.contains);

  /// The sources that are on and can be used.
  List<Connector> get enabledSources => [for (final c in sources) if (isOn(c.id)) c];

  /// The curated row's sources that exist (catalogue ids, or the built-in source that stands in).
  List<Connector> rowSources(CuratedRow r) => [for (final id in r.ids) ?sourceById(id) ?? _builtInFor(id)];

  Connector? _builtInFor(String id) {
    final b = liveReplaces[id];
    if (b == null) return null;
    for (final c in _builtIn) {
      if (c.id == b) return c;
    }
    return null;
  }

  bool rowIsOn(CuratedRow r) => rowSources(r).any((c) => isOn(c.id));

  /// A switch: all of the sources behind it.
  Future<void> setRowOn(CuratedRow r, bool on) => setSourcesOn(rowSources(r), on);

  Future<void> setSourcesOn(Iterable<Connector> list, bool on) async {
    final ids = <String>{for (final c in list) ..._same(c.id)};
    if (ids.isEmpty) return;
    settings.setLiveSourcesOn(ids, on);
    await _applyAll();
  }

  Future<void> setSourceOn(Connector c, bool on) => setSourcesOn([c], on);

  // ---------------------------------------------------------------- keys

  /// A key is saved for this name. (A key itself is never handed out.)
  bool hasKey(String alias) => _keys.contains(alias);

  /// The key names saved, sorted.
  List<String> get savedKeyAliases => _keys.toList()..sort();

  /// The sources that use the key [alias].
  List<Connector> sourcesUsingKey(String alias) => [for (final c in sources) if (c.keyAlias == alias) c];

  /// True when [c] can be fetched as far as its key goes.
  bool keyReady(Connector c) => !c.needsKey || hasKey(c.keyAlias!);

  /// Checks [raw] with one real download from the provider and, only if it is accepted, keeps it in secure storage, hands it to the
  /// core (memory only) and, when [switchOn], switches [forSource] on. A key that fails the check is not saved. The key is never
  /// shown again and is in no message.
  Future<KeyCheck> saveKey(Connector forSource, String raw, {bool switchOn = true}) async {
    final alias = forSource.keyAlias;
    if (alias == null) return const KeyCheck.failed('This source needs no key.');
    final key = raw.trim();
    if (key.isEmpty) return const KeyCheck.failed('Paste your key first.');
    final KeyCheck r = await _checkKey(forSource, key);
    if (!r.ok) return r;
    try {
      await secrets.write(secretName(alias), key);
    } catch (_) {
      return const KeyCheck.failed("The key was accepted but couldn't be saved on this device.");
    }
    _keys.add(alias);
    if (switchOn) settings.setLiveSourcesOn({..._same(forSource.id)}, true);
    notifyListeners();
    await _applyAll();
    return r;
  }

  Future<KeyCheck> _checkKey(Connector c, String key) async {
    final at = _probePlace();
    try {
      final r = await core.preview({
        'definition': c.def,
        'place': {'lat': at.lat, 'lon': at.lon, 'name': 'Key check'},
        'api_key': key,
        'now': isoWithOffset(_now()),
        'max_items': 1,
        'raw_chars': 400,
      });
      // A provider that answers a bad key with a page of its own comes back as a response the mapping cannot read.
      if (r['mapping_error'] != null) {
        return KeyCheck.failed("${_providerOf(c)} didn't accept this key, or answered with something Cache couldn't read. Check you copied all of it.");
      }
      return const KeyCheck.ok();
    } on CacheSearchException catch (e) {
      return KeyCheck.failed(_keyFailureWords(c, e));
    } catch (_) {
      return const KeyCheck.failed("Couldn't check the key. Try again.");
    }
  }

  String _providerOf(Connector c) => c.provider.isEmpty ? 'The service' : c.provider;

  String _keyFailureWords(Connector c, CacheSearchException e) {
    final who = _providerOf(c);
    if (e.code == 'key_missing') return "$who didn't accept this key. Check you copied all of it.";
    if (e.code == 'quota') return '$who says this key has reached its limit. Try again later.';
    final m = RegExp(r'HTTP (\d{3})').firstMatch(e.message);
    if (e.code == 'fetch_failed') {
      if (m == null) return "Couldn't reach $who. Check your connection.";
      final code = int.parse(m.group(1)!);
      if (code == 401 || code == 403) return "$who didn't accept this key. Check you copied all of it.";
      if (code >= 500) return '$who had a problem (HTTP $code). Try again in a moment.';
      return '$who answered with an error (HTTP $code).';
    }
    if (e.code == 'bad_response') return "$who answered with something Cache couldn't read. Try again later.";
    return "Couldn't check the key. Try again.";
  }

  /// Where the key check downloads: the phone's position, else the first watched place, else the middle of Idaho (a point the
  /// providers answer for; the key is being checked, not the place).
  ({double lat, double lon}) _probePlace() {
    final p = position?.call();
    if (p != null) return (lat: p.lat, lon: p.lon);
    return (lat: 44.07, lon: -114.74);
  }

  /// Forgets the key, forgets it in the core and switches off the sources that need it.
  Future<void> removeKey(String alias) async {
    try {
      await secrets.delete(secretName(alias));
    } catch (_) {}
    _keys.remove(alias);
    final users = sourcesUsingKey(alias);
    settings.setLiveSourcesOn({for (final c in users) ..._same(c.id)}, false);
    notifyListeners();
    await _applyAll();
  }

  // ---------------------------------------------------------------- start and the core's view

  /// Reads what is kept on the phone, tells the core what it may fetch and holds, and (when due) looks for catalogue updates.
  /// Called once the core has opened.
  Future<void> start() async {
    if (_started) return;
    _store = CatalogueStore(await catalogueDir());
    try {
      _builtIn = [for (final t in await builtIns()) Connector.parse(t)];
    } catch (e) {
      logError('Built-in live sources', error: e);
    }
    _catalogues = _store!.loadAll();
    _moveLinkedLists();
    _readStatus();
    _readShown();
    _readSaved();
    await _readKeys();
    _kind = await policy.probe.current();
    if (_kind != ConnectionKind.none) _lastOnlineAt = _now();
    settings.addListener(_onSettings);
    try {
      _sub = policy.probe.changes.listen(_onConnection);
    } catch (_) {}
    _started = true;
    // What is kept on the phone (the sources that are on, the last data shown, the saved places) shows from here, before the core
    // has answered anything: the rest of start waits for the core.
    notifyListeners();
    await _applyAll();
    notifyListeners();
    if (_catalogueDue) {
      _startupRefresh = refreshCatalogues();
      unawaited(_startupRefresh);
    }
  }

  Future<void>? _startupRefresh;

  /// The catalogue check [start] began in the background, if it began one (so tests can wait for it).
  @visibleForTesting
  Future<void>? get startupRefresh => _startupRefresh;

  bool get _catalogueDue {
    if (_kind == ConnectionKind.none) return false;
    final cats = catalogues;
    if (!catalogueUrls.every((u) => cats.any((c) => c.url == u))) return true;
    return cats.any((c) => _now().difference(c.fetchedAt) > const Duration(days: 1));
  }

  Future<void> _readKeys() async {
    _keys.clear();
    final aliases = <String>{for (final c in [..._builtIn, for (final k in _catalogues) ...k.connectors]) ?c.keyAlias};
    for (final a in aliases) {
      try {
        if ((await secrets.read(secretName(a)))?.isNotEmpty == true) _keys.add(a);
      } catch (_) {}
    }
  }

  void _onConnection(ConnectionKind k) {
    _kind = k;
    if (k != ConnectionKind.none) {
      _lastOnlineAt = _now();
      _saveStatus();
    }
    unawaited(pushPolicy());
    notifyListeners();
  }

  void _onSettings() {
    unawaited(pushPolicy());
    notifyListeners();
  }

  /// The alert sources a catalogue switches on by default for US places that no curated switch holds (FEMA IPAWS): they go with
  /// the "Weather alerts" switch (NWS, US).
  List<Connector> get _usAlertDefaults {
    final curated = {for (final r in kCurated) ...r.ids, ...liveReplaces.keys, ...liveReplaces.values};
    return [
      for (final c in sources)
        if (c.entry?.defaultOn == true && c.category == 'alerts' && c.coverage == 'US' && !c.needsKey && !curated.contains(c.id)) c,
    ];
  }

  bool get _weatherAlertsOn => rowIsOn(kCurated.firstWhere((r) => r.title == 'Weather alerts'));

  /// Switches on the US alert sources that go with "Weather alerts" (FEMA IPAWS): the first time a catalogue offers one, where
  /// "Weather alerts" is on, and always with [force] (Turn on weather). After that it is the person's switch.
  Future<void> applyAlertDefaults({bool force = false}) async {
    final news = [for (final c in _usAlertDefaults) if (force || !settings.liveDefaultsSeen.contains(c.id)) c];
    if (news.isEmpty) return;
    settings.noteLiveDefaults([for (final c in news) c.id]);
    if (force || _weatherAlertsOn) await setSourcesOn(news, true);
  }

  /// Syncs everything the core holds from what is on: the definitions folder, the keys and the fetch policy.
  Future<void> _applyAll() async {
    if (!_started && _store == null) return;
    // a US alert source new in the catalogue goes with "Weather alerts" once (FEMA IPAWS for someone who has NWS alerts on)
    final defaults = [for (final c in _usAlertDefaults) if (!settings.liveDefaultsSeen.contains(c.id)) c];
    if (defaults.isNotEmpty) {
      settings.noteLiveDefaults([for (final c in defaults) c.id]);
      if (_weatherAlertsOn) settings.setLiveSourcesOn({for (final c in defaults) c.id}, true);
    }
    await _syncFolder();
    await pushKeys();
    await pushPolicy();
    notifyListeners();
  }

  Future<void> _syncFolder() async {
    try {
      final dir = await liveDir();
      if (dir == null) return;
      _folder ??= LiveFolder(dir);
      _folder!.apply(
        {for (final c in enabledSources) c.id: c.defText},
        formerly: [for (final c in _builtIn) c.id],
      );
      final listed = await core.sources();
      _registered = {for (final s in (listed['sources'] as List? ?? const [])) (s as Map)['id'] as String};
    } catch (e) {
      logError('Live sources folder', error: e);
    }
  }

  /// The core's source folder once it is known (Storage counts it).
  Directory? get liveFolder => _folder?.dir;

  /// The sources the core has registered (the ones that are on).
  Set<String> get registeredIds => Set.unmodifiable(_registered);

  /// cs_live_set_key for every source that takes a key: the saved key, or nothing.
  Future<void> pushKeys() async {
    for (final c in sources) {
      final alias = c.keyAlias;
      if (alias == null) continue;
      String? key;
      if (_keys.contains(alias)) {
        try {
          key = await secrets.read(secretName(alias));
        } catch (_) {}
      }
      try {
        await core.setKey(c.id, key);
      } catch (e) {
        logError('Live key', error: e);
        return;
      }
    }
  }

  /// cs_live_set_fetch_policy: online, metered, mobile data allowed (updates always use any connection), and the sources that are on.
  Future<void> pushPolicy() async {
    final k = await policy.probe.current();
    _kind = k;
    final body = <String, dynamic>{
      'online': k != ConnectionKind.none,
      'allow_metered': true,
      'metered': k == ConnectionKind.mobile,
      'enabled_sources': ([for (final c in enabledSources) c.id]..sort()),
    };
    final text = jsonEncode(body);
    if (text == _lastPolicy) return;
    try {
      await core.setFetchPolicy(body);
      _lastPolicy = text;
    } catch (e) {
      logError('Live policy', error: e);
    }
  }

  // ---------------------------------------------------------------- catalogues

  /// Downloads every catalogue in use again and replaces what is kept; the sources on are re-registered. A catalogue that cannot be
  /// reached keeps what it had, with the reason in [catalogueErrors].
  Future<void> refreshCatalogues() async {
    if (_refreshing || _store == null) return;
    _refreshing = true;
    _catalogueErrors.clear();
    notifyListeners();
    try {
      for (final url in catalogueUrls) {
        try {
          if (await policy.probe.current() == ConnectionKind.none) throw const NetworkProblem('No connection.');
          final loaded = await _loader.load(url);
          _store!.save(loaded);
          _catalogues = _store!.loadAll();
        } on CatalogueException catch (e) {
          _catalogueErrors[url] = e.message;
        } catch (e) {
          _catalogueErrors[url] = "Couldn't load the list of sources.";
        }
      }
    } finally {
      _refreshing = false;
    }
    _moveLinkedLists();
    await _readKeys();
    await _applyAll();
  }

  CatalogueLoader get _loader => CatalogueLoader(fetch: _fetch, check: _checkDefinition, now: _now);

  Future<void> _checkDefinition(String text) async {
    try {
      await core.check(text);
    } on CacheSearchException catch (e) {
      throw CatalogueException(_firstLines(e.message));
    }
  }

  static String _firstLines(String m) {
    final s = m.trim();
    return s.length > 240 ? '${s.substring(0, 240)}…' : s;
  }

  // ---------------------------------------------------------------- your own sources

  /// What the "Your own" collection is kept under in the store (it is kept like a downloaded list, in the same format, and is never
  /// downloaded again).
  static const String ownListUrl = 'cache:own';

  /// The id and title of the collection; its sources' [Origin].
  static const String ownListId = 'own';
  static const String ownListTitle = 'Your own';

  LoadedCatalogue? get _own => _catalogues.where((c) => c.url == ownListUrl).firstOrNull;

  /// The sources of your own: made with Add your own source, imported from a source file, or moved from a link an earlier version
  /// added. They behave like every other source.
  List<Connector> get ownSources => _own?.connectors ?? const [];

  bool isOwn(Connector c) => c.origin.catalogueId == ownListId;

  /// The sources of your own as a linked device takes them (Settings > Sharing and sync > a device > Settings): each source's
  /// entry and definition, sorted by id. Their keys are not here (see API keys there).
  List<Map<String, dynamic>> get ownSourcesJson {
    final own = _own;
    if (own == null) return const [];
    final entries = [...own.catalogue.entries]..sort((a, b) => a.id.compareTo(b.id));
    return [
      for (final e in entries)
        if (own.definitions[e.id] != null) {'entry': catalogueEntryJson(e), 'definition': own.definitions[e.id]},
    ];
  }

  /// The sources of your own exactly as a linked device has them ([ownSourcesJson]); each definition is checked by the core as
  /// any other, and one that fails is left out. Applied at once.
  Future<void> replaceOwnSources(Object? list) async {
    if (_store == null) return;
    final entries = <CatalogueEntry>[];
    final defs = <String, String>{};
    for (final x in (list is List ? list : const [])) {
      if (x is! Map || x['entry'] is! Map || x['definition'] is! String) continue;
      try {
        final e = _ownEntry(CatalogueEntry.fromJson((x['entry'] as Map).cast<String, dynamic>()));
        Connector.parse(x['definition'] as String);
        if (defs.containsKey(e.id)) continue;
        entries.add(e);
        defs[e.id] = x['definition'] as String;
      } catch (_) {}
    }
    _saveOwn(entries, defs);
    await _readKeys();
    await _applyAll();
    notifyListeners();
  }

  /// The live sources switched on changed from outside this page (a linked device's settings): the core is told at once.
  Future<void> sourcesChanged() async {
    await _applyAll();
    notifyListeners();
  }

  /// Keeps a key a linked device sent, under [alias], and uses it at once.
  Future<void> keepKey(String alias, String key) async {
    await secrets.write(secretName(alias), key);
    await _readKeys();
    _keys.add(alias);
    await _applyAll();
    notifyListeners();
  }

  /// Replaces the collection with [entries] and their [defs].
  void _saveOwn(List<CatalogueEntry> entries, Map<String, String> defs) {
    final cat = Catalogue(
      id: ownListId,
      title: ownListTitle,
      maintainer: '',
      homepage: '',
      baseUrl: Uri.parse('https://localhost/own/'),
      updated: '',
      entries: entries,
    );
    _store!.save(LoadedCatalogue(url: ownListUrl, catalogue: cat, definitions: {for (final e in entries) e.id: defs[e.id]!}, skipped: const {}, at: _now()));
    _catalogues = _store!.loadAll();
  }

  /// [e] as an entry of the collection: listed under "Your own" (not featured, not switched on by default), its definition beside it.
  static CatalogueEntry _ownEntry(CatalogueEntry e) => CatalogueEntry(
    id: e.id,
    title: e.title,
    description: e.description,
    category: e.category,
    provider: e.provider,
    coverage: e.coverage,
    needsKey: e.needsKey,
    keyAlias: e.keyAlias,
    defaultOn: false,
    featured: false,
    path: 'defs/${e.id}.json',
    attribution: e.attribution,
    license: e.license,
    docs: e.docs,
    sha256: null,
  );

  /// An entry for a definition that came without one (one source file, or the form): its words from the definition.
  static CatalogueEntry _entryOf(Connector c) => _ownEntry(CatalogueEntry(
    id: c.id,
    title: c.title,
    description: c.description,
    category: 'other',
    provider: c.provider,
    coverage: '',
    needsKey: c.needsKey,
    keyAlias: c.keyAlias,
    defaultOn: false,
    path: '',
    attribution: c.attribution,
    license: '',
    docs: null,
    sha256: null,
  ));

  /// Ids a new source of your own may not take: every source there is but the ones of [except].
  Set<String> _takenIds({Iterable<String> except = const []}) => {
    for (final c in sources) c.id,
    for (final c in _builtIn) c.id,
    ...liveReplaces.keys,
  }..removeAll(except);

  /// Links an earlier version added under "Add sources from a link" become part of "Your own": every source the kept copy holds is
  /// moved (its switch and its key stay, the ids are the same), and the link is dropped. A link not downloaded yet stays until a
  /// refresh brings its copy. A source the main list also has is the main list's. True when something moved.
  bool _moveLinkedLists() {
    final store = _store;
    if (store == null) return false;
    final links = [for (final u in settings.extraCatalogues) if (u != catalogueUrl) u];
    if (links.isEmpty) return false;
    final own = _own;
    final entries = [...?own?.catalogue.entries];
    final defs = {...?own?.definitions};
    final main = _catalogues.where((c) => c.url == catalogueUrl).firstOrNull;
    final taken = <String>{
      for (final e in entries) e.id,
      for (final e in main?.catalogue.entries ?? const <CatalogueEntry>[]) e.id,
      for (final c in _builtIn) c.id,
      ...liveReplaces.keys,
    };
    var moved = false;
    for (final url in links) {
      final kept = _catalogues.where((c) => c.url == url).firstOrNull;
      if (kept == null) continue;
      for (final e in kept.catalogue.entries) {
        final text = kept.definitions[e.id];
        if (text == null || !taken.add(e.id)) continue;
        entries.add(_ownEntry(e));
        defs[e.id] = text;
      }
      store.remove(url);
      settings.removeCatalogue(url);
      _catalogueErrors.remove(url);
      moved = true;
    }
    if (!moved) return false;
    _saveOwn(entries, defs);
    return true;
  }

  /// Where Try it asks for: the first watched place, else where the phone is, else the middle of Idaho.
  Future<({double lat, double lon})> _tryPlace() async {
    try {
      final w = await watchedPlaces();
      if (w.isNotEmpty) return (lat: w.first.lat!, lon: w.first.lon!);
    } catch (_) {}
    return _probePlace();
  }

  /// Try it: fetches the address of [d] once, for the first watched place, with the key typed (or, editing, the one kept), and
  /// gives the values found. Nothing is kept.
  Future<OwnTry> tryOwnSource(OwnDraft d) async {
    final host = ownHost(d.keptAddress);
    if (await policy.probe.current() == ConnectionKind.none) return OwnTry.failed(host, OwnTryFailure.offline);
    final at = await _tryPlace();
    var key = d.key.trim();
    if (key.isEmpty && d.needsKey && d.id != null) {
      try {
        key = await secrets.read(secretName(d.id!)) ?? '';
      } catch (_) {}
    }
    final url = Uri.tryParse(fillAddress(d.keptAddress, lat: at.lat, lon: at.lon, key: key));
    if (url == null || !isAllowedAddress(url)) return OwnTry.failed(host, OwnTryFailure.notAllowed);
    return tryOwnAddress(url, fetch: _ownFetch, timeout: ownTimeout);
  }

  /// Saves the source [d] makes with the values [picks] (a new one, or the one being edited, [OwnDraft.id]): its definition is
  /// checked by the core as every published definition is, the key goes to secure storage only, and the source is switched on.
  /// Gives the reason in words when it cannot be saved, else null.
  Future<String?> saveOwnSource(OwnDraft d, List<OwnPick> picks, {({String lat, String lon})? point}) async {
    if (_store == null) return 'Weather and alerts is still starting. Try again in a moment.';
    if (picks.isEmpty) return 'Tick at least one value to show.';
    final id = d.id ?? ownIdFor(d.name, _takenIds());
    final text = buildOwnDefinition(id: id, draft: d, picks: picks, point: point);
    try {
      await _checkDefinition(text);
    } on CatalogueException catch (e) {
      return "Cache can't use this source: ${e.message}";
    }
    final key = d.key.trim();
    try {
      if (d.needsKey && key.isNotEmpty) await secrets.write(secretName(id), key);
      if (!d.needsKey) await secrets.delete(secretName(id));
    } catch (_) {
      return "The key couldn't be saved on this device.";
    }
    final c = Connector.parse(text);
    final own = _own;
    final entries = [for (final e in own?.catalogue.entries ?? const <CatalogueEntry>[]) if (e.id != id) e, _entryOf(c)];
    final defs = {...?own?.definitions, id: text};
    _saveOwn(entries, defs);
    settings.setLiveSourcesOn({id}, true);
    await _readKeys();
    await _applyAll();
    return null;
  }

  /// Removes a source of your own: it is switched off and taken off this device, with its key when no other source uses it.
  Future<void> removeOwnSource(String id) async {
    final own = _own;
    if (own == null || !own.catalogue.entries.any((e) => e.id == id)) return;
    final alias = sourceById(id)?.keyAlias;
    settings.setLiveSourcesOn(_same(id), false);
    _saveOwn([for (final e in own.catalogue.entries) if (e.id != id) e], own.definitions);
    if (alias != null && sourcesUsingKey(alias).isEmpty) {
      try {
        await secrets.delete(secretName(alias));
      } catch (_) {}
      _keys.remove(alias);
    }
    await _applyAll();
  }

  /// Reads a source file ([text], or the file at [link]): one source definition, or a list of sources in the published list format
  /// (its definitions are downloaded from the address it gives). Every source is checked by the core, as the published ones are;
  /// one that fails, or that is here already, is left out with the reason. Nothing is kept: [addImported] keeps it. Throws
  /// [CatalogueException] with the reason in words.
  Future<LoadedCatalogue> previewImport({String? text, String? link}) async {
    var body = text;
    final from = link?.trim() ?? 'file';
    if (body == null) {
      final u = Uri.tryParse(from);
      if (u == null || !isAllowedAddress(u)) throw const CatalogueException('Enter an address that starts with https://');
      if (await policy.probe.current() == ConnectionKind.none) throw const NetworkProblem('No connection. Connect to read the link.');
      body = utf8.decode(await _fetch(u), allowMalformed: true);
    }
    final Object? j;
    try {
      j = jsonDecode(body.replaceFirst('\u{feff}', ''));
    } on FormatException {
      throw const CatalogueException("This isn't a source file. Cache reads source files written in JSON.");
    }
    if (j is! Map<String, dynamic>) throw const CatalogueException("This isn't a source file.");
    final LoadedCatalogue read;
    if (j.containsKey('connectors')) {
      if (await policy.probe.current() == ConnectionKind.none) throw const NetworkProblem('No connection. Connect to read the sources in the list.');
      read = await _loader.loadText(body, from);
    } else if (j.containsKey('items') || j.containsKey('request')) {
      final c = Connector.parse(body);
      try {
        await _checkDefinition(body);
      } on CatalogueException catch (e) {
        throw CatalogueException("Cache can't use this source: ${e.message}");
      }
      final e = _entryOf(c);
      read = LoadedCatalogue(
        url: from,
        catalogue: Catalogue(id: ownListId, title: c.title, maintainer: c.provider, homepage: '', baseUrl: Uri.parse('https://localhost/own/'), updated: '', entries: [e]),
        definitions: {c.id: body},
        skipped: const {},
        at: _now(),
      );
    } else {
      throw const CatalogueException("This isn't a source file: it is neither a source nor a list of sources.");
    }
    final taken = _takenIds();
    final defs = <String, String>{};
    final skipped = {...read.skipped};
    for (final e in read.catalogue.entries) {
      final t = read.definitions[e.id];
      if (t == null) continue;
      if (!isValidSourceId(e.id)) {
        skipped[e.id] = 'Its id must be lower-case letters, digits, - and _, at most 64.';
      } else if (taken.contains(e.id)) {
        skipped[e.id] = 'You have this source already.';
      } else {
        defs[e.id] = t;
      }
    }
    if (defs.isEmpty) {
      throw CatalogueException(skipped.isEmpty ? 'There is no source in it that Cache can add.' : 'None of its sources can be added. ${skipped.values.first}');
    }
    return LoadedCatalogue(url: read.url, catalogue: read.catalogue, definitions: defs, skipped: skipped, at: read.fetchedAt);
  }

  /// Keeps the sources [previewImport] read, in "Your own". They stay off until switched on.
  Future<void> addImported(LoadedCatalogue p) async {
    if (_store == null) return;
    final own = _own;
    final entries = [...?own?.catalogue.entries];
    final defs = {...?own?.definitions};
    final have = {for (final e in entries) e.id};
    for (final e in p.catalogue.entries) {
      final t = p.definitions[e.id];
      if (t == null || !have.add(e.id)) continue;
      entries.add(_ownEntry(e));
      defs[e.id] = t;
    }
    _saveOwn(entries, defs);
    await _readKeys();
    await _applyAll();
  }

  /// Sets the main source list's address (Settings > Storage > Advanced); null or empty puts the default back. The old copy is
  /// dropped and the new one fetched.
  Future<void> setCatalogueUrl(String? address) async {
    final old = catalogueUrl;
    settings.setCatalogueUrl(address);
    if (catalogueUrl == old) return;
    _store?.remove(old);
    _catalogues = _store?.loadAll() ?? [];
    await _applyAll();
    await refreshCatalogues();
  }

  // ---------------------------------------------------------------- places

  /// The weather watch settings' own places (1.0.29: they left the Places notebook): "Where I am" and each downloaded region,
  /// each with its switch. Saved places are switched from the Places notebook. The screen that lists these drops in later.
  Future<List<({WatchPlace place, bool on})>> watchAreas() async => [
    for (final p in await placeChoices())
      if (p.kind != PlaceKind.saved) (place: p, on: settings.watchedPlaces.contains(p.id)),
  ];

  /// Everything that can be watched: where the phone is, each saved place by name, and the downloaded regions. The saved places are
  /// the core's; when it cannot answer, the ones it last gave.
  Future<List<WatchPlace>> placeChoices() async {
    List<SavedPlaceRecord> saved;
    try {
      saved = await core.savedPlaces();
      // A newly saved place is watched (see AppSettings.noteSavedPlaces).
      settings.noteSavedPlaces([for (final s in saved) 'place:${s.key}']);
      _keepSaved(saved);
    } catch (_) {
      saved = _savedKept ?? const [];
    }
    return _choices(saved);
  }

  /// [placeChoices] at once, without the core: the saved places it last gave (kept in a file). At start the core can be busy for
  /// seconds; the Weather screen and Home show "Where I am" and the kept places meanwhile.
  List<WatchPlace> placeChoicesNow() => _choices(_savedKept ?? const []);

  /// [watchedPlaces] at once, without the core (see [placeChoicesNow]).
  List<WatchPlace> watchedPlacesNow() => _watched(placeChoicesNow());

  List<WatchPlace> _choices(List<SavedPlaceRecord> saved) {
    final p = position?.call();
    final out = <WatchPlace>[
      WatchPlace(
        id: kWatchHere,
        kind: PlaceKind.here,
        name: 'Where I am',
        subtitle: p == null ? 'Follows this device · position not known yet' : 'Follows this device',
        lat: p?.lat,
        lon: p?.lon,
        key: p == null ? null : _hereKey(p.lat, p.lon),
      ),
    ];
    for (final s in saved) {
      out.add(WatchPlace(
        id: 'place:${s.key}',
        kind: PlaceKind.saved,
        name: s.name,
        subtitle: (s.label != null && s.label!.isNotEmpty) ? s.label! : '${s.lat.toStringAsFixed(2)}, ${s.lon.toStringAsFixed(2)}',
        lat: s.lat,
        lon: s.lon,
        key: s.key,
      ));
    }
    for (final r in regions?.call() ?? const <WatchRegion>[]) {
      out.add(WatchPlace(
        id: 'region:${r.name}',
        kind: PlaceKind.region,
        name: r.name,
        subtitle: 'Downloaded region',
        lat: r.lat,
        lon: r.lon,
        key: 'region-${_slug(r.name)}',
        area: r.area,
      ));
    }
    return out;
  }

  String? _hereSeen;

  /// The phone's position changed (the app calls this from the location service). The position is read when asked for, so
  /// without this Home and the place lists kept "Where I am" as "not known yet" after the first fix arrived, until something
  /// else changed. Listeners hear when "Where I am" gains, loses or moves its position (its key).
  void positionChanged() {
    final p = position?.call();
    final key = p == null ? null : _hereKey(p.lat, p.lon);
    if (key == _hereSeen) return;
    _hereSeen = key;
    notifyListeners();
    if (key != null) _scheduleHereFetch(hereSettle);
  }

  Timer? _hereTimer;
  DateTime? _hereFetchedAt;

  /// "Where I am" moved to a place nothing was downloaded for, so Home said "no forecast yet" until the next scheduled update
  /// (build 48). Once the key has settled ([hereSettle], restarted by each move) its sources are fetched for that place alone, at
  /// most once per [hereGap]. Like every update it uses any connection (mobile data too) and none while offline; the core's own
  /// refresh intervals and quotas still apply, so a fresh copy is not downloaded again.
  void _scheduleHereFetch(Duration after) {
    _hereTimer?.cancel();
    if (_disposed || !_started) return;
    _hereTimer = Timer(after, () async {
      final last = _hereFetchedAt;
      if (last != null && _now().difference(last) < hereGap) {
        _scheduleHereFetch(hereGap - _now().difference(last));
        return;
      }
      await _fetchHere();
    });
  }

  Future<void> _fetchHere() async {
    if (_disposed || _updating) return;
    final srcs = [for (final c in enabledSources) if (keyReady(c)) c];
    final here = [for (final p in await watchedPlaces()) if (p.kind == PlaceKind.here) p];
    if (srcs.isEmpty || here.isEmpty) return;
    if (await policy.probe.current() == ConnectionKind.none) return;
    _hereFetchedAt = _now();
    await _syncFolder();
    await pushPolicy();
    await Future.wait([
      for (final c in srcs)
        () async {
          try {
            await core.fetch({'source': c.id, 'place': placeRequest(here.first), 'now': isoWithOffset(_now())});
          } catch (e) {
            logInfo('Live update for where I am, ${c.id}: failed');
          }
        }(),
    ]);
    notifyListeners();
    await checkAlerts();
  }

  /// "Where I am" is ticked and its position is not known yet: the place is waiting, not missing.
  bool get waitingForPosition => settings.watchedPlaces.contains(kWatchHere) && position?.call() == null;

  /// What Home says while it has no place to talk about.
  String get _noPlaceWords => waitingForPosition ? 'Waiting for your position' : 'Choose a place to watch in Settings';

  /// The key for "where the phone is": the position rounded to 0.01 degrees, which the core's live_data tool also looks for.
  static String _hereKey(double lat, double lon) => 'at:${lat.toStringAsFixed(2)},${lon.toStringAsFixed(2)}';

  static String _slug(String s) {
    final t = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return t.isEmpty ? 'region' : t;
  }

  /// The place object the core takes for a download. A region carries its whole area, which alert sources that match by area
  /// (FEMA IPAWS) match against; a point source (NWS by point) still uses the middle.
  static Map<String, dynamic> placeRequest(WatchPlace p) => {
    'key': p.key,
    'name': p.kind == PlaceKind.here ? 'current location' : p.name,
    'lat': p.lat,
    'lon': p.lon,
    if (p.area != null) 'area': p.area,
  };

  /// Removes a saved place: the core forgets it and it is no longer watched. Only saved places can be removed.
  Future<void> removePlace(WatchPlace p) async {
    final key = p.key;
    if (p.kind != PlaceKind.saved || key == null) return;
    await core.deleteSavedPlace(key);
    settings.forgetWatched([p.id]);
    notifyListeners();
    onPlacesChanged?.call();
  }

  /// The watched places that can be fetched for now (a place without a position, like "Where I am" before the first fix, waits).
  Future<List<WatchPlace>> watchedPlaces() async => _watched(await placeChoices());

  List<WatchPlace> _watched(List<WatchPlace> all) {
    final w = settings.watchedPlaces;
    return [for (final p in all) if (w.contains(p.id) && p.located) p];
  }

  /// The saved places the core last gave, also kept in a file (read at start, before the core opens).
  List<SavedPlaceRecord>? _savedKept;

  File? get _savedFile {
    final d = _store?.root;
    return d == null ? null : File('${d.path}/saved-places.json');
  }

  static Map<String, dynamic> _savedJson(SavedPlaceRecord s) => {'key': s.key, 'name': s.name, 'lat': s.lat, 'lon': s.lon, 'label': ?s.label};

  void _readSaved() {
    try {
      final f = _savedFile;
      if (f == null || !f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync());
      if (j is! List) return;
      _savedKept ??= [for (final e in j) if (e is Map) SavedPlaceRecord.fromJson(e.cast<String, dynamic>())];
    } catch (_) {}
  }

  void _keepSaved(List<SavedPlaceRecord> saved) {
    final text = jsonEncode([for (final s in saved) _savedJson(s)]);
    final before = _savedKept == null ? null : jsonEncode([for (final s in _savedKept!) _savedJson(s)]);
    _savedKept = saved;
    if (text == before) return;
    try {
      final f = _savedFile;
      if (f == null) return;
      f.parent.createSync(recursive: true);
      writeStringAtomicSync(f, text);
    } catch (_) {}
  }

  /// The watched places by name, one per line ("Where I am", "Home", "Cabin", "+2 more"): a name can hold a comma, as
  /// coordinates do.
  Future<String> watchedSummary() async {
    final all = await placeChoices();
    final w = settings.watchedPlaces;
    final names = [for (final p in all) if (w.contains(p.id)) p.name];
    if (names.isEmpty) return 'None';
    if (names.length <= 3) return names.join('\n');
    return [...names.take(3), '+${names.length - 3} more'].join('\n');
  }

  // ---------------------------------------------------------------- Update now

  /// Fetches every source that is on, for every watched place, through the core: the same fetch the assistant uses, with the core's
  /// own refresh intervals and quotas, so a copy that is still fresh is not downloaded again. Updates use any connection, mobile data
  /// too. [force] is a person's refresh: every source is downloaded again even when its copy is younger than its refresh interval (a
  /// forecast is kept for 3 hours), still within the core's quotas.
  Future<UpdateReport> updateNow({bool force = false}) async {
    if (_updating) return const UpdateReport(nothingToDo: 'Already updating');
    final srcs = [for (final c in enabledSources) if (keyReady(c)) c];
    if (srcs.isEmpty) return const UpdateReport(nothingToDo: 'Switch on a source to update it.');
    final places = await watchedPlaces();
    if (places.isEmpty) {
      return UpdateReport(nothingToDo: waitingForPosition ? 'Waiting for your position.' : 'No place is being watched. Choose one under Places.');
    }
    _kind = await policy.probe.current();
    if (_kind == ConnectionKind.none) {
      notifyListeners();
      return const UpdateReport(offline: true);
    }
    _lastOnlineAt = _now();
    _updating = true;
    _sourceErrors.clear();
    notifyListeners();
    // The core reads its definitions from the folder: write it from what is on now, whichever way a source was switched on (a
    // switch, Turn on weather, a catalogue's default), so no source that is on is missing there ("no live source").
    await _syncFolder();
    // The policy the core fetches under must be the one just checked (it is also what the assistant's fetch uses).
    await pushPolicy();
    var fetched = 0, fresh = 0;
    // Every source for every place at once: each download runs on a thread of the core's own (cs_live_fetch_start), so none waits
    // for another's network and the core's worker stays free for searches and the stored data meanwhile. Failures are listed in
    // the order of the sources and places, as before.
    final all = Stopwatch()..start();
    Future<(bool, String?)> one(Connector c, WatchPlace p) async {
      final took = Stopwatch()..start();
      try {
        final r = await core.fetch({'source': c.id, 'place': placeRequest(p), 'now': isoWithOffset(_now()), if (force) 'force': true});
        final got = r['fetched'] == true;
        logInfo('Live update ${c.id}: ${took.elapsedMilliseconds} ms, ${got ? 'downloaded' : 'still fresh'}');
        return (got, null);
      } on CacheSearchException catch (e) {
        logInfo('Live update ${c.id}: ${took.elapsedMilliseconds} ms, failed (${e.code})');
        logError('Live update failed (${e.code})', error: e.message, detail: c.id);
        final who = c.provider.isEmpty ? c.title : c.provider;
        _sourceErrors[c.id] = _fetchFailureWords(e);
        return (false, '$who for ${p.name} failed: ${_fetchFailureWords(e)}');
      } catch (e) {
        logInfo('Live update ${c.id}: ${took.elapsedMilliseconds} ms, failed');
        logError('Live update failed', error: e, detail: c.id);
        _sourceErrors[c.id] = "Couldn't update.";
        return (false, '${c.title} for ${p.name} failed');
      }
    }

    final List<(bool, String?)> outcomes;
    try {
      outcomes = await Future.wait([for (final c in srcs) for (final p in places) one(c, p)]);
    } finally {
      _updating = false;
    }
    final failures = <String>[];
    for (final (got, failure) in outcomes) {
      if (failure != null) {
        failures.add(failure);
      } else {
        got ? fetched++ : fresh++;
      }
    }
    logInfo('Live update: ${outcomes.length} fetches at once in ${all.elapsedMilliseconds} ms ($fetched downloaded, $fresh still fresh, ${failures.length} failed)');
    _lastRunAt = _now();
    if (fetched + fresh > 0) _lastOkAt = _lastRunAt;
    // Every source that failed, not only the first.
    _lastFailure = failures.isEmpty ? null : (failures.length == 1 ? failures.single : '${failures.length} updates failed: ${failures.join('; ')}');
    _saveStatus();
    notifyListeners();
    // Every update checks, fresh copies included: an alert that arrived through the assistant or before pop-ups existed is still
    // news; what was told before is never repeated.
    await checkAlerts();
    return UpdateReport(fetched: fetched, upToDate: fresh, failures: failures);
  }

  /// When the app starts or comes back to the screen: the scheduled background run may not have come (iOS decides when, and
  /// may not run it for hours), so an update that is due ([every] since the last run) runs now. What a background run wrote is
  /// read first, so its time shows and it is not repeated. The core's refresh intervals still apply (no forced download).
  Future<UpdateReport?> updateIfDue(Duration every) async {
    if (!_started || _updating || enabledSources.isEmpty) return null;
    _readStatus();
    notifyListeners();
    final last = _lastRunAt;
    if (last != null && _now().difference(last) < every) return null;
    return updateNow();
  }

  String _fetchFailureWords(CacheSearchException e) => switch (e.code) {
    'quota' => 'reached its limit for now',
    'key_missing' => 'needs a key',
    'bad_response' => 'sent something Cache could not read',
    'fetch_failed' => _httpWords(e.message),
    _ => "couldn't update",
  };

  String _httpWords(String m) {
    final h = RegExp(r'HTTP (\d{3})').firstMatch(m);
    if (h != null) return 'the service answered HTTP ${h.group(1)}';
    return "couldn't be reached";
  }

  // ---------------------------------------------------------------- the status line

  /// The age of the data, and why when it is old (see [WeatherStatus]).
  WeatherStatus status() {
    final on = enabledSources;
    if (on.isEmpty) return const WeatherStatus(headline: 'Nothing switched on yet', tone: StatusTone.quiet);
    final now = _now();
    final reason = _kind == ConnectionKind.none ? 'No connection since ${dayWords(_lastOnlineAt ?? now, now)}' : null;
    final ok = _lastOkAt;
    if (ok == null) return WeatherStatus(headline: reason == null ? 'Not updated yet' : 'Not updated yet · $reason', tone: StatusTone.warn);
    final age = now.difference(ok);
    final stale = age.inMinutes > on.map((c) => c.refreshMinutes).reduce((a, b) => a < b ? a : b);
    final failed = _lastFailure != null && _lastRunAt != null && !_lastRunAt!.isBefore(ok);
    final head = 'Updated ${agoWords(age)}';
    if (!stale && !failed && reason == null) return WeatherStatus(headline: head, tone: StatusTone.ok);
    final why = reason ?? (failed ? _lastFailure! : null);
    return WeatherStatus(headline: why == null ? head : '$head · $why', tone: StatusTone.warn);
  }

  /// "3 on · Updated 12 min ago": the line under the Weather and alerts row of Settings.
  String settingsLine() {
    final on = enabledSources.length;
    final head = on == 0 ? 'Nothing on' : '$on on';
    final ok = _lastOkAt;
    if (on == 0 || ok == null) return head;
    final now = _now();
    final age = now.difference(ok);
    return '$head · Updated ${agoWords(age)}';
  }

  // ---------------------------------------------------------------- a source's details

  /// What the core holds for [c] across the watched places: the newest copy's age, and the last error, if any.
  Future<SourceInfo> infoFor(Connector c) async {
    String? age, at, err;
    int? bestSeconds;
    var expired = false;
    for (final p in await watchedPlaces()) {
      try {
        final g = await core.get({'source': c.id, 'place': placeRequest(p), 'now': isoWithOffset(_now())});
        final secs = (g['age_seconds'] as num?)?.toInt() ?? 0;
        if (bestSeconds == null || secs < bestSeconds) {
          bestSeconds = secs;
          age = g['age'] as String?;
          at = g['fetched_at'] as String?;
          expired = g['expired'] == true;
        }
        final le = g['last_error'];
        if (le is Map && err == null) err = '${le['message']}';
      } on CacheSearchException catch (e) {
        if (e.code != 'not_found' && e.code != 'not_configured' && err == null) err = e.message;
      } catch (_) {}
    }
    err ??= _sourceErrors[c.id];
    return SourceInfo(age: age, fetchedAt: at, lastError: err, expired: expired);
  }

  // ---------------------------------------------------------------- what the Weather screen and Home show

  /// What every switched-on source holds for [p], as stored (expired data is included and flagged). Read from the core, so it
  /// is exactly what the assistant would get.
  Future<List<SourceView>> viewFor(WatchPlace p) async {
    var kept = false;
    // asked all at once (the core answers them one after another, without a round trip between)
    final out = await Future.wait([
      for (final c in enabledSources)
        () async {
          try {
            final g = await core.get({'source': c.id, 'place': placeRequest(p), 'now': isoWithOffset(_now())});
            // An answer with no items (a fetch that failed, a place not downloaded yet) must not wipe the last good one kept for
            // Home at start (a source with nothing to say gives a "none active" item, never an empty list).
            final key = '${c.id} ${p.id}';
            final had = (_shown[key]?['items'] as List?)?.isNotEmpty ?? false;
            if (!had || (g['items'] as List?)?.isNotEmpty == true) {
              _shown[key] = g;
              kept = true;
            }
            return _viewOf(c, p, g);
          } on CacheSearchException catch (e) {
            return SourceView(source: c, place: p, missing: true, error: e.code == 'not_found' ? null : (_sourceErrors[c.id] ?? e.message));
          } catch (_) {
            return SourceView(source: c, place: p, missing: true, error: _sourceErrors[c.id]);
          }
        }(),
    ]);
    if (kept) _saveShown();
    return out;
  }

  SourceView _viewOf(Connector c, WatchPlace p, Map<String, dynamic> g, {bool kept = false}) {
    final le = g['last_error'];
    final fetched = DateTime.tryParse('${g['fetched_at']}');
    return SourceView(
      source: c,
      place: p,
      items: [for (final i in (g['items'] as List? ?? const [])) if (i is Map) LiveItem.fromJson(i.cast<String, dynamic>())],
      // A kept answer's age is worked out again: it is older now than when the core said it.
      age: kept && fetched != null ? setupAge(_now().difference(fetched)) : g['age'] as String?,
      fetchedAt: g['fetched_at'] as String?,
      expired: g['expired'] == true,
      error: le is Map ? '${le['message']}' : _sourceErrors[c.id],
    );
  }

  /// The last answer the core gave for each source and place, also kept in a file: the core answers one call at a time, and while
  /// it downloads (a weather update, map sizes, a library) the Weather screen waited minutes for what is already on the phone.
  final Map<String, Map<String, dynamic>> _shown = {};

  /// What [viewFor] last gave for [p], at once and without the core, with each copy's age as of now; null when nothing is kept.
  List<SourceView>? keptViewFor(WatchPlace p) {
    final out = [
      for (final c in enabledSources)
        if (_shown['${c.id} ${p.id}'] case final g?) _viewOf(c, p, g, kept: true),
    ];
    return out.isEmpty ? null : out;
  }

  File? get _shownFile {
    final d = _store?.root;
    return d == null ? null : File('${d.path}/last-shown.json');
  }

  void _readShown() {
    try {
      final f = _shownFile;
      if (f == null || !f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return;
      for (final e in j.entries) {
        if (e.value is Map) _shown.putIfAbsent(e.key as String, () => (e.value as Map).cast<String, dynamic>());
      }
    } catch (_) {}
  }

  void _saveShown() {
    try {
      final f = _shownFile;
      if (f == null) return;
      f.parent.createSync(recursive: true);
      writeStringAtomicSync(f, jsonEncode(_shown));
    } catch (_) {}
  }

  /// Pops up what is new near the watched places (warnings and fires; see [pickNewAlerts]) as the person's "Pop up for" says, silent in
  /// quiet hours unless it is serious. Everything checked is remembered as told, shown or not, so choosing more pop-ups later does not
  /// bring back old alerts. Returns how many were shown.
  Future<int> checkAlerts() async {
    final n = notifier, t = told;
    if (n == null || t == null) return 0;
    final byPlace = <WatchPlace, List<SourceView>>{};
    for (final p in await watchedPlaces()) {
      byPlace[p] = await viewFor(p);
    }
    await placeAlerts?.load();
    final fresh = pickNewAlerts(byPlace, await t.read(), rules: placeAlerts?.ruleFor, toldAlerts: await t.readAlerts());
    if (fresh.isEmpty) return 0;
    var shown = 0;
    for (final a in fresh) {
      if (await n.show(a, deliveryOf(a, settings, _now()))) shown++;
    }
    await t.add([for (final a in fresh) ...a.allAddresses], alerts: [for (final a in fresh) ...a.told]);
    return shown;
  }

  /// How [a] is shown. A place's Custom rule overrides "Pop up for": what it picked pops up (silent in quiet hours unless it
  /// is serious). Otherwise "Pop up for" and quiet hours decide; a place set to Off picked nothing.
  static AlertDelivery deliveryOf(NewAlert a, AppSettings settings, DateTime now) {
    if (!a.custom) return settings.deliveryFor(serious: a.serious, now: now);
    return !a.serious && settings.quiet.contains(now) ? AlertDelivery.silent : AlertDelivery.normal;
  }

  /// The place Home talks about: "Where I am" when it is watched and known, else the first watched place.
  Future<WatchPlace?> homePlace() async => _homeOf(await watchedPlaces());

  /// [homePlace] at once, without the core (see [placeChoicesNow]).
  WatchPlace? homePlaceNow() => _homeOf(watchedPlacesNow());

  static WatchPlace? _homeOf(List<WatchPlace> w) {
    if (w.isEmpty) return null;
    return w.firstWhere((p) => p.kind == PlaceKind.here, orElse: () => w.first);
  }

  /// Weather is not set up for anywhere yet: no forecast switched on, or no watched place with a position. Home then offers
  /// "Turn on weather".
  Future<bool> needsTurnOn() async {
    // Before the weather part has started (it waits for the search core, which can take minutes on the first start after an
    // update) no source is listed yet: what is switched on is read from the settings instead.
    if (!_started) return settings.liveSourcesOn.isEmpty;
    if (!enabledSources.any((c) => groupOf(c) == LiveGroup.forecast)) return true;
    return await homePlace() == null;
  }

  /// The Weather and alerts card on Home, for the place Home talks about ([homePlace]): the forecast now (temperature, conditions,
  /// the day's high and low), and the warnings in force and fires near it. Other watched places are on the Weather screen; so are
  /// earthquakes, rivers and the rest. Several fire sources describe the same fires (incidents and their perimeters), so the fires
  /// listed are those of the one fire source that reports the most.
  Future<HomeWeather> homeCard() async {
    final early = _homeEarly();
    if (early != null) return early;
    final p = await homePlace();
    if (p == null) return HomeWeather(message: _noPlaceWords);
    return _homeFrom(p, await viewFor(p));
  }

  /// [homeCard] at once, without the core: what was last shown for the place Home talks about, with its age as of now; null while
  /// nothing is kept for it (Home then waits for [homeCard]). At start the core can be busy for seconds (build 46: 13-20 s
  /// before the card filled).
  HomeWeather? homeCardNow() {
    final early = _homeEarly();
    if (early != null) return early;
    final p = homePlaceNow();
    final kept = p == null ? null : keptViewFor(p);
    if (p == null || kept == null) return null;
    return _homeFrom(p, kept);
  }

  /// What the card says before it is about a place: getting ready, off, or not set up.
  HomeWeather? _homeEarly() {
    // Not started yet: sources that are on are not listed until the catalogues are read at start. Saying "Not set up yet" then
    // read as weather switched off by the update (1.0.28 feedback); it is still getting ready.
    if (!_started) return HomeWeather(message: settings.liveSourcesOn.isEmpty ? 'Not set up yet' : kWeatherStarting);
    final forecast = [for (final c in enabledSources) if (groupOf(c) == LiveGroup.forecast) c];
    final counted = [for (final c in enabledSources) if (c.category == 'alerts' || c.category == 'fire' || c.id == 'alerts') c];
    // Every source switched off after weather was on (its defaults were applied once): "Weather is off", not "Not set up yet".
    if (enabledSources.isEmpty && settings.liveDefaultsSeen.isNotEmpty) return const HomeWeather(message: 'Weather is off', off: true);
    if (forecast.isEmpty && counted.isEmpty) return const HomeWeather(message: 'Not set up yet');
    return null;
  }

  HomeWeather _homeFrom(WatchPlace p, List<SourceView> views) {
    final forecast = [for (final c in enabledSources) if (groupOf(c) == LiveGroup.forecast) c];
    final counted = [for (final c in enabledSources) if (c.category == 'alerts' || c.category == 'fire' || c.id == 'alerts') c];
    String? temperature, conditions, high, low, age;
    var forecastExpired = false;
    // Each forecast source gives its best "now": a forecast's own /now item first, else (a weather station list, as NWS current
    // conditions) the nearest station that reports a temperature, else its first item. A source that lists no temperature (a
    // station with only wind and pressure) must not hide the one after it, so every source is scanned and temperature and
    // conditions each come from the best source that has them. Forecast /now items rank before station lists.
    // A first item that reports no temperature is not known to be a reading: a forecast whose "Now" has ended lists only its
    // periods (tonight, the days), so its conditions are never taken as the conditions now. It still gives the source's age.
    final nows = <(LiveItem, SourceView)>[];
    final stations = <(LiveItem, SourceView)>[];
    final notReadings = <LiveItem>{};
    for (final v in views) {
      if (v.group != LiveGroup.forecast || v.items.isEmpty) continue;
      final own = [for (final i in v.items) if (i.address.endsWith('/now')) i];
      if (own.isNotEmpty) {
        nows.add((own.first, v));
        continue;
      }
      LiveItem? pick;
      double? best;
      for (final i in v.items) {
        if (i.fields['Temperature'] == null) continue;
        final d = distanceMiles(i);
        if (pick == null || (d != null && (best == null || d < best))) {
          pick = i;
          best = d;
        }
      }
      if (pick == null) notReadings.add(v.items.first);
      stations.add((pick ?? v.items.first, v));
    }
    final ranked = [...nows, ...stations];
    for (final (i, v) in ranked) {
      if (temperature == null && i.fields['Temperature'] != null) {
        temperature = i.fields['Temperature'];
        age = v.age;
        forecastExpired = v.expired;
      }
      if (!notReadings.contains(i)) conditions ??= i.fields['Conditions'];
    }
    // No reading: "Now" has ended (a forecast's own lasts 3 hours, and the next download can be hours away) or was never
    // given, and no station reports. The forecast period that covers now stands in, under its own label and with its source's
    // age, as the Weather screen lists it. It is a forecast, not a reading, so no temperature stands in for the one that ended.
    String? period;
    if (temperature == null && conditions == null) {
      for (final v in views) {
        if (v.group != LiveGroup.forecast) continue;
        final i = _periodNow(v);
        if (i == null) continue;
        period = i.label;
        conditions = i.fields['Conditions'];
        // the high and low of that same period, never another day's under its label
        high = i.fields['Daytime high'] ?? i.fields['High'];
        low = i.fields['Low (early morning)'] ?? i.fields['Low'];
        age = v.age;
        forecastExpired = v.expired;
        break;
      }
    }
    // the day's high and low from the first source that has them; the names before "Daytime high" and "Low (early morning)" too,
    // for a definition not updated yet
    for (final v in views) {
      if (period != null) break;
      if (v.group != LiveGroup.forecast) continue;
      for (final i in v.items) {
        if (i.address.endsWith('/now')) continue;
        final h = i.fields['Daytime high'] ?? i.fields['High'];
        final l = i.fields['Low (early morning)'] ?? i.fields['Low'];
        if (h == null && l == null) continue;
        high = h;
        low = l;
        break;
      }
      if (high != null || low != null) break;
    }
    age ??= [for (final (_, v) in ranked) v.age].firstOrNull;
    if (period == null) forecastExpired = temperature == null && ranked.isNotEmpty ? ranked.first.$2.expired : forecastExpired;
    final warnings = <HomeAlert>[];
    // one line per alert: NWS and FEMA IPAWS often carry the same one (see sameAlert)
    final listed = <(LiveItem, String)>[];
    var fires = <HomeAlert>[];
    var anyAlerts = false, alertsExpired = false;
    String? checked;
    for (final v in views) {
      if (!counted.any((c) => c.id == v.source.id) || v.missing) continue;
      anyAlerts = true;
      alertsExpired = alertsExpired || v.expired;
      checked ??= v.age;
      final who = v.source.provider;
      final fire = v.source.category == 'fire';
      final items = [
        for (final i in v.active)
          if (fire || !listed.any((l) => sameAlert(l.$1, p, true, i, p, true, sourceA: l.$2, sourceB: v.source.id)))
          HomeAlert(
            fire: v.source.category == 'fire',
            label: i.label,
            detail: [?i.distance, if (i.summary.isNotEmpty) i.summary, if (who.isNotEmpty) who].join(' · '),
          ),
      ];
      if (fire) {
        if (items.length > fires.length) fires = items;
      } else {
        warnings.addAll(items);
        listed.addAll([for (final i in v.active) (i, v.source.id)]);
      }
    }
    return HomeWeather(
      place: p.name,
      temperature: temperature,
      conditions: conditions,
      period: period,
      high: high,
      low: low,
      age: age,
      expired: forecastExpired,
      // "no forecast yet" only when there is nothing to show: never beside a high and low
      forecastMissing: forecast.isNotEmpty && temperature == null && conditions == null && high == null && low == null,
      alerts: [...warnings, ...fires],
      alertsKnown: anyAlerts,
      alertsExpired: alertsExpired,
      checked: checked,
    );
  }

  /// The forecast period of [v] that covers now, for Home when there is no reading: of the items that give "Conditions" (not
  /// the "Now" item), the one that started last. A day ("2026-11-11") covers that date at the place and no other, so a day that
  /// has passed is never shown as today; a period with a start time covers from then on (the core leaves out the periods that
  /// have ended, and an item carries no end to check here). Null when no item is known to cover now.
  LiveItem? _periodNow(SourceView v) {
    final now = _now();
    // the place's clock: the offset the core writes this source's times in, else the device's
    final stamp = RegExp(r'([+-])(\d\d):(\d\d)$').firstMatch(v.fetchedAt?.trim() ?? '');
    final offset = stamp == null
        ? now.timeZoneOffset.inMinutes
        : (stamp.group(1) == '-' ? -1 : 1) * (int.parse(stamp.group(2)!) * 60 + int.parse(stamp.group(3)!));
    final there = now.toUtc().add(Duration(minutes: offset));
    LiveItem? pick;
    DateTime? best;
    for (final i in v.items) {
      if (i.address.endsWith('/now') || i.fields['Conditions'] == null) continue;
      final t = i.time?.trim();
      if (t == null) continue;
      final DateTime from;
      final day = RegExp(r'^(\d{4})-(\d\d)-(\d\d)$').firstMatch(t);
      if (day != null) {
        final y = int.parse(day.group(1)!), m = int.parse(day.group(2)!), d = int.parse(day.group(3)!);
        if (y != there.year || m != there.month || d != there.day) continue;
        from = DateTime.utc(y, m, d).subtract(Duration(minutes: offset));
      } else {
        final at = DateTime.tryParse(t);
        if (at == null || at.isAfter(now)) continue;
        from = at.toUtc();
      }
      if (best == null || from.isAfter(best)) {
        pick = i;
        best = from;
      }
    }
    return pick;
  }

  // ---------------------------------------------------------------- what is remembered between starts

  File? get _statusFile {
    final d = _store?.root;
    return d == null ? null : File('${d.path}/status.json');
  }

  void _readStatus() {
    try {
      final f = _statusFile;
      if (f == null || !f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      DateTime? t(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
      _lastOkAt = t(j['ok']);
      _lastRunAt = t(j['run']);
      _lastOnlineAt = t(j['online']);
      _lastFailure = j['failure'] as String?;
    } catch (_) {}
  }

  void _saveStatus() {
    try {
      final f = _statusFile;
      if (f == null) return;
      f.parent.createSync(recursive: true);
      writeStringAtomicSync(f, jsonEncode({
        'ok': _lastOkAt?.millisecondsSinceEpoch,
        'run': _lastRunAt?.millisecondsSinceEpoch,
        'online': _lastOnlineAt?.millisecondsSinceEpoch,
        'failure': _lastFailure,
      }));
    } catch (_) {}
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _hereTimer?.cancel();
    settings.removeListener(_onSettings);
    _sub?.cancel();
    super.dispose();
  }
}
