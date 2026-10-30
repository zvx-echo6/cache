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
import 'place_alerts.dart';
import 'places.dart';
import 'words.dart';

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

/// What the Weather and alerts card on Home shows (see [WeatherState.homeCard]).
class HomeWeather {
  const HomeWeather({
    this.message,
    this.place = '',
    this.temperature,
    this.conditions,
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
  final String place;

  /// "45 °F" and "clear sky", as the forecast source writes them.
  final String? temperature;
  final String? conditions;
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
    DateTime Function()? clock,
  }) : _fetch = fetch ?? fetchBytes,
       _now = clock ?? DateTime.now;

  final AppSettings settings;
  final DataPolicy policy;
  final LiveCore core;
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

  /// The address of the main catalogue (Advanced can change it).
  String get catalogueUrl => settings.catalogueUrl ?? kDefaultCatalogueUrl;

  /// The catalogues in use, the main one first, then the ones added from a link.
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
    for (final c in catalogues) {
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
      return const KeyCheck.failed("The key was accepted but couldn't be saved on this phone.");
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
      debugPrint('Built-in live sources: $e');
    }
    _catalogues = _store!.loadAll();
    _readStatus();
    _readShown();
    await _readKeys();
    _kind = await policy.probe.current();
    if (_kind != ConnectionKind.none) _lastOnlineAt = _now();
    settings.addListener(_onSettings);
    try {
      _sub = policy.probe.changes.listen(_onConnection);
    } catch (_) {}
    _started = true;
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
      debugPrint('Live sources folder: ${e.runtimeType}');
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
        debugPrint('Live key: ${e.runtimeType}');
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
      debugPrint('Live policy: ${e.runtimeType}');
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
          _catalogueErrors[url] = "Couldn't load the catalogue.";
        }
      }
    } finally {
      _refreshing = false;
    }
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

  /// Downloads a catalogue from [address] and checks every definition in it, without keeping anything. The person is shown what it
  /// adds, then [addCatalogue] keeps it. Throws [CatalogueException] with the reason in words.
  Future<LoadedCatalogue> previewCatalogue(String address) async {
    if (await policy.probe.current() == ConnectionKind.none) throw const NetworkProblem('No connection. Connect to add a catalogue.');
    final url = address.trim();
    if (catalogueUrls.contains(url)) throw const CatalogueException('That catalogue is already added.');
    final loaded = await _loader.load(url);
    if (loaded.definitions.isEmpty) {
      throw const CatalogueException('None of the sources in this catalogue can be used by this version of Cache.');
    }
    if (catalogues.any((c) => c.catalogue.id == loaded.catalogue.id)) {
      throw CatalogueException('A catalogue called "${loaded.catalogue.title}" is already added.');
    }
    return loaded;
  }

  /// Keeps a catalogue [previewCatalogue] returned.
  Future<void> addCatalogue(LoadedCatalogue loaded) async {
    _store!.save(loaded);
    settings.addCatalogue(loaded.url);
    _catalogues = _store!.loadAll();
    await _readKeys();
    await _applyAll();
  }

  /// Removes a catalogue added from a link: its sources go from the lists, and from the core.
  Future<void> removeCatalogue(String url) async {
    if (url == catalogueUrl) return;
    final gone = [for (final c in _catalogues.where((c) => c.url == url)) ...c.connectors.map((k) => k.id)];
    _store!.remove(url);
    settings.removeCatalogue(url);
    _catalogues = _store!.loadAll();
    settings.setLiveSourcesOn(gone.where((id) => sourceById(id) == null), false);
    await _readKeys();
    await _applyAll();
  }

  /// Sets the main catalogue's address (Advanced); null or empty puts the default back. The old copy is dropped and the new one fetched.
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

  /// Everything that can be watched: where the phone is, each saved place by name, and the downloaded regions.
  Future<List<WatchPlace>> placeChoices() async {
    final p = position?.call();
    final out = <WatchPlace>[
      WatchPlace(
        id: kWatchHere,
        kind: PlaceKind.here,
        name: 'Where I am',
        subtitle: p == null ? 'Follows the phone · position not known yet' : 'Follows the phone',
        lat: p?.lat,
        lon: p?.lon,
        key: p == null ? null : _hereKey(p.lat, p.lon),
      ),
    ];
    try {
      final saved = await core.savedPlaces();
      // A newly saved place is watched (see AppSettings.noteSavedPlaces).
      settings.noteSavedPlaces([for (final s in saved) 'place:${s.key}']);
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
    } catch (_) {}
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
  Future<List<WatchPlace>> watchedPlaces() async {
    final all = await placeChoices();
    final w = settings.watchedPlaces;
    return [for (final p in all) if (w.contains(p.id) && p.located) p];
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
    // The policy the core fetches under must be the one just checked (it is also what the assistant's fetch uses).
    await pushPolicy();
    var fetched = 0, fresh = 0;
    final failures = <String>[];
    try {
      for (final c in srcs) {
        for (final p in places) {
          try {
            final r = await core.fetch({'source': c.id, 'place': placeRequest(p), 'now': isoWithOffset(_now()), if (force) 'force': true});
            r['fetched'] == true ? fetched++ : fresh++;
          } on CacheSearchException catch (e) {
            debugPrint('Live update of ${c.id}: ${e.code}: ${e.message}');
            final who = c.provider.isEmpty ? c.title : c.provider;
            final line = '$who for ${p.name} failed: ${_fetchFailureWords(e)}';
            failures.add(line);
            _sourceErrors[c.id] = _fetchFailureWords(e);
          } catch (e) {
            debugPrint('Live update of ${c.id}: ${e.runtimeType}: $e');
            failures.add('${c.title} for ${p.name} failed');
            _sourceErrors[c.id] = "Couldn't update.";
          }
        }
      }
    } finally {
      _updating = false;
    }
    _lastRunAt = _now();
    if (fetched + fresh > 0) _lastOkAt = _lastRunAt;
    _lastFailure = failures.isEmpty ? null : failures.first;
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
    final out = <SourceView>[];
    var kept = false;
    for (final c in enabledSources) {
      try {
        final g = await core.get({'source': c.id, 'place': placeRequest(p), 'now': isoWithOffset(_now())});
        _shown['${c.id} ${p.id}'] = g;
        kept = true;
        out.add(_viewOf(c, p, g));
      } on CacheSearchException catch (e) {
        out.add(SourceView(source: c, place: p, missing: true, error: e.code == 'not_found' ? null : (_sourceErrors[c.id] ?? e.message)));
      } catch (_) {
        out.add(SourceView(source: c, place: p, missing: true, error: _sourceErrors[c.id]));
      }
    }
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
  Future<WatchPlace?> homePlace() async {
    final w = await watchedPlaces();
    if (w.isEmpty) return null;
    return w.firstWhere((p) => p.kind == PlaceKind.here, orElse: () => w.first);
  }

  /// Weather is not set up for anywhere yet: no forecast switched on, or no watched place with a position. Home then offers
  /// "Turn on weather".
  Future<bool> needsTurnOn() async {
    if (!enabledSources.any((c) => groupOf(c) == LiveGroup.forecast)) return true;
    return await homePlace() == null;
  }

  /// The Weather and alerts card on Home, for the place Home talks about ([homePlace]): the forecast now (temperature, conditions,
  /// the day's high and low), and the warnings in force and fires near it. Other watched places are on the Weather screen; so are
  /// earthquakes, rivers and the rest. Several fire sources describe the same fires (incidents and their perimeters), so the fires
  /// listed are those of the one fire source that reports the most.
  Future<HomeWeather> homeCard() async {
    final forecast = [for (final c in enabledSources) if (groupOf(c) == LiveGroup.forecast) c];
    final counted = [for (final c in enabledSources) if (c.category == 'alerts' || c.category == 'fire' || c.id == 'alerts') c];
    if (forecast.isEmpty && counted.isEmpty) return const HomeWeather(message: 'Not set up yet');
    final p = await homePlace();
    if (p == null) return HomeWeather(message: _noPlaceWords);
    final views = await viewFor(p);
    String? temperature, conditions, high, low, age;
    var forecastExpired = false;
    for (final v in views) {
      if (v.group != LiveGroup.forecast || v.items.isEmpty) continue;
      final now = v.items.firstWhere((i) => i.address.endsWith('/now'), orElse: () => v.items.first);
      final day = v.items.firstWhere((i) => !i.address.endsWith('/now'), orElse: () => now);
      temperature = now.fields['Temperature'];
      conditions = now.fields['Conditions'];
      // the names before "Daytime high" and "Low (early morning)" too, for a definition not updated yet
      high = day.fields['Daytime high'] ?? day.fields['High'];
      low = day.fields['Low (early morning)'] ?? day.fields['Low'];
      age = v.age;
      forecastExpired = v.expired;
      break;
    }
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
      high: high,
      low: low,
      age: age,
      expired: forecastExpired,
      forecastMissing: forecast.isNotEmpty && temperature == null && conditions == null,
      alerts: [...warnings, ...fires],
      alertsKnown: anyAlerts,
      alertsExpired: alertsExpired,
      checked: checked,
    );
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
    settings.removeListener(_onSettings);
    _sub?.cancel();
    super.dispose();
  }
}
