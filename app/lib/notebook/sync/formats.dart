/// How a notebook entry is written as Markdown for Obsidian (one file, YAML properties on top) and for Logseq (one block on a
/// journal page, `key:: value` properties), and read back. Machine formats: Cache writes them with its own small emitter so the
/// output is stable byte for byte (LF, UTF-8, one trailing newline), and reads back only what it writes plus the properties
/// people add (kept as they are).
library;

import '../notebook_model.dart';

/// Cache's own property names; a field whose name would collide gets `_field`.
const List<String> kCacheProps = ['cache_id', 'notebook', 'title', 'date', 'time', 'place', 'lat', 'lon', 'photos', 'private'];
const List<String> _reserved = ['tags', 'aliases', 'cssclasses', 'id', 'alias', 'icon', 'template', 'public', 'collapsed', 'filters'];

/// An entry as a file holds it: what Cache owns, field values by property name, and the properties it does not own (their
/// lines kept verbatim, in order).
class EntryDoc {
  EntryDoc({
    required this.id,
    required this.notebook,
    required this.when,
    this.title,
    this.body = '',
    this.place,
    this.photos = const [],
    this.fields = const {},
    this.private = false,
    this.extra = const [],
  });

  final String id;
  final String notebook;

  /// Local date and time without an offset (`2026-10-27T16:12:00`).
  final String when;
  final String? title;
  final String body;
  final NbPlace? place;

  /// Photo ids (files `cache-<id>.jpg`).
  final List<String> photos;

  /// Field values by property name: text, number, bool, a place `{label, lat, lon}` or a list of photo ids.
  final Map<String, Object?> fields;
  final bool private;
  final List<String> extra;
}

/// A label as a property name: lower snake case (`Run time` -> `run_time`), `_field` when it collides with Cache's names or
/// the apps' own, `field` when nothing is left.
String propName(String label, {Iterable<String> taken = const []}) {
  var s = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  if (s.isEmpty) s = 'field';
  if (kCacheProps.contains(s) || _reserved.contains(s)) s = '${s}_field';
  var out = s;
  var i = 2;
  while (taken.contains(out)) {
    out = '${s}_${i++}';
  }
  return out;
}

/// The wall-clock part of a local ISO time with offset.
String wallTime(String occurredAt) => occurredAt.length >= 19 ? occurredAt.substring(0, 19) : '${occurredAt.substring(0, 16)}:00';

/// [wall] with [offset] (`-06:00`, `Z`), as the store takes it.
String withOffset(String wall, String offset) => '$wall$offset';

/// The offset of a local ISO time (`-06:00`), or the phone's now.
String offsetOf(String? occurredAt, {DateTime? now}) {
  final m = occurredAt == null ? null : RegExp(r'(Z|[+-]\d\d:\d\d)$').firstMatch(occurredAt);
  if (m != null) return m.group(1)!;
  final o = (now ?? DateTime.now()).timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final mins = o.inMinutes.abs();
  return '$sign${(mins ~/ 60).toString().padLeft(2, '0')}:${(mins % 60).toString().padLeft(2, '0')}';
}

// ---- YAML values (flat) ----

final RegExp _looksTyped = RegExp(r'^(true|false|yes|no|null|~|[-+]?\d+(\.\d+)?([eE][-+]?\d+)?|\d{4}-\d\d-\d\d.*)$', caseSensitive: false);

/// A text value as YAML: double-quoted whenever it holds `: `, `#`, `[[`, quotes, spaces at either end, a line break, or
/// looks like a number, a yes/no or a date.
String yamlText(String s) {
  final quote = s.isEmpty ||
      s.contains(': ') ||
      s.contains('#') ||
      s.contains('[[') ||
      s.contains('"') ||
      s.contains("'") ||
      s.contains('\n') ||
      s != s.trim() ||
      s.startsWith(RegExp(r'[-?:,\[\]{}&*!|>%@`]')) ||
      s.endsWith(':') ||
      _looksTyped.hasMatch(s);
  if (!quote) return s;
  return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
}

String _num(num v) => v is int || v == v.truncateToDouble() && v.abs() < 1e15 ? '${v.toInt()}' : '$v';

