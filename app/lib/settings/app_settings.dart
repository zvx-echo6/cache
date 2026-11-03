import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_fs.dart';

/// Where connectors are published: the catalogue the app starts with (configurable in Advanced).
const String kDefaultCatalogueUrl = 'https://data.cached.info/connectors/catalogue.json';

/// The id of "Where I am" among the watched places: the place follows the phone.
const String kWatchHere = 'here';

/// The format of preferences.json's `weatherWatch` (1.0.29).
const int kWeatherWatchFormat = 1;

/// "10 PM", "6:30 AM": a time of day in minutes after midnight, as people say it.
String formatMinutes(int minutes) {
  final m = ((minutes % 1440) + 1440) % 1440;
  final h24 = m ~/ 60;
  final min = m % 60;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final suffix = h24 < 12 ? 'AM' : 'PM';
  return min == 0 ? '$h12 $suffix' : '$h12:${min.toString().padLeft(2, '0')} $suffix';
}

/// The hours when alerts arrive silently. [from] and [to] are minutes after midnight; a window may cross midnight
/// (10 PM to 6 AM). Equal times are an empty window.
@immutable
class QuietHours {
  const QuietHours({this.on = true, this.from = 22 * 60, this.to = 6 * 60});

  final bool on;
  final int from;
  final int to;

  QuietHours copyWith({bool? on, int? from, int? to}) => QuietHours(on: on ?? this.on, from: from ?? this.from, to: to ?? this.to);

  /// True when [t] (local time) falls inside the window and the window is switched on.
  bool contains(DateTime t) {
    if (!on || from == to) return false;
    final m = t.hour * 60 + t.minute;
    return from < to ? (m >= from && m < to) : (m >= from || m < to);
  }

  /// "10 PM to 6 AM".
  String get label => '${formatMinutes(from)} to ${formatMinutes(to)}';
}

/// Which alerts pop up: the one choice in Settings > Notifications. Every alert is listed in Weather either way.
enum PopUpFor {
  /// Evacuations, extreme and severe warnings, and fires near a place (the default).
  serious,

  /// Watches and advisories too.
  all,

  /// Nothing pops up.
  none;

  static PopUpFor byName(Object? n) => PopUpFor.values.firstWhere((v) => v.name == n, orElse: () => PopUpFor.serious);
}

/// What an alert should do when it arrives: the answer the alert notification code asks [AppSettings.deliveryFor].
enum AlertDelivery {
  /// It does not pop up.
  none,

  /// A notification with no sound or vibration (quiet hours).
  silent,

  /// A normal notification.
  normal,
}

/// The choices a person makes in Settings that the rest of the app reads: which alerts pop up, quiet hours, whether big downloads
/// may use mobile data, and the web search switch. Saved in preferences.json beside the app's other
/// settings and read back at start. (The key to a service is not here: keys live in secure storage.)
class AppSettings extends ChangeNotifier {
  AppSettings({this.settingsDirOverride});

  /// Test hook.
  final Directory? settingsDirOverride;

  PopUpFor _popUpFor = PopUpFor.serious;
  bool _toldNoPopUps = false;
  QuietHours _quiet = const QuietHours();
  bool _mobileForDownloads = false;
  bool _indexingNormal = false;
  bool _webSearchOn = false;
  Set<String> _liveOn = {};
  Set<String> _watched = {kWatchHere};
  Set<String>? _seenPlaces;
  Set<String> _defaultsSeen = {};
  String? _catalogueUrl;
  List<String> _extraCatalogues = [];
  AppFs? _fs;

  /// Which alerts near the person's places pop up.
  PopUpFor get popUpFor => _popUpFor;

  /// The one-time warning for "None" (Cache will not interrupt for evacuations) has been shown.
  bool get toldNoPopUps => _toldNoPopUps;

  /// When alerts that are not serious arrive silently. Serious ones still ring.
  QuietHours get quiet => _quiet;

  /// Weather, alerts and the other small updates always use any connection, mobile data too.
  bool get mobileForUpdates => true;

  /// Large downloads (maps, library, models, videos) may use mobile data. Off by default: they wait for Wi-Fi.
  bool get mobileForDownloads => _mobileForDownloads;

  /// Background indexing speed (Storage > Advanced): Gentle (false, the default) or Normal (true). The throttle eases either off
  /// for heat, a low battery and the person using Cache.
  bool get indexingNormal => _indexingNormal;

  /// The person's switch for searching the web. Only has an effect once a search service has a key.
  bool get webSearchOn => _webSearchOn;

  /// The live data sources that are switched on (weather, alerts, fires...), by source id. Nothing is downloaded for a source that
  /// is not here. A source and the built-in one it replaces (see liveReplaces in weather/catalogue.dart) are on or off together.
  Set<String> get liveSourcesOn => Set.unmodifiable(_liveOn);

  /// The places weather, alerts and fires are kept for: [kWatchHere] ("Where I am"), `place:<key>` (a saved place) or `region:<name>`
  /// (a downloaded region). "Where I am" is watched until the person unchecks it.
  Set<String> get watchedPlaces => Set.unmodifiable(_watched);

