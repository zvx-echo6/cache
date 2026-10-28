import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../files.dart';

/// Where connectors are published: the catalogue the app starts with (configurable in Advanced).
const String kDefaultCatalogueUrl = 'https://cache.echo6.co/connectors/catalogue.json';

/// The id of "Where I am" among the watched places: the place follows the phone.
const String kWatchHere = 'here';

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

/// What an alert should do when it arrives: the answer the alert notification code asks [AppSettings.deliveryFor].
enum AlertDelivery {
  /// Alert pop-ups are off: no notification.
  none,

  /// A notification with no sound or vibration (quiet hours).
  silent,

  /// A normal notification.
  normal,
}

/// The choices a person makes in Settings that the rest of the app reads: alert pop-ups, quiet hours, ringing through for
/// extreme alerts, whether mobile data may be used, and the web search switch. Saved in preferences.json beside the app's other
/// settings and read back at start. (The key to a service is not here: keys live in secure storage.)
class AppSettings extends ChangeNotifier {
  AppSettings({this.settingsDirOverride});

  /// Test hook.
  final Directory? settingsDirOverride;

  bool _alertPopups = true;
  QuietHours _quiet = const QuietHours();
  bool _ringThroughExtreme = true;
  bool _mobileForUpdates = true;
  bool _mobileForDownloads = false;
  bool _webSearchOn = false;
  Set<String> _liveOn = {};
  Set<String> _watched = {kWatchHere};
  String? _catalogueUrl;
  List<String> _extraCatalogues = [];
  File? _file;

  /// Weather alerts and fires near the person's places show as pop-ups.
  bool get alertPopups => _alertPopups;

  /// When alerts arrive silently.
  QuietHours get quiet => _quiet;

  /// Evacuation orders, tornado and flash flood warnings make a sound even in quiet hours.
  bool get ringThroughExtreme => _ringThroughExtreme;

  /// Small, regular downloads (weather, alerts, fires, catalogues) may use mobile data. On by default.
  bool get mobileForUpdates => _mobileForUpdates;

  /// Large downloads (maps, library, videos) may use mobile data. Off by default.
  bool get mobileForDownloads => _mobileForDownloads;

  /// The person's switch for searching the web. Only has an effect once a search service has a key.
  bool get webSearchOn => _webSearchOn;

  /// The live data sources that are switched on (weather, alerts, fires...), by source id. Nothing is downloaded for a source that
  /// is not here. A source and the built-in one it replaces (see liveReplaces in weather/catalogue.dart) are on or off together.
  Set<String> get liveSourcesOn => Set.unmodifiable(_liveOn);

  /// The places weather, alerts and fires are kept for: [kWatchHere] ("Where I am"), `place:<key>` (a saved place) or `region:<name>`
  /// (a downloaded region). "Where I am" is watched until the person unchecks it.
  Set<String> get watchedPlaces => Set.unmodifiable(_watched);

  /// The address of the connector catalogue the person set in Advanced, or null for the default ([kDefaultCatalogueUrl]).
  String? get catalogueUrl => _catalogueUrl;

  /// Catalogues the person added from a link, in the order added.
  List<String> get extraCatalogues => List.unmodifiable(_extraCatalogues);

  Future<void> init() async {
    final dir = settingsDirOverride ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File('${dir.path}/preferences.json');
    _read();
    notifyListeners();
  }

  void _read() {
    try {
      final f = _file!;
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _alertPopups = j['alertPopups'] != false;
      final q = j['quiet'];
      if (q is Map) {
        _quiet = QuietHours(
          on: q['on'] != false,
          from: ((q['from'] as num?)?.toInt() ?? 22 * 60).clamp(0, 1439),
          to: ((q['to'] as num?)?.toInt() ?? 6 * 60).clamp(0, 1439),
        );
      }
      _ringThroughExtreme = j['ringThroughExtreme'] != false;
      _mobileForUpdates = j['mobileForUpdates'] != false;
      _mobileForDownloads = j['mobileForDownloads'] == true;
      _webSearchOn = j['webSearchOn'] == true;
      _liveOn = _strings(j['liveSourcesOn']).toSet();
      if (j['watchedPlaces'] is List) _watched = _strings(j['watchedPlaces']).toSet();
      final u = j['catalogueUrl'];
      _catalogueUrl = u is String && u.trim().isNotEmpty ? u.trim() : null;
      _extraCatalogues = _strings(j['extraCatalogues']);
    } catch (_) {
      // A damaged file is ignored; the defaults apply.
    }
  }

  static List<String> _strings(Object? v) => v is List ? [for (final e in v) if (e is String && e.isNotEmpty) e] : <String>[];

  void _save() {
    notifyListeners();
    try {
      final f = _file;
      if (f == null) return;
      writeStringAtomicSync(f, jsonEncode({
        'alertPopups': _alertPopups,
        'quiet': {'on': _quiet.on, 'from': _quiet.from, 'to': _quiet.to},
        'ringThroughExtreme': _ringThroughExtreme,
        'mobileForUpdates': _mobileForUpdates,
        'mobileForDownloads': _mobileForDownloads,
        'webSearchOn': _webSearchOn,
        'liveSourcesOn': _liveOn.toList()..sort(),
        'watchedPlaces': _watched.toList()..sort(),
        'catalogueUrl': _catalogueUrl,
        'extraCatalogues': _extraCatalogues,
      }));
    } catch (_) {}
  }

  void setAlertPopups(bool v) {
    if (v == _alertPopups) return;
    _alertPopups = v;
    _save();
  }

  void setQuiet(QuietHours q) {
    if (q.on == _quiet.on && q.from == _quiet.from && q.to == _quiet.to) return;
    _quiet = q;
    _save();
  }

  void setRingThroughExtreme(bool v) {
    if (v == _ringThroughExtreme) return;
    _ringThroughExtreme = v;
    _save();
  }

  void setMobileForUpdates(bool v) {
    if (v == _mobileForUpdates) return;
    _mobileForUpdates = v;
    _save();
  }

  void setMobileForDownloads(bool v) {
    if (v == _mobileForDownloads) return;
    _mobileForDownloads = v;
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

  /// Watches or stops watching a place (see [watchedPlaces]).
  void setWatched(String placeId, bool on) {
    if (on == _watched.contains(placeId)) return;
    _watched = on ? {..._watched, placeId} : ({..._watched}..remove(placeId));
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

  /// What the alert notification code does with an alert arriving at [now]. [extreme] is an evacuation order, a tornado or a flash flood
  /// warning. Pop-ups off: nothing. Inside quiet hours: silent, unless it is extreme and ringing through is on.
  AlertDelivery deliveryFor({required bool extreme, DateTime? now}) {
    if (!_alertPopups) return AlertDelivery.none;
    if (_quiet.contains(now ?? DateTime.now()) && !(extreme && _ringThroughExtreme)) return AlertDelivery.silent;
    return AlertDelivery.normal;
  }
}