String _yaml(Object? v) => switch (v) {
      bool b => '$b',
      num n => _num(n),
      _ => yamlText('$v'),
    };

/// A scalar read back: quoted text, true/false, a number, or text.
Object? yamlValue(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    return s.substring(1, s.length - 1).replaceAllMapped(RegExp(r'\\(.)'), (m) => switch (m.group(1)) { 'n' => '\n', 't' => '\t', final c => c! });
  }
  if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) return s.substring(1, s.length - 1).replaceAll("''", "'");
  if (s == 'true') return true;
  if (s == 'false') return false;
  final n = num.tryParse(s);
  if (n != null && RegExp(r'^[-+]?\d').hasMatch(s)) return n;
  return s;
}

/// The properties block of a file: each key with its raw lines (a list's items included), in order, and the body after it.
/// Null when the file has no properties block, or one that is not closed (unreadable: Cache leaves the file alone).
({List<(String key, List<String> lines)> props, String body})? splitFrontMatter(String text) {
  final t = text.replaceAll('\r\n', '\n');
  if (!t.startsWith('---\n')) return null;
  final end = t.indexOf('\n---', 3);
  if (end < 0) return null;
  final after = t.indexOf('\n', end + 4);
  final head = t.substring(4, end + 1);
  final body = after < 0 ? '' : t.substring(after + 1);
  final props = <(String, List<String>)>[];
  for (final line in head.split('\n')) {
    if (line.isEmpty) continue;
    final m = RegExp(r'^([^\s:#][^:]*):(?:\s|$)').firstMatch(line);
    if (m != null) {
      props.add((m.group(1)!.trim(), [line]));
    } else if (props.isNotEmpty && (line.startsWith(' ') || line.startsWith('\t') || line.startsWith('-'))) {
      props.last.$2.add(line);
    } else {
      return null;
    }
  }
  return (props: props, body: body);
}

/// A property's value from its lines: a scalar, or a list.
Object? propValue(List<String> lines) {
  final first = lines.first;
  final rest = first.substring(first.indexOf(':') + 1);
  if (lines.length == 1) {
    final s = rest.trim();
    if (s.startsWith('[') && s.endsWith(']')) {
      final inner = s.substring(1, s.length - 1).trim();
      return inner.isEmpty ? <Object?>[] : [for (final p in inner.split(',')) yamlValue(p)];
    }
    return yamlValue(rest);
  }
  return [
    for (final l in lines.skip(1))
      if (l.trim().startsWith('- ')) yamlValue(l.trim().substring(2)) else if (l.trim() == '-') null,
  ];
}

// ---- Obsidian ----

/// An entry as an Obsidian note: properties, then the text as typed.
String renderObsidian(EntryDoc d) {
  final b = StringBuffer('---\n');
  void p(String k, Object? v) => b.writeln('$k: ${_yaml(v)}');
  p('cache_id', d.id);
  p('notebook', d.notebook);
  if (d.title != null && d.title!.trim().isNotEmpty) p('title', d.title);
  // Obsidian's Date and Date & time types: written as they are, unquoted.
  b.writeln('date: ${d.when.substring(0, 10)}');
  b.writeln('time: ${d.when}');
  if (d.place != null) {
    if (d.place!.label != null) p('place', d.place!.label);
    p('lat', d.place!.lat);
    p('lon', d.place!.lon);
  }
  if (d.private) p('private', true);
  if (d.photos.isNotEmpty) {
    b.writeln('photos:');
    for (final id in d.photos) {
      b.writeln('  - "[[cache-$id.jpg]]"');
    }
  }
  for (final e in d.fields.entries) {
    final v = e.value;
    if (v == null) continue;
    if (v is Map) {
      if (v['label'] != null) p(e.key, v['label']);
      p('${e.key}_lat', v['lat']);
      p('${e.key}_lon', v['lon']);
    } else if (v is List) {
      b.writeln('${e.key}:');
      for (final id in v) {
        b.writeln('  - "[[cache-$id.jpg]]"');
      }
    } else {
      p(e.key, v);
    }
  }
  for (final l in d.extra) {
    b.writeln(l);
  }
  b.writeln('---');
  final body = d.body.replaceAll('\r\n', '\n').trimRight();
  if (body.isNotEmpty) b.writeln(body);
  return b.toString();
}

