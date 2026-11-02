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
///
/// [imported]: a note the person made and Cache imported by its tag. Cache then writes only what the note does not already say
/// its own way: no `notebook` (the id decides), `title` only when it is not the file's name ([titleDefault]), `date` and `time`
/// only when they are not the time Cache gave it on import ([whenDefault]), and none of the names in [skip] (the note's own
/// properties that were there before Cache, kept as they are in [EntryDoc.extra]).
String renderObsidian(EntryDoc d, {bool imported = false, Set<String> skip = const {}, String? titleDefault, String? whenDefault}) {
  final b = StringBuffer('---\n');
  void p(String k, Object? v) {
    if (!skip.contains(k)) b.writeln('$k: ${_yaml(v)}');
  }

  p('cache_id', d.id);
  if (!imported) p('notebook', d.notebook);
  if (d.title != null && d.title!.trim().isNotEmpty && !(imported && d.title!.trim() == titleDefault)) p('title', d.title);
  // Obsidian's Date and Date & time types: written as they are, unquoted.
  if (!imported || d.when != whenDefault) {
    if (!skip.contains('date')) b.writeln('date: ${d.when.substring(0, 10)}');
    if (!skip.contains('time')) b.writeln('time: ${d.when}');
  }
  if (d.place != null) {
    if (d.place!.label != null) p('place', d.place!.label);
    p('lat', d.place!.lat);
    p('lon', d.place!.lon);
  }
  if (d.private) p('private', true);
  if (d.photos.isNotEmpty && !skip.contains('photos')) {
    b.writeln('photos:');
    for (final id in d.photos) {
      b.writeln('  - "[[cache-$id.jpg]]"');
    }
  }
  for (final e in d.fields.entries) {
    final v = e.value;
    if (v == null || skip.contains(e.key)) continue;
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
///
/// [userKeys]: properties of an imported note that were the person's before Cache imported it; they are kept as they are,
/// never read as Cache's even when they share a name with Cache's own. [fallbackTitle]: the title when there is no `title`
/// (an imported note's file name).
EntryDoc? parseObsidian(String text,
    {required String fallbackId, required String fallbackNotebook, required Map<String, FieldType> fieldProps, String? fallbackWhen, Set<String> userKeys = const {}, String? fallbackTitle}) {
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
  final map = {for (final (k, lines) in props) if (!userKeys.contains(k)) k: lines};
  Object? v(String k) => map[k] == null ? null : propValue(map[k]!);
  final extra = <String>[];
  final fields = <String, Object?>{};
  final placeKeys = {for (final e in fieldProps.entries) if (e.value == FieldType.place) e.key};
  for (final (k, lines) in props) {
    if (userKeys.contains(k)) {
      extra.addAll(lines);
      continue;
    }
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
    title: v('title')?.toString() ?? fallbackTitle,
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

// ---- import by tag (1.0.30) ----
//
// A note the person made in Obsidian or Logseq that carries the import tag (`#cachesync`, settable) and no Cache id is imported
// once: Cache makes an entry for it and writes its id into the note. From then on the id decides, never the tag. When Cache
// stops syncing it (the entry deleted, or "Stop syncing this note"), the id goes and `cachesync: off` takes its place, so the
// note is never imported again unless the person deletes that line. The note's text and inline tags are never touched.

/// The import tag a connection starts with.
const String kDefaultImportTag = '#cachesync';

/// The property Cache writes into a note it stopped syncing (`cachesync: off`, Logseq `cachesync:: off`).
const String kSyncOffProp = 'cachesync';

/// Whether [tag] can be the import tag: `#`, then letters, numbers, `-`, `_` and `/`; no spaces.
bool validImportTag(String tag) => RegExp(r'^#[\p{L}\p{N}_-][\p{L}\p{N}_/-]*$', unicode: true).hasMatch(tag) && !tag.endsWith('/');

String _bareTag(String t) {
  var s = t.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.startsWith('[[') && s.endsWith(']]')) s = s.substring(2, s.length - 2);
  return s.trim();
}

/// Whether one of [tags] is the import tag [importTag]: null when none is; else the notebook its `/<notebook>` part names
/// (null for the plain tag). Case does not matter; the first matching tag wins.
({String? notebook})? importTagIn(Iterable<String> tags, String importTag) {
  final base = _bareTag(importTag).toLowerCase();
  if (base.isEmpty) return null;
  for (final t in tags) {
    final s = _bareTag(t);
    final l = s.toLowerCase();
    if (l == base) return (notebook: null);
    if (l.startsWith('$base/') && s.length > base.length + 1) return (notebook: s.substring(base.length + 1));
  }
  return null;
}

/// A notebook name as a tag part compares: lower case, runs of anything but letters and numbers as one `-`.
String tagSlug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// An inline tag: `#word` (letters, numbers, `-`, `_`, `/`) or Logseq's `#[[two words]]`, at the start or after a space.
final RegExp _inlineTag = RegExp(r'(?<![^\s(\[,;])#(\[\[[^\]\n]+\]\]|[\p{L}\p{N}_/-]+)', unicode: true);

/// [text] without fenced code blocks and inline code (a `#` in code is not a tag).
String _withoutCode(String text) =>
    text.replaceAll(RegExp(r'^ *(```|~~~)[^\n]*\n[\s\S]*?^ *\1[^\n]*$', multiLine: true), ' ').replaceAll(RegExp(r'`[^`\n]*`'), ' ');

/// The inline tags of [text].
List<String> inlineTags(String text) => [for (final m in _inlineTag.allMatches(_withoutCode(text))) _bareTag(m.group(1)!)];

bool _isOff(Object? v) => v == false || (v is String && const {'off', 'no', 'false'}.contains(v.trim().toLowerCase()));

/// The tags of an Obsidian note: its `tags` (or `tag`) property, a list or text, then the #tags of its text (not in code).
List<String> obsidianTags(String text) {
  final fm = splitFrontMatter(text);
  final out = <String>[];
  for (final (k, lines) in fm?.props ?? const <(String, List<String>)>[]) {
    final key = k.toLowerCase();
    if (key != 'tags' && key != 'tag') continue;
    final v = propValue(lines);
    for (final x in v is List ? v : [v]) {
      if (x == null) continue;
      out.addAll('$x'.split(RegExp(r'[,\s]+')).where((t) => t.isNotEmpty).map(_bareTag));
    }
  }
  out.addAll(inlineTags(fm?.body ?? text));
  return out;
}

/// The note says `cachesync: off`: Cache never imports it.
bool obsidianSyncOff(String text) {
  for (final (k, lines) in splitFrontMatter(text)?.props ?? const <(String, List<String>)>[]) {
    if (k.toLowerCase() == kSyncOffProp && _isOff(propValue(lines))) return true;
  }
  return false;
}

/// An Obsidian note with `cache_id: <id>` as its first property (a properties block is made when it has none); the rest byte
/// for byte. Null when its properties cannot be read (Cache then leaves it alone).
String? withCacheId(String text, String id) {
  final t = text.replaceAll('\r\n', '\n');
  if (splitFrontMatter(t) == null) {
    if (t.trimLeft().startsWith('---')) return null;
    return '---\ncache_id: $id\n---\n$t';
  }
  return '---\ncache_id: $id\n${t.substring(4)}';
}

/// An Obsidian note Cache stops syncing: its `cache_id` line replaced by `cachesync: off`; everything else byte for byte. Null
/// when its properties cannot be read.
String? releasedObsidian(String text) {
  final t = text.replaceAll('\r\n', '\n');
  if (splitFrontMatter(t) == null) return null;
  final end = t.indexOf('\n---', 3);
  final lines = t.substring(4, end + 1).split('\n');
  final hasOff = lines.any((l) => RegExp('^$kSyncOffProp:(\\s|\$)').hasMatch(l));
  final out = <String>[];
  for (final l in lines) {
    if (RegExp(r'^cache_id:(\s|$)').hasMatch(l)) {
      if (!hasOff) out.add('$kSyncOffProp: off');
    } else if (RegExp('^$kSyncOffProp:(\\s|\$)').hasMatch(l)) {
      out.add('$kSyncOffProp: off');
    } else {
      out.add(l);
    }
  }
  return '---\n${out.join('\n')}${t.substring(end + 1)}';
}

// ---- Logseq ----

final RegExp _lsPropLine = RegExp(r'^\s*([A-Za-z0-9_.*+!?$%&=<>-]+)::\s?(.*)$');

/// Logseq properties of [lines] (page properties, or a block's own lines): name (lower case) to its raw value.
Map<String, String> lsProps(Iterable<String> lines) => {
      for (final l in lines)
        if (_lsPropLine.firstMatch(l.replaceAll('\n', '')) case final m?) m.group(1)!.toLowerCase(): m.group(2)!.trim(),
    };

/// The tags a `tags::` value names: `a, [[b c]], #d`.
List<String> lsTagValues(String? v) {
  if (v == null) return const [];
  final out = [for (final m in RegExp(r'\[\[([^\]]+)\]\]').allMatches(v)) m.group(1)!.trim()];
  final rest = v.replaceAll(RegExp(r'#?\[\[[^\]]+\]\]'), ',');
  out.addAll(rest.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).map(_bareTag));
  return out;
}

bool _lsTrue(String? v) => v != null && const {'true', 'yes'}.contains(v.trim().toLowerCase());

/// A page's or block's `cachesync:: off`.
bool lsSyncOff(Map<String, String> props) => _isOff(props[kSyncOffProp]);

/// Whether a page's properties say it is private (`private:: true`).
bool lsPrivate(Map<String, String> props) => _lsTrue(props['private']);

/// The lines of [text] without their line ends ('' at the end dropped).
List<String> _lines(String text) {
  final l = text.split('\n');
  if (l.isNotEmpty && l.last.isEmpty) l.removeLast();
  return l;
}

/// A page's title from its file name (`a___b.md` and `a%2Fb.md` are `a/b`).
String lsPageTitle(String path) {
  var n = path.split('/').last;
  if (n.endsWith('.md')) n = n.substring(0, n.length - 3);
  n = n.replaceAll('___', '/');
  try {
    return Uri.decodeComponent(n);
  } catch (_) {
    return n;
  }
}

/// A Logseq page Cache imported as one entry: the page's properties are kept as they are (`title::` is its title; the page's
/// name otherwise), its blocks are the text, as written.
EntryDoc parseLsPage(String text, {required String pageTitle, required String when, required String notebook}) {
  final p = splitPage(text);
  final head = _lines(p.head);
  final props = lsProps(head);
  final t = props['title'];
  return EntryDoc(
    id: props['cache-id'] ?? '',
    notebook: notebook,
    when: when,
    title: t == null || t.isEmpty ? pageTitle : t,
    body: p.blocks.map((b) => b.text).join().trimRight(),
    private: lsPrivate(props),
    extra: [for (final l in head) if (!RegExp(r'^\s*cache-id::').hasMatch(l)) l],
  );
}

/// An imported page written back: `cache-id::` first, the page's own properties (a `title::` follows Cache's title), the text.
String renderLsPage(EntryDoc d, {required String pageTitle}) {
  final b = StringBuffer('cache-id:: ${d.id}\n');
  final t = (d.title ?? '').trim();
  final hasTitle = d.extra.any((l) => RegExp(r'^title::').hasMatch(l));
  if (!hasTitle && t.isNotEmpty && t != pageTitle) b.writeln('title:: $t');
  for (final l in d.extra) {
    b.writeln(RegExp(r'^title::').hasMatch(l) && t.isNotEmpty ? 'title:: $t' : l);
  }
  final body = d.body.replaceAll('\r\n', '\n').trimRight();
  if (body.isNotEmpty) b.writeln(body);
  return b.toString();
}

/// The lines of a block before its child blocks: the first line, the rest of its text and its properties.
int _ownEnd(LsBlock b) {
  var i = 1;
  while (i < b.lines.length && !b.lines[i].startsWith('\t')) {
    i++;
  }
  return i;
}

/// A block's own properties (not its children's).
Map<String, String> lsBlockProps(LsBlock b) => lsProps(b.lines.sublist(1, _ownEnd(b)));

/// The tags of a top-level block: its `tags::` and the #tags of its own lines (not of its child blocks).
List<String> lsBlockTags(LsBlock b) {
  final own = b.lines.sublist(0, _ownEnd(b));
  final props = lsProps(own.skip(1));
  return [...lsTagValues(props['tags']), ...inlineTags(own.where((l) => _lsPropLine.firstMatch(l.replaceAll('\n', '')) == null).join())];
}

/// [b] with `  cache-id:: <id>` after its own lines.
String lsBlockWithId(LsBlock b, String id) => _blockWith(b, '  cache-id:: $id\n');

String _blockWith(LsBlock b, String line) {
  final end = _ownEnd(b);
  final own = [for (final l in b.lines.sublist(0, end)) l.endsWith('\n') ? l : '$l\n'];
  return [...own, line, ...b.lines.sublist(end)].join();
}

/// A block's first line as the person sees it, without tags and spacing: how Cache knows a block again once its id was
/// taken out by hand (with or without its tag).
String lsBlockKey(String firstLine) => firstLine
    .replaceAll('\n', '')
    .replaceFirst(RegExp(r'^-\s?'), '')
    .replaceAll(_inlineTag, ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// [b] saying `cachesync:: off` (a block the person took Cache's id out of by hand); the rest byte for byte.
String lsBlockWithOff(LsBlock b) {
  if (lsSyncOff(lsBlockProps(b))) return b.text;
  final props = lsBlockProps(b);
  if (props.containsKey(kSyncOffProp)) return lsBlockReleased(b);
  return _blockWith(b, '  $kSyncOffProp:: off\n');
}

/// A Logseq page saying `cachesync:: off` as its first property; the rest byte for byte.
String lsPageWithOff(String text) {
  final p = splitPage(text);
  final props = lsProps(_lines(p.head));
  if (lsSyncOff(props)) return text;
  if (props.containsKey(kSyncOffProp)) return lsPageReleased(text);
  return '$kSyncOffProp:: off\n$text';
}

/// An Obsidian note saying `cachesync: off` as its first property (a properties block made when it has none); the rest byte
/// for byte. Null when its properties cannot be read.
String? obsidianWithOff(String text) {
  final t = text.replaceAll('\r\n', '\n');
  if (obsidianSyncOff(t)) return t;
  if (splitFrontMatter(t) == null) {
    if (t.trimLeft().startsWith('---')) return null;
    return '---\n$kSyncOffProp: off\n---\n$t';
  }
  if (splitFrontMatter(t)!.props.any((p) => p.$1 == kSyncOffProp)) return releasedObsidian(t);
  return '---\n$kSyncOffProp: off\n${t.substring(4)}';
}

/// A block of the person's own Cache imported: its first line is the title, its other own lines (properties, more text) are
/// kept as they are, its child blocks are the text, as written (one tab less).
EntryDoc parseLsBlock(LsBlock b, {required String when, required String notebook}) {
  final end = _ownEnd(b);
  final own = [for (final l in b.lines.sublist(1, end)) l.replaceAll('\n', '')];
  final props = lsProps(own);
  final title = b.lines.first.replaceAll('\n', '').replaceFirst(RegExp(r'^-\s?'), '');
  return EntryDoc(
    id: props['cache-id'] ?? '',
    notebook: notebook,
    when: when,
    title: title.trim().isEmpty ? null : title,
    body: [for (final l in b.lines.sublist(end)) l.replaceAll('\n', '').replaceFirst('\t', '')].join('\n').trimRight(),
    private: lsPrivate(props),
    extra: [for (final l in own) if (!RegExp(r'^\s+cache-id::').hasMatch(l)) l],
  );
}

/// An imported block written back (see [parseLsBlock]).
String renderLsBlock(EntryDoc d) {
  final b = StringBuffer('- ${d.title ?? ''}\n');
  for (final l in d.extra) {
    b.writeln(l);
  }
  b.writeln('  cache-id:: ${d.id}');
  final body = d.body.replaceAll('\r\n', '\n').trimRight();
  if (body.isNotEmpty) {
    for (final l in body.split('\n')) {
      b.writeln('\t$l');
    }
  }
  return b.toString();
}

/// Logseq property lines Cache stops syncing: the `cache-id::` line becomes `cachesync:: off` (with the same indent).
List<String> lsReleased(List<String> lines) {
  final hasOff = lines.any((l) => RegExp('^\\s*$kSyncOffProp::').hasMatch(l));
  final out = <String>[];
  for (final l in lines) {
    final m = RegExp(r'^(\s*)cache-id::').firstMatch(l);
    if (m != null) {
      if (!hasOff) out.add('${m.group(1)}$kSyncOffProp:: off${l.endsWith('\n') ? '\n' : ''}');
    } else if (RegExp('^(\\s*)$kSyncOffProp::').firstMatch(l) case final o?) {
      out.add('${o.group(1)}$kSyncOffProp:: off${l.endsWith('\n') ? '\n' : ''}');
    } else {
      out.add(l);
    }
  }
  return out;
}

List<String> _keepEnds(String text) => RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text).map((m) => m.group(0)!).toList();

/// An imported Logseq page Cache stops syncing: `cache-id::` becomes `cachesync:: off`; the rest byte for byte.
String lsPageReleased(String text) {
  final p = splitPage(text);
  return lsReleased(_keepEnds(p.head)).join() + p.blocks.map((b) => b.text).join();
}

/// An imported Logseq block Cache stops syncing (see [lsPageReleased]).
String lsBlockReleased(LsBlock b) {
  final end = _ownEnd(b);
  return [...lsReleased(b.lines.sublist(0, end)), ...b.lines.sublist(end)].join();
}

/// The lines of [text] as an [LsBlock] holds them (with their line ends).
LsBlock lsBlockOf(String text) => LsBlock(_keepEnds(text));

/// The `cache-id::` among a page's properties.
String? lsPageId(String text) => lsProps(_lines(splitPage(text).head))['cache-id'];
