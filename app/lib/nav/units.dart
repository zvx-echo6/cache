import 'dart:ui' show Locale;

/// Miles and feet, or kilometres and metres.
enum UnitSystem { imperial, metric }

/// The countries that drive in miles (United States, United Kingdom, Liberia, Myanmar); everyone else gets metric. This is
/// the phone's own region, so there is no setting for it.
UnitSystem unitsForLocale(Locale locale) {
  const imperial = {'US', 'GB', 'LR', 'MM'};
  return imperial.contains(locale.countryCode) ? UnitSystem.imperial : UnitSystem.metric;
}

const double _ftPerM = 3.28084;
const double _mPerMile = 1609.344;

/// Distances, times and heights in plain words, for the screen and for speech.
class Fmt {
  const Fmt(this.units);

  final UnitSystem units;

  bool get _us => units == UnitSystem.imperial;

  /// "300 ft", "0.5 mi", "12 mi", "350 m", "1.2 km".
  String distance(double m) {
    if (_us) {
      final ft = m * _ftPerM;
      final mi = m / _mPerMile;
      if (ft < 528) return '${_round(ft, ft < 100 ? 10 : 50)} ft';
      if (mi < 10) return '${mi.toStringAsFixed(1)} mi';
      return '${mi.round()} mi';
    }
    if (m < 1000) return '${_round(m, m < 100 ? 10 : 50)} m';
    final km = m / 1000;
    return km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
  }

  /// A height or climb: "120 ft", "40 m".
  String height(num m) => _us ? '${(m * _ftPerM).round()} ft' : '${m.round()} m';

  /// "5 min", "1 h 25 min", "2 d 3 h".
  String duration(int seconds) {
    final mins = (seconds / 60).round();
    if (mins < 1) return '1 min';
    if (mins < 60) return '$mins min';
    final h = mins ~/ 60, m = mins % 60;
    if (h < 24) return m == 0 ? '$h h' : '$h h $m min';
    final d = h ~/ 24;
    return h % 24 == 0 ? '$d d' : '$d d ${h % 24} h';
  }

  /// A distance as a person says it: "half a mile", "300 feet", "2 miles", "500 meters".
  String spoken(double m) {
    if (_us) {
      final mi = m / _mPerMile;
      final ft = m * _ftPerM;
      if (mi >= 0.95) {
        final r = mi >= 9.5 ? mi.round().toDouble() : (mi * 2).round() / 2;
        final text = r == r.roundToDouble() ? r.round().toString() : r.toStringAsFixed(1);
        return r == 1 ? '1 mile' : '$text miles';
      }
      if (mi >= 0.65) return 'three quarters of a mile';
      if (mi >= 0.35) return 'half a mile';
      if (mi >= 0.2) return 'a quarter mile';
      final r = ft < 150 ? _round(ft, 50) : (ft < 1000 ? _round(ft, 100) : _round(ft, 500));
      return '${r < 50 ? 50 : r} feet';
    }
    if (m >= 950) {
      final km = m / 1000;
      final r = km >= 9.5 ? km.round().toDouble() : (km * 2).round() / 2;
      final text = r == r.roundToDouble() ? r.round().toString() : r.toStringAsFixed(1);
      return r == 1 ? '1 kilometer' : '$text kilometers';
    }
    final r = m < 150 ? _round(m, 50) : _round(m, 100);
    return '${r < 50 ? 50 : r} meters';
  }

  /// A duration as a person says it: "5 minutes", "1 hour 25 minutes".
  String spokenDuration(int seconds) {
    final mins = (seconds / 60).round();
    if (mins < 1) return 'less than a minute';
    String unit(int n, String w) => '$n $w${n == 1 ? '' : 's'}';
    if (mins < 60) return unit(mins, 'minute');
    final h = mins ~/ 60, m = mins % 60;
    return m == 0 ? unit(h, 'hour') : '${unit(h, 'hour')} ${unit(m, 'minute')}';
  }

  /// A height as a person says it: "120 feet", "40 meters".
  String spokenHeight(num m) => _us ? '${_round(m * _ftPerM, 10)} feet' : '${_round(m.toDouble(), 5)} meters';

  static int _round(double v, int step) => (v / step).round() * step;
}

/// Compass abbreviations from the core ("NE") as words ("northeast").
String cardinalWord(String? c) => switch (c) {
      'N' => 'north',
      'NE' => 'northeast',
      'E' => 'east',
      'SE' => 'southeast',
      'S' => 'south',
      'SW' => 'southwest',
      'W' => 'west',
      'NW' => 'northwest',
      _ => '',
    };

/// "3:42 PM" in the phone's local time.
String clockTime(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}