  /// Weather watch settings (1.0.29): "Where I am" and the downloaded regions belong to Weather and alerts, not to the Places
  /// notebook, which holds only the person's own places. Kept in preferences.json as `weatherWatch` ({format, here, regions,
  /// places}); `watchedPlaces` is still written beside it, so an older build reads the same choices.
  bool get watchHere => _watched.contains(kWatchHere);

  /// The downloaded regions watched, by region name.
  Set<String> get watchedRegions => {for (final id in _watched) if (id.startsWith('region:')) id.substring(7)};

  /// The saved places watched, by place key.
  Set<String> get watchedSavedPlaces => {for (final id in _watched) if (id.startsWith('place:')) id.substring(6)};

  void setWatchHere(bool on) => setWatched(kWatchHere, on);

  void setRegionWatched(String regionName, bool on) => setWatched('region:$regionName', on);

  /// The address of the connector catalogue the person set in Advanced, or null for the default ([kDefaultCatalogueUrl]).
  String? get catalogueUrl => _catalogueUrl;

  /// Catalogues the person added from a link, in the order added.
  List<String> get extraCatalogues => List.unmodifiable(_extraCatalogues);

  static const String _name = 'preferences.json';

  Future<void> init() async {
    final fs = createAppFs(supportOverride: settingsDirOverride);
    await fs.mkdir(AppRoot.support, '');
    _fs = fs;
    await _read();
    notifyListeners();
  }

  /// Keys this build does not know (written by a newer or an older build), kept and written back as they were, so moving between
  /// versions never drops a setting.
  Map<String, dynamic> _other = {};

  static const Set<String> _known = {
    'popUpFor', 'alertPopups', 'toldNoPopUps', 'quiet', 'mobileForDownloads', 'indexingSpeed', 'webSearchOn', 'liveSourcesOn', 'watchedPlaces',
    'weatherWatch', 'seenSavedPlaces', 'liveDefaultsSeen', 'catalogueUrl', 'extraCatalogues',
  };

  /// Each setting is read on its own: one that cannot be read keeps its default and the rest are still read (one bad value used
  /// to leave every setting after it at its default, and the next save wrote those defaults over the person's choices). A file
  /// that is not readable at all is kept beside it (preferences.json.unreadable) before anything is written over it.
  Future<void> _read() async {
    final fs = _fs!;
    final bytes = await fs.readBytes(AppRoot.support, _name);
    if (bytes == null) return;
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
    } catch (_) {
      try {
        await fs.copy(AppRoot.support, _name, '$_name.unreadable');
      } catch (_) {}
      return;
    }
    void each(void Function() read) {
      try {
        read();
      } catch (_) {}
    }