/// The photo id in a link to `cache-<id>.jpg` (`[[cache-<id>.jpg]]` or `![x](../assets/cache-<id>.jpg)`).
String? photoIdOf(Object? link) {
  final m = RegExp(r'cache-([A-Za-z0-9-]+)\.jpg').firstMatch('$link');
  return m?.group(1);
}

/// An Obsidian note read back; [fieldProps] are the field property names of its notebook (with their type), so the rest are
/// kept as the user's own. Null when the properties cannot be read.
EntryDoc? parseObsidian(String text, {required String fallbackId, required String fallbackNotebook, required Map<String, FieldType> fieldProps, String? fallbackWhen}) {
  final fm = splitFrontMatter(text);
  final List<(String, List<String>)> props;
  final String body;
  if (fm == null) {
    if (text.trimLeft().startsWith('---')) return null;
    props = const [];
    body = text;
  } else {
    props = fm.props;
    body = fm.body;
  }
  final map = {for (final (k, lines) in props) k: lines};
  Object? v(String k) => map[k] == null ? null : propValue(map[k]!);
  final extra = <String>[];
  final fields = <String, Object?>{};
  final placeKeys = {for (final e in fieldProps.entries) if (e.value == FieldType.place) e.key};
  for (final (k, lines) in props) {
    if (kCacheProps.contains(k)) continue;
    final base = k.endsWith('_lat') || k.endsWith('_lon') ? k.substring(0, k.length - 4) : k;
    if (placeKeys.contains(base)) continue;
    final type = fieldProps[k];
    if (type == null) {
      extra.addAll(lines);
      continue;
    }
    final val = propValue(lines);
    fields[k] = switch (type) {
      FieldType.photo => [for (final x in (val is List ? val : [val])) ?photoIdOf(x)],
      _ => val,
    };
  }
  for (final k in placeKeys) {
    final la = v('${k}_lat'), lo = v('${k}_lon');
    if (la is num && lo is num) fields[k] = {'lat': la, 'lon': lo, if (v(k) != null) 'label': '${v(k)}'};
  }
  final lat = v('lat'), lon = v('lon');
  final date = v('date');
  final time = v('time');
  var when = time is String && time.length >= 16 ? wallTime(time) : (date is String && date.length >= 10 ? '${date.substring(0, 10)}T00:00:00' : (fallbackWhen ?? ''));
  if (when.isEmpty) when = wallTime(DateTime.now().toIso8601String());
  final photos = v('photos');
  return EntryDoc(
    id: v('cache_id') is String ? v('cache_id') as String : fallbackId,
    notebook: v('notebook') is String ? v('notebook') as String : fallbackNotebook,
    when: when,
    title: v('title')?.toString(),
    body: body.replaceAll('\r\n', '\n').trimRight(),
    place: lat is num && lon is num ? NbPlace(lat: lat.toDouble(), lon: lon.toDouble(), label: v('place')?.toString()) : null,
    photos: [for (final x in (photos is List ? photos : const [])) ?photoIdOf(x)],
    fields: fields,
    private: v('private') == true,
    extra: extra,
  );
}

