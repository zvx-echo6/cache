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