    // Before the one choice there was a pop-up switch: off reads as None.
    each(() => _popUpFor = j['popUpFor'] != null ? PopUpFor.byName(j['popUpFor']) : (j['alertPopups'] == false ? PopUpFor.none : PopUpFor.serious));
    each(() => _toldNoPopUps = j['toldNoPopUps'] == true);
    each(() {
      final q = j['quiet'];
      if (q is Map) {
        _quiet = QuietHours(
          on: q['on'] != false,
          from: ((q['from'] as num?)?.toInt() ?? 22 * 60).clamp(0, 1439),
          to: ((q['to'] as num?)?.toInt() ?? 6 * 60).clamp(0, 1439),
        );
      }
    });
    each(() => _mobileForDownloads = j['mobileForDownloads'] == true);
    each(() => _indexingNormal = j['indexingSpeed'] == 'normal');
    each(() => _webSearchOn = j['webSearchOn'] == true);
    each(() => _liveOn = _strings(j['liveSourcesOn']).toSet());
    each(() {
      final ww = j['weatherWatch'];
      if (ww is Map && ww['format'] == kWeatherWatchFormat) {
        _watched = {
          if (ww['here'] != false) kWatchHere,
          for (final r in _strings(ww['regions'])) 'region:$r',
          for (final k in _strings(ww['places'])) 'place:$k',
        };
      } else if (j['watchedPlaces'] is List) {
        // 1.0.28 and before: one list of ids, which the Places notebook showed. Read as it is (the choices are the person's).
        _watched = _strings(j['watchedPlaces']).toSet();
      }
    });
    each(() {
      if (j['seenSavedPlaces'] is List) _seenPlaces = _strings(j['seenSavedPlaces']).toSet();
    });
    each(() => _defaultsSeen = _strings(j['liveDefaultsSeen']).toSet());
    each(() {
      final u = j['catalogueUrl'];
      _catalogueUrl = u is String && u.trim().isNotEmpty ? u.trim() : null;
    });
    each(() => _extraCatalogues = _strings(j['extraCatalogues']));
    _other = {for (final e in j.entries) if (!_known.contains(e.key)) e.key: e.value};
  }

  static List<String> _strings(Object? v) => v is List ? [for (final e in v) if (e is String && e.isNotEmpty) e] : <String>[];

  void _save() {
    notifyListeners();
    try {
      final fs = _fs;
      if (fs == null) return;
      fs.writeStringAtomicSync(AppRoot.support, _name, jsonEncode({
        ..._other,
        'popUpFor': _popUpFor.name,
        if (_toldNoPopUps) 'toldNoPopUps': true,
        'quiet': {'on': _quiet.on, 'from': _quiet.from, 'to': _quiet.to},
        'mobileForDownloads': _mobileForDownloads,
        'indexingSpeed': _indexingNormal ? 'normal' : 'gentle',
        'webSearchOn': _webSearchOn,
        'liveSourcesOn': _liveOn.toList()..sort(),
        'watchedPlaces': _watched.toList()..sort(),
        'weatherWatch': {
          'format': kWeatherWatchFormat,
          'here': watchHere,
          'regions': watchedRegions.toList()..sort(),
          'places': watchedSavedPlaces.toList()..sort(),
        },
        if (_seenPlaces != null) 'seenSavedPlaces': _seenPlaces!.toList()..sort(),
        if (_defaultsSeen.isNotEmpty) 'liveDefaultsSeen': _defaultsSeen.toList()..sort(),
        'catalogueUrl': _catalogueUrl,
        'extraCatalogues': _extraCatalogues,
      }));
    } catch (_) {}
  }

  void setPopUpFor(PopUpFor v) {
    if (v == _popUpFor) return;
    _popUpFor = v;
    _save();
  }

  void setToldNoPopUps() {
    if (_toldNoPopUps) return;
    _toldNoPopUps = true;
    _save();
  }

  void setQuiet(QuietHours q) {
    if (q.on == _quiet.on && q.from == _quiet.from && q.to == _quiet.to) return;
    _quiet = q;
    _save();
  }

  void setMobileForDownloads(bool v) {
    if (v == _mobileForDownloads) return;
    _mobileForDownloads = v;
    _save();
  }

  void setIndexingNormal(bool v) {
    if (v == _indexingNormal) return;
    _indexingNormal = v;
    _save();
  }

  void setWebSearchOn(bool v) {
    if (v == _webSearchOn) return;
    _webSearchOn = v;
    _save();
  }

  /// Switches live data sources on or off, by id (all of [ids] at once).
  void setLiveSourcesOn(Iterable<String> ids, bool on) {
    final next = {..._liveOn};
    on ? next.addAll(ids) : next.removeAll(ids);
    if (next.length == _liveOn.length && next.containsAll(_liveOn)) return;
    _liveOn = next;
    _save();
  }

  /// The sources whose default ("on by default") has been applied once: after that only the person switches them.
  Set<String> get liveDefaultsSeen => Set.unmodifiable(_defaultsSeen);

  /// Notes that the defaults of [ids] were applied.
  void noteLiveDefaults(Iterable<String> ids) {
    final next = {..._defaultsSeen, ...ids};
    if (next.length == _defaultsSeen.length) return;
    _defaultsSeen = next;
    _save();
  }

  /// Watches or stops watching a place (see [watchedPlaces]).
  void setWatched(String placeId, bool on) {
    if (on == _watched.contains(placeId)) return;
    _watched = on ? {..._watched, placeId} : ({..._watched}..remove(placeId));
    _save();
  }

  /// Takes the saved places there are now (by watched-place id). One that was not there last time is new and is watched. The first
  /// time, the places there already are only remembered: places saved before this was kept stay as the person set them.
  void noteSavedPlaces(Iterable<String> ids) {
    final now = ids.toSet();
    final seen = _seenPlaces;
    if (seen != null && seen.length == now.length && seen.containsAll(now)) return;
    if (seen != null) _watched = {..._watched, ...now.difference(seen)};
    _seenPlaces = now;
    _save();
  }

  /// Forgets a watched place that no longer exists (a deleted saved place).
  void forgetWatched(Iterable<String> ids) {
    final next = {..._watched}..removeAll(ids);
    if (next.length == _watched.length) return;
    _watched = next;
    _save();
  }

  /// The catalogue address from Advanced; null or empty puts the default back.
  void setCatalogueUrl(String? url) {
    final v = url == null || url.trim().isEmpty ? null : url.trim();
    if (v == _catalogueUrl) return;
    _catalogueUrl = v;
    _save();
  }

  void addCatalogue(String url) {
    if (_extraCatalogues.contains(url)) return;
    _extraCatalogues = [..._extraCatalogues, url];
    _save();
  }

  void removeCatalogue(String url) {
    if (!_extraCatalogues.contains(url)) return;
    _extraCatalogues = [..._extraCatalogues]..remove(url);
    _save();
  }

  /// What the alert notification code does with an alert arriving at [now]. [serious] is an evacuation, an extreme or a severe
  /// warning. None: nothing pops up; Serious only: only serious ones do. Inside quiet hours the rest arrive silently; serious ones
  /// still ring.
  AlertDelivery deliveryFor({required bool serious, DateTime? now}) {
    if (_popUpFor == PopUpFor.none || (_popUpFor == PopUpFor.serious && !serious)) return AlertDelivery.none;
    if (!serious && _quiet.contains(now ?? DateTime.now())) return AlertDelivery.silent;
    return AlertDelivery.normal;
  }
}
