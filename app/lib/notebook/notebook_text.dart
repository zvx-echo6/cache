/// The words the Notebook screens show for dates, values and the "Due again" cue (UX: NOTEBOOK-UX.md 2 and 3).
library;

import 'notebook_model.dart';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "4:12 PM"
String clockText(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${_two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// "Sun 25 Oct", with the year when it is not [now]'s.
String dayText(DateTime t, {DateTime? now}) {
  final y = now == null || now.year == t.year ? '' : ' ${t.year}';
  return '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}$y';
}

/// "Sun 25 Oct, 4:12 PM"
String dayTimeText(DateTime t, {DateTime? now}) => '${dayText(t, now: now)}, ${clockText(t)}';

/// "Unfinished entry · Tue 4:12 PM": the weekday and time, for something within the last week.
String weekdayTimeText(DateTime t) => '${_days[t.weekday - 1]} ${clockText(t)}';

/// Whole days from [from] to [to] by the calendar (not by 24-hour spans).
int calendarDays(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// "3 days", "2 weeks", "5 months", "1 year": a span of [days] in the unit people would use.
String spanText(int days) {
  String n(int v, String unit) => '$v $unit${v == 1 ? '' : 's'}';
  if (days < 14) return n(days, 'day');
  if (days < 60) return n((days / 7).round(), 'week');
  if (days < 730) return n((days / 30.44).round(), 'month');
  return n((days / 365.25).round(), 'year');
}

/// "today", "yesterday", "4 days ago", "5 months ago".
String agoText(DateTime then, DateTime now) {
  final d = calendarDays(then, now);
  if (d <= 0) return 'today';
  if (d == 1) return 'yesterday';
  return '${spanText(d)} ago';
}

/// The interval words a log's due_every holds, as (count, unit) with unit day, week, month or year.
(int, String)? parseEvery(String? every) {
  if (every == null) return null;
  if (const ['day', 'week', 'month', 'year'].contains(every)) return (1, every);
  final parts = every.split(' ');
  final n = parts.length == 2 ? int.tryParse(parts[0]) : null;
  if (n == null || n < 2) return null;
  final unit = parts[1].endsWith('s') ? parts[1].substring(0, parts[1].length - 1) : parts[1];
  return const ['day', 'week', 'month', 'year'].contains(unit) ? (n, unit) : null;
}

/// "every month", "every 3 months"
String everyText(String every) {
  final p = parseEvery(every);
  if (p == null) return 'every $every';
  return p.$1 == 1 ? 'every ${p.$2}' : 'every ${p.$1} ${p.$2}s';
}

/// The day a log is due again: its last entry's day plus the interval (months keep the day, clamped to the month's end).
DateTime? dueDate(DateTime last, String? every) {
  final p = parseEvery(every);
  if (p == null) return null;
  final (n, unit) = p;
  switch (unit) {
    case 'day':
      return DateTime(last.year, last.month, last.day + n);
    case 'week':
      return DateTime(last.year, last.month, last.day + 7 * n);
    default:
      final months = unit == 'year' ? 12 * n : n;
      final y = last.year + (last.month - 1 + months) ~/ 12;
      final m = (last.month - 1 + months) % 12 + 1;
      final lastDay = DateTime(y, m + 1, 0).day;
      return DateTime(y, m, last.day > lastDay ? lastDay : last.day);
  }
}

/// The due cue of a log: its words and whether it is overdue (shown in the warning colour, never by colour alone). Null for a log
/// with no interval or no entries yet.
({String text, bool overdue, int days})? dueCue(Notebook log, DateTime now) {
  final last = log.lastEntry;
  final due = last == null ? null : dueDate(last.when, log.def.dueEvery);
  if (due == null) return null;
  final d = calendarDays(now, due);
  if (d < 0) return (text: 'Overdue by ${spanText(-d)}', overdue: true, days: d);
  if (d == 0) return (text: 'Due today', overdue: false, days: d);
  return (text: 'Due in ${spanText(d)}', overdue: false, days: d);
}

/// The history screen's line: "Due again in 26 days (every month)", "Due again today (every month)", "Overdue by 5 days (every
/// month)".
String? dueAgainText(Notebook log, DateTime now) {
  final c = dueCue(log, now);
  if (c == null) return null;
  final every = everyText(log.def.dueEvery!);
  if (c.overdue) return '${c.text} ($every)';
  if (c.days == 0) return 'Due again today ($every)';
  return 'Due again in ${spanText(c.days)} ($every)';
}

/// A value as the screens show it: "20 min", "Yes", "Full", "Home", "2 photos".
String valueText(LogField f, Object? v) => switch (f.type) {
      FieldType.number => v is num ? (f.unit == null ? numberText(v) : '${numberText(v)} ${f.unit}') : '',
      FieldType.yesNo => v == true ? 'Yes' : (v == false ? 'No' : ''),
      FieldType.text || FieldType.choice => v is String ? v.trim() : '',
      FieldType.place => NbPlace.fromJson(v)?.display ?? '',
      FieldType.photo => v is List && v.isNotEmpty ? (v.length == 1 ? '1 photo' : '${v.length} photos') : '',
    };

/// The value the Logbook row shows after "Last done ...": the first number field with a value, else the first text field.
String? mainValue(NotebookDef def, NbEntry e) {
  for (final type in const [FieldType.number, FieldType.text]) {
    for (final f in def.visible) {
      if (f.type != type || f.fid == null) continue;
      final t = valueText(f, e.values[f.fid]);
      if (t.isNotEmpty) return t;
    }
  }
  return null;
}

/// Up to [max] values of a log entry: labels only for Yes/No and Choice ("20 min · Under load: Yes · Fuel level: Full").
List<String> entryValues(NotebookDef def, NbEntry e, {int max = 3}) {
  final out = <String>[];
  for (final f in def.visible) {
    if (out.length >= max || f.fid == null) break;
    final t = valueText(f, e.values[f.fid]);
    if (t.isEmpty) continue;
    out.add(f.type == FieldType.yesNo || f.type == FieldType.choice ? '${f.label}: $t' : t);
  }
  return out;
}

/// The Logbook row's second line: "Last done 4 days ago · 20 min" or "Not done yet".
String lastDoneText(Notebook log, DateTime now) {
  final e = log.lastEntry;
  if (e == null) return 'Not done yet';
  final main = mainValue(log.def, e);
  return 'Last done ${agoText(e.when, now)}${main == null ? '' : ' · $main'}';
}

/// The heading of a list group: "THIS WEEK" for the last 7 days, then the month ("OCTOBER", "OCTOBER 2025").
String groupLabel(DateTime t, DateTime now) {
  final d = calendarDays(t, now);
  if (d >= 0 && d < 7) return 'THIS WEEK';
  final m = _monthNames[t.month - 1].toUpperCase();
  return t.year == now.year ? m : '$m ${t.year}';
}

/// The month heading of a log's history ("OCTOBER", "OCTOBER 2025").
String monthLabel(DateTime t, DateTime now) {
  final m = _monthNames[t.month - 1].toUpperCase();
  return t.year == now.year ? m : '$m ${t.year}';
}

/// A Journal entry's title: its own, else the first line of its text.
String entryTitle(NbEntry e) {
  final t = e.title?.trim() ?? '';
  if (t.isNotEmpty) return t;
  final first = (e.body ?? '').trim().split('\n').first.trim();
  return first.isEmpty ? 'Untitled entry' : first;
}

/// The line under the title: the text after the title (or after the first line when there is no title).
String entryPreview(NbEntry e) {
  final body = (e.body ?? '').trim();
  if ((e.title?.trim() ?? '').isNotEmpty) return body.split('\n').first.trim();
  final lines = body.split('\n');
  return lines.length > 1 ? lines.skip(1).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim() : '';
}

/// ISO 8601 with the phone's offset for [t] (`2026-10-29T16:12:00-06:00`).
String isoLocal(DateTime t) {
  final o = t.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final m = o.inMinutes.abs();
  return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}'
      '$sign${_two(m ~/ 60)}:${_two(m % 60)}';
}

/// One checklist item of an entry's text: a Markdown task line, `- [ ] Spare glasses` or `- [x] Copy of prescription`.
class CheckItem {
  const CheckItem(this.text, {this.done = false});

  final String text;
  final bool done;
}

bool _isTask(String l) {
  final t = l.trimLeft();
  return t.startsWith('- [ ] ') || t.startsWith('- [x] ') || t.startsWith('- [X] ') || t == '- [ ]' || t == '- [x]';
}

/// [body] as its text and its checklist (the task lines, in order). Entries without task lines have no checklist.
(String, List<CheckItem>) splitChecklist(String? body) {
  final text = <String>[];
  final items = <CheckItem>[];
  for (final l in (body ?? '').split('\n')) {
    if (_isTask(l)) {
      final t = l.trimLeft();
      items.add(CheckItem(t.length > 6 ? t.substring(6) : '', done: t[3] != ' '));
    } else {
      text.add(l);
    }
  }
  return (text.join('\n').trim(), items);
}

/// The text with the checklist after it, as Markdown task lines (Obsidian and Logseq read them the same way).
String joinChecklist(String text, List<CheckItem> items) {
  final lines = [for (final i in items) if (i.text.trim().isNotEmpty) '- [${i.done ? 'x' : ' '}] ${i.text.trim()}'];
  if (lines.isEmpty) return text.trim();
  return [if (text.trim().isNotEmpty) text.trim(), lines.join('\n')].join('\n\n');
}
