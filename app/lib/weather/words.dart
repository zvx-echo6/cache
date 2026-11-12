import '../settings/app_settings.dart' show formatMinutes;

/// "just now", "12 min ago", "3 hours ago", "3 days ago": how long ago, in words for people.
String agoWords(Duration d) {
  final m = d.inMinutes;
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  final h = d.inHours;
  if (h < 24) return h == 1 ? '1 hour ago' : '$h hours ago';
  final days = d.inDays;
  if (days < 60) return days == 1 ? '1 day ago' : '$days days ago';
  final months = days ~/ 30;
  return '$months months ago';
}

const List<String> _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "today", "yesterday", "Friday" (within the last week) or "Oct 12": [then] as a day, from [now].
String dayWords(DateTime then, DateTime now) {
  final a = DateTime(then.year, then.month, then.day);
  final b = DateTime(now.year, now.month, now.day);
  final days = b.difference(a).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return _weekdays[then.weekday - 1];
  return '${_months[then.month - 1]} ${then.day}';
}

/// "every 15 min", "every 3 hours", "every day": a refresh interval.
String everyWords(int minutes) {
  if (minutes < 60) return 'every $minutes min';
  if (minutes % 1440 == 0) return minutes == 1440 ? 'every day' : 'every ${minutes ~/ 1440} days';
  if (minutes % 60 == 0) return minutes == 60 ? 'every hour' : 'every ${minutes ~/ 60} hours';
  return 'every ${(minutes / 60).toStringAsFixed(1)} hours';
}

/// [line] with its first letter in capitals, for a line of the screen that starts with a value as the source words it ("rain ·
/// High 61 °F" reads "Rain · High 61 °F"). Only the screen: what the model reads keeps the source's words.
String lineStart(String line) {
  if (line.isEmpty) return line;
  final first = line.runes.first;
  final c = String.fromCharCode(first);
  return c.toUpperCase() + line.substring(c.length);
}

const List<String> _weekdaysShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// A moment on a place's own clock: its date (as midnight UTC, for comparing dates) and the minutes after midnight.
typedef PlaceClock = ({DateTime day, int minutes});

/// A moment as the core writes it at a place ("2026-11-11T14:14:00-07:00", "2026-11-11 21:00", "2026-11-11"), read as the
/// place's own clock shows it, whatever this device's time zone. A date alone is midnight. Null when [text] is not a moment.
PlaceClock? placeClock(String? text) {
  final m = RegExp(r'^(\d{4})-(\d\d)-(\d\d)(?:[ T](\d\d):(\d\d))?').firstMatch(text?.trim() ?? '');
  if (m == null) return null;
  return (
    day: DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)),
    minutes: m.group(4) == null ? 0 : int.parse(m.group(4)!) * 60 + int.parse(m.group(5)!),
  );
}

/// The date at a place at [now] (as midnight UTC, see [PlaceClock]). The place's clock is the offset [stamp] is written with
/// (the core stamps a source's times in the place's zone, "2026-11-11T14:14:00-07:00"); without one, this device's.
DateTime placeToday(DateTime now, String? stamp) {
  final o = RegExp(r'([+-])(\d\d):(\d\d)$').firstMatch(stamp?.trim() ?? '');
  final minutes = o == null ? now.timeZoneOffset.inMinutes : (o.group(1) == '-' ? -1 : 1) * (int.parse(o.group(2)!) * 60 + int.parse(o.group(3)!));
  final there = now.toUtc().add(Duration(minutes: minutes));
  return DateTime.utc(there.year, there.month, there.day);
}

/// "2:14 PM" for a moment on [today], "Wed 2:14 PM" within six days of it, else "Nov 4, 2:14 PM".
String clockWords(PlaceClock at, DateTime today) {
  final time = formatMinutes(at.minutes);
  final days = at.day.difference(today).inDays;
  if (days == 0) return time;
  if (days.abs() < 7) return '${_weekdaysShort[at.day.weekday - 1]} $time';
  return '${_months[at.day.month - 1]} ${at.day.day}, $time';
}
