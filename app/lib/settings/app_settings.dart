import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
    } catch (_) {
      // A damaged file is ignored; the defaults apply.
    }
  }

  void _save() {
    notifyListeners();
    try {
      _file?.writeAsStringSync(jsonEncode({
        'alertPopups': _alertPopups,
        'quiet': {'on': _quiet.on, 'from': _quiet.from, 'to': _quiet.to},
        'ringThroughExtreme': _ringThroughExtreme,
        'mobileForUpdates': _mobileForUpdates,
        'mobileForDownloads': _mobileForDownloads,
        'webSearchOn': _webSearchOn,
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

  /// What the alert notification code does with an alert arriving at [now]. [extreme] is an evacuation order, a tornado or a flash flood
  /// warning. Pop-ups off: nothing. Inside quiet hours: silent, unless it is extreme and ringing through is on.
  AlertDelivery deliveryFor({required bool extreme, DateTime? now}) {
    if (!_alertPopups) return AlertDelivery.none;
    if (_quiet.contains(now ?? DateTime.now()) && !(extreme && _ringThroughExtreme)) return AlertDelivery.silent;
    return AlertDelivery.normal;
  }
}