/// The file name a new note gets: `YYYY-MM-DD <title>` (untitled: `YYYY-MM-DD HHMM`), with characters the apps refuse as
/// spaces, at most 80 characters.
String noteFileName(EntryDoc d) {
  final day = d.when.substring(0, 10);
  final t = (d.title ?? '').trim();
  final raw = t.isEmpty ? '$day ${d.when.substring(11, 13)}${d.when.substring(14, 16)}' : '$day $t';
  var s = raw.replaceAll(RegExp(r'[#|^:%\[\]/\\?*"<>]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length > 80) s = s.substring(0, 80).trim();
  return s;
}

/// A notebook's name as a folder name.
String folderName(String notebook) {
  final s = notebook.replaceAll(RegExp(r'[#|^:%\[\]/\\?*"<>.]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? 'Notebook' : s;
}

// ---- Logseq ----

String _lsName(String prop) => prop.replaceAll('_', '-');

String _lsValue(Object? v) {
  if (v is bool) return v ? 'yes' : 'no';
  if (v is num) return _num(v);
  final s = '$v'.replaceAll('\n', ' ');
  return s.contains('[[') || s.contains('#') || s.contains(',') ? '"${s.replaceAll('"', "'")}"' : s;
}

/// An entry as a Logseq block: "- HH:MM Title", its properties two spaces in, then its text as child blocks (one per line),
/// photos as image children.
String renderLogseq(EntryDoc d) {
  final b = StringBuffer();
  final t = (d.title ?? '').trim();
  b.writeln('- ${d.when.substring(11, 16)}${t.isEmpty ? '' : ' $t'}');
  void p(String k, Object? v) => b.writeln('  ${_lsName(k)}:: ${_lsValue(v)}');
  p('cache_id', d.id);
  p('notebook', d.notebook);
  if (d.place != null) {
    if (d.place!.label != null) p('place', d.place!.label);
    p('lat', d.place!.lat);
    p('lon', d.place!.lon);
  }
  if (d.private) p('private', true);
  for (final e in d.fields.entries) {
    final v = e.value;
    if (v == null || v is List) continue;
    if (v is Map) {
      if (v['label'] != null) p(e.key, v['label']);
      p('${e.key}_lat', v['lat']);
      p('${e.key}_lon', v['lon']);
    } else {
      p(e.key, v);
    }
  }
  for (final l in d.extra) {
    b.writeln(l);
  }
  for (final line in d.body.replaceAll('\r\n', '\n').split('\n')) {
    if (line.trim().isEmpty) continue;
    b.writeln('\t- $line');
  }
  for (final id in [...d.photos, for (final v in d.fields.values) if (v is List) ...v.whereType<String>()]) {
    b.writeln('\t- ![cache-$id.jpg](../assets/cache-$id.jpg)');
  }
  return b.toString();
}

/// One top-level block of a Logseq page: its lines (with their line ends) and where it starts.
class LsBlock {
  LsBlock(this.lines);

  final List<String> lines;
  String get text => lines.join();

  /// The `cache-id::` of the block, when it is Cache's.
  String? get cacheId {
    for (final l in lines.skip(1)) {
      final m = RegExp(r'^\s+cache-id::\s*(\S+)').firstMatch(l);
      if (m != null) return m.group(1);
      if (l.startsWith('\t')) break;
    }
    return null;
  }
}

/// A page split into what comes before its first block (page properties) and its top-level blocks. Joining them gives the
/// page back unchanged.
({String head, List<LsBlock> blocks}) splitPage(String text) {
  final lines = RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text).map((m) => m.group(0)!).toList();
  final head = StringBuffer();
  final blocks = <LsBlock>[];
  for (final l in lines) {
    if (l.startsWith('- ') || l.trimRight() == '-') {
      blocks.add(LsBlock([l]));
    } else if (blocks.isEmpty) {
      head.write(l);
    } else {
      blocks.last.lines.add(l);
    }
  }
  return (head: head.toString(), blocks: blocks);
}

/// A Logseq block read back (see [renderLogseq]); [day] is its page's date (YYYY-MM-DD).
EntryDoc parseLogseq(LsBlock block, {required String day, required String fallbackNotebook, required Map<String, FieldType> fieldProps}) {
  final first = block.lines.first.replaceFirst(RegExp(r'^-\s?'), '').trimRight();
  final tm = RegExp(r'^(\d\d):(\d\d)(?:\s+(.*))?$').firstMatch(first);
  final props = <String, String>{};
  final extra = <String>[];
  final body = <String>[];
  final photos = <String>[];
  final fieldPhotos = <String>[];
  for (final l in block.lines.skip(1)) {
    final line = l.replaceAll('\n', '');
    final pm = RegExp(r'^  ([A-Za-z0-9._*+!?$%&=<>-]+)::\s?(.*)$').firstMatch(line);
    if (pm != null && body.isEmpty) {
      props[pm.group(1)!.toLowerCase()] = pm.group(2)!;
      continue;
    }
    if (line.startsWith('\t')) {
      final child = line.substring(1);
      final img = photoIdOf(child);
      if (img != null && child.trim().startsWith('- ![')) {
        photos.add(img);
        continue;
      }
      body.add(child.startsWith('- ') ? child.substring(2) : child.trimLeft());
    }
  }
  Object? val(String raw) {
    final s = raw.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) return s.substring(1, s.length - 1);
    if (s == 'yes' || s == 'true') return true;
    if (s == 'no' || s == 'false') return false;
    final n = num.tryParse(s);
    return n ?? s;
  }

  final fields = <String, Object?>{};
  final ownNames = {for (final k in kCacheProps) _lsName(k)};
  final placeKeys = {for (final e in fieldProps.entries) if (e.value == FieldType.place) _lsName(e.key): e.key};
  for (final e in props.entries) {
    if (ownNames.contains(e.key)) continue;
    final base = e.key.endsWith('-lat') || e.key.endsWith('-lon') ? e.key.substring(0, e.key.length - 4) : e.key;
    if (placeKeys.containsKey(base)) continue;
    final match = fieldProps.entries.where((f) => _lsName(f.key) == e.key).firstOrNull;
    if (match == null) {
      extra.add('  ${e.key}:: ${e.value}');
      continue;
    }
    fields[match.key] = match.value == FieldType.text || match.value == FieldType.choice ? '${val(e.value)}' : val(e.value);
  }
  for (final e in placeKeys.entries) {
    final la = val(props['${e.key}-lat'] ?? ''), lo = val(props['${e.key}-lon'] ?? '');
    if (la is num && lo is num) fields[e.value] = {'lat': la, 'lon': lo, if (props[e.key] != null) 'label': '${val(props[e.key]!)}'};
  }
  final photoField = fieldProps.entries.where((f) => f.value == FieldType.photo).map((f) => f.key).firstOrNull;
  if (photoField != null && fieldPhotos.isNotEmpty) fields[photoField] = fieldPhotos;
  final lat = val(props['lat'] ?? ''), lon = val(props['lon'] ?? '');
  return EntryDoc(
    id: props['cache-id'] ?? '',
    notebook: props['notebook'] != null ? '${val(props['notebook']!)}' : fallbackNotebook,
    when: '${day}T${tm?.group(1) ?? '00'}:${tm?.group(2) ?? '00'}:00',
    title: tm == null ? (first.isEmpty ? null : first) : tm.group(3),
    body: body.join('\n'),
    place: lat is num && lon is num ? NbPlace(lat: lat.toDouble(), lon: lon.toDouble(), label: props['place'] == null ? null : '${val(props['place']!)}') : null,
    photos: photos,
    fields: fields,
    private: val(props['private'] ?? '') == true,
    extra: extra,
  );
}

/// Logseq's journal page file name for [day] (YYYY-MM-DD) in its `:journal/file-name-format` (`yyyy_MM_dd` by default).
String journalFileName(String day, {String format = 'yyyy_MM_dd'}) =>
    '${format.replaceAll('yyyy', day.substring(0, 4)).replaceAll('MM', day.substring(5, 7)).replaceAll('dd', day.substring(8, 10))}.md';

/// The day of a journal page file name in [format], or null.
String? dayOfJournal(String fileName, {String format = 'yyyy_MM_dd'}) {
  final pattern = RegExp('^${RegExp.escape(format).replaceAll('yyyy', r'(?<y>\d{4})').replaceAll('MM', r'(?<m>\d\d)').replaceAll('dd', r'(?<d>\d\d)')}\\.md\$');
  final m = pattern.firstMatch(fileName);
  if (m == null) return null;
  return '${m.namedGroup('y')}-${m.namedGroup('m')}-${m.namedGroup('d')}';
}

/// What Cache reads of a graph's `logseq/config.edn`: the journal file name format and folder, and whether it is an Org graph.
({String format, String dir, bool org}) readLogseqConfig(String? edn) {
  String? str(String key) => edn == null ? null : RegExp('${RegExp.escape(key)}\\s+"([^"]*)"').firstMatch(edn)?.group(1);
  return (
    format: str(':journal/file-name-format') ?? 'yyyy_MM_dd',
    dir: str(':journals-directory') ?? 'journals',
    org: edn != null && RegExp(r':preferred-format\s+"?:?[Oo]rg"?').hasMatch(edn),
  );
}
