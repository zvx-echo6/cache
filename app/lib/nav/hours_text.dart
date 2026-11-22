import 'package:cache_search/cache_search.dart' show MapPlace;

/// A place's opening hours as the card shows them: [text] and, only when it can be answered for sure, [openNow].
///
/// The core reads the OSM `opening_hours` value (it parses it, and says the week and the place's time zone only when the value
/// is a plain weekly pattern: no holidays, sun events, months, dates or comments). A value it does not read stays as it is in
/// the places data, shown as that text with no Open or Closed: never a wrong answer. See `hours.rs` in cache_places.
class HoursView {
  const HoursView(this.text, {this.openNow});

  /// "Mon–Fri 9 AM–7 PM · Sat 10 AM–5 PM", "Open 24 hours", or the raw value.
  final String text;

  /// True: "Open now". False: "Closed now". Null: not known, so nothing is said.
  final bool? openNow;
}

/// The card's hours for [p] at [now] (default: the clock), or null when it has none. [use24h]: the phone's 12 or 24 hour setting.
HoursView? hoursViewFor(MapPlace p, {required bool use24h, DateTime? now}) {
  final raw = p.hours;
  if (raw == null) return null;
  final week = p.hoursWeek;
  if (week == null) return HoursView(raw);
  final off = p.utcOffsetMin;
  return HoursView(hoursText(week, use24h: use24h), openNow: off == null || !p.hoursExact ? null : isOpenAt(week, now ?? DateTime.now(), off));
}

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// A minute count from a day's midnight as a clock time; 1440 and more is the next day's ("26:00" is 2 AM).
String clockText(int minutes, {required bool use24h}) {
  final m = minutes % 1440;
  final h = m ~/ 60, mm = m % 60;
  if (use24h) return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
  // The 12 hour setting says "midnight" and "noon" for the two times that are ambiguous as 12 AM and 12 PM.
  if (mm == 0 && h == 0) return 'midnight';
  if (mm == 0 && h == 12) return 'noon';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12${mm == 0 ? '' : ':${mm.toString().padLeft(2, '0')}'} ${h < 12 ? 'AM' : 'PM'}';
}

String _ranges(List<List<int>> day, bool use24h) {
  if (day.length == 1 && day[0][0] == 0 && day[0][1] == 1440) return 'open 24 hours';
  return day.map((r) => '${clockText(r[0], use24h: use24h)}–${clockText(r[1], use24h: use24h)}').join(', ');
}

String _dayList(List<int> days) {
  final parts = <String>[];
  var i = 0;
  while (i < days.length) {
    var j = i;
    while (j + 1 < days.length && days[j + 1] == days[j] + 1) {
      j++;
    }
    parts.add(j > i ? '${_days[days[i]]}–${_days[days[j]]}' : _days[days[i]]);
    i = j + 1;
  }
  return parts.join(', ');
}

/// The week in plain words, closed days left out: "Mon–Fri 9 AM–7 PM · Sat 10 AM–5 PM", "Daily 8 AM–9 PM", "Open 24 hours".
/// Days with the same hours are one group; groups are in the order of their first day.
String hoursText(List<List<List<int>>> week, {required bool use24h}) {
  final groups = <String, List<int>>{};
  for (var d = 0; d < 7; d++) {
    if (week[d].isEmpty) continue;
    groups.putIfAbsent(_ranges(week[d], use24h), () => []).add(d);
  }
  if (groups.length == 1 && groups.values.first.length == 7) {
    final h = groups.keys.first;
    return h == 'open 24 hours' ? 'Open 24 hours' : 'Daily $h';
  }
  return [for (final e in groups.entries) '${_dayList(e.value)} ${e.key}'].join(' · ');
}

/// Whether the place is open at [now], reading the week in the place's time zone ([utcOffsetMin] from UTC). A range that
/// runs past midnight (end over 1440) belongs to the day it starts and covers the start of the next. The end is not open.
bool isOpenAt(List<List<List<int>>> week, DateTime now, int utcOffsetMin) {
  final local = now.toUtc().add(Duration(minutes: utcOffsetMin));
  final secs = local.hour * 3600 + local.minute * 60 + local.second;
  final today = local.weekday - 1; // DateTime: Monday is 1
  for (final r in week[today]) {
    if (secs >= r[0] * 60 && secs < r[1] * 60) return true;
  }
  for (final r in week[(today + 6) % 7]) {
    final t = secs + 86400;
    if (r[1] > 1440 && t >= r[0] * 60 && t < r[1] * 60) return true;
  }
  return false;
}
