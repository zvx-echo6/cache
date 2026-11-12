import 'dart:convert';

import 'field_sync.dart';
import 'folder.dart';

/// The format of the internal notebooks share (notebook sync between a person's own devices), version 2.
///
/// Version 1 (every build up to 1.0.30) keeps a notebook in a folder named after it, and nothing in the share says which notebook
/// a folder is, so two devices that each made "Hikes" gave it two ids. Version 2 keeps each notebook in `<id>/`:
///
/// - `<id>/notebook.json`: the notebook's record ([NbRecord]): `{"format": 2, "id", "name", "name_at", ...}`, or a tombstone
///   `{"format": 2, "id", "deleted": true, "at"}` when it was deleted, or an alias `{"format": 2, "id", "alias_of", "at"}` when
///   two devices' ids for one notebook were settled on the lower (the entries already in `<id>/` stay there and belong to it);
/// - `<id>/<entry>.cnote`: one entry per file, in the same text format as before (not `.md`, so a build that only knows version 1
///   never takes them for its notes);
/// - `<id>/photos/cache-<photo>.jpg`.
///
/// A rename changes the record's name only; the folder never moves. A device that finds a record with a format it does not know
/// stops syncing notebooks ([NotebookFormatTooNew]).
const int kShareFormat = 2;

/// An entry's file in the share (version 2).
const String kNoteExt = '.cnote';

/// A record's file name.
const String kRecordFile = 'notebook.json';

/// What Sharing says under Notebooks when the share has a newer format than this version reads.
const String kUpdateNeededNote = 'Update Cache on this device to keep syncing notebooks';

/// How long the tombstone of a deleted notebook stays in the share.
const int kTombstoneDays = 30;

/// A notebook record in the share has a format this version does not know: notebooks are not synced until Cache is updated.
class NotebookFormatTooNew implements Exception {
  const NotebookFormatTooNew(this.format);

  final int format;

  @override
  String toString() => 'The notebooks share is in format $format; this version reads up to $kShareFormat';
}

/// What a notebook's folder says about it.
enum RecordKind { live, tombstone, alias }

/// A `notebook.json` of format 2.
class NbRecord {
  const NbRecord._(this.kind, this.id, this.at, this.body);

  /// A notebook that is there: [body] holds `name`, `template`, `def`, `private`, `map`, `saved_places`, `props` (all but the name
  /// are as the notebook was when it was first written here; only the name changes later).
  factory NbRecord.live(String id, {required int nameAt, required Map<String, dynamic> body}) => NbRecord._(RecordKind.live, id, nameAt, body);

  factory NbRecord.tombstone(String id, int at) => NbRecord._(RecordKind.tombstone, id, at, const {});

  factory NbRecord.alias(String id, String aliasOf, int at) => NbRecord._(RecordKind.alias, id, at, {'alias_of': aliasOf});

  final RecordKind kind;
  final String id;

  /// The time of the last rename ([RecordKind.live]), of the delete (tombstone), of the merge (alias): milliseconds since the epoch.
  final int at;
  final Map<String, dynamic> body;

  String get name => '${body['name'] ?? ''}';

  /// The notebook's map icon and colour, each with the time it was last set: they are changed independently, like the name (null:
  /// none, or cleared).
  String? get icon => body['icon'] as String?;
  int get iconAt => (body['icon_at'] as num?)?.toInt() ?? 0;
  String? get color => body['color'] as String?;
  int get colorAt => (body['color_at'] as num?)?.toInt() ?? 0;
  String? get aliasOf => kind == RecordKind.alias ? body['alias_of'] as String? : null;

  Map<String, dynamic> toJson() => switch (kind) {
        RecordKind.live => {'format': kShareFormat, 'id': id, 'name_at': at, ...body},
        RecordKind.tombstone => {'format': kShareFormat, 'id': id, 'deleted': true, 'at': at},
        RecordKind.alias => {'format': kShareFormat, 'id': id, 'alias_of': aliasOf, 'at': at},
      };

  /// The text a record is stored as: the same for the same record, whichever device writes it.
  String get text => '${const JsonEncoder.withIndent(' ').convert(_sorted(toJson()))}\n';

  static Object? _sorted(Object? v) => v is Map ? {for (final k in (v.keys.map((k) => '$k').toList()..sort())) k: _sorted(v[k])} : (v is List ? [for (final x in v) _sorted(x)] : v);

  static final RegExp _validId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  /// The record in [text]; null when it is not one. Throws [NotebookFormatTooNew] for a format above [kShareFormat].
  static NbRecord? parse(String? text) {
    if (text == null) return null;
    final Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;
    final f = j['format'];
    if (f is! num) return null;
    if (f > kShareFormat) throw NotebookFormatTooNew(f.toInt());
    final id = j['id'];
    if (id is! String || !_validId.hasMatch(id)) return null;
    if (j['deleted'] == true) return NbRecord.tombstone(id, (j['at'] as num?)?.toInt() ?? 0);
    if (j['alias_of'] is String && _validId.hasMatch(j['alias_of'] as String)) return NbRecord.alias(id, j['alias_of'] as String, (j['at'] as num?)?.toInt() ?? 0);
    final body = {for (final e in j.entries) if (e.key != 'format' && e.key != 'id' && e.key != 'name_at') '${e.key}': e.value};
    if (body['name'] is! String) return null;
    return NbRecord.live(id, nameAt: (j['name_at'] as num?)?.toInt() ?? 0, body: body);
  }

  /// The one record that two devices' writes of one notebook's file come to: a tombstone beats everything (a delete is on purpose),
  /// an alias beats a live record (a merge is not undone), and among live records each property is the later writer's.
  ///
  /// Newer builds add properties as `<key>`/`<key>_at` pairs; this keeps them, so older builds never drop them. Every such pair that
  /// any live record has (the icon and the colour among them) goes the way of the later `_at`, each on its own (a rename on one device
  /// and a colour on another both stay). A tie on the time goes to the greater value (null least), so every device picks the same. A
  /// key with no `_at` that the best record lacks is taken from the record with the latest name.
  static NbRecord? merge(Iterable<NbRecord> all) {
    final best = _mergeKinds(all);
    if (best == null || best.kind != RecordKind.live) return best;
    final lives = [for (final r in all) if (r.kind == RecordKind.live) r];
    if (lives.length < 2) return best;
    final body = {...best.body};
    final pairs = <String>{
      'icon',
      'color',
      for (final r in lives)
        for (final k in r.body.keys)
          if (k.endsWith('_at') && k.length > 3 && k != 'fields_at') k.substring(0, k.length - 3),
    };
    String val(NbRecord r, String k) {
      final v = r.body[k];
      return v == null ? '' : (v is String ? v : jsonEncode(_sorted(v)));
    }

    int at(NbRecord r, String k) => (r.body['${k}_at'] as num?)?.toInt() ?? 0;
    for (final key in pairs) {
      var w = lives.first;
      for (final r in lives.skip(1)) {
        final c = at(r, key).compareTo(at(w, key));
        if (c > 0 || (c == 0 && val(r, key).compareTo(val(w, key)) > 0)) w = r;
      }
      if (w.body.containsKey(key)) {
        body[key] = w.body[key];
      } else {
        body.remove(key);
      }
      if (w.body.containsKey('${key}_at')) {
        body['${key}_at'] = w.body['${key}_at'];
      } else {
        body.remove('${key}_at');
      }
    }
    // The fields are merged one by one (each property of each field by its own time); `fields_at` is the latest of those times, so a
    // build that knows nothing of fields still takes the later list whole.
    if (lives.any((r) => r.body['fields'] is List)) {
      final fields = mergeFieldLists([for (final r in lives) r.body['fields']]);
      body['fields'] = fields;
      body['fields_at'] = fieldsAt(fields);
    }
    // The entries deleted (by id, with the time): the union of what the records say, a delete is never undone.
    if (lives.any((r) => r.body['gone'] is Map)) {
      final gone = <String, int>{};
      for (final r in lives) {
        final g = r.body['gone'];
        if (g is! Map) continue;
        for (final e in g.entries) {
          final at = (e.value as num?)?.toInt() ?? 0;
          if (at >= (gone['${e.key}'] ?? -1)) gone['${e.key}'] = at;
        }
      }
      body['gone'] = gone;
    }
    // What no pair decides: whatever a record has and the best one lacks, from the latest name first.
    final taken = {for (final k in pairs) ...[k, '${k}_at'], 'fields', 'fields_at', 'gone'};
    final byName = [...lives]..sort((a, b) => b.at != a.at ? b.at.compareTo(a.at) : b.text.compareTo(a.text));
    for (final r in byName) {
      for (final e in r.body.entries) {
        if (!taken.contains(e.key) && !body.containsKey(e.key)) body[e.key] = e.value;
      }
    }
    return NbRecord.live(best.id, nameAt: best.at, body: body);
  }

  static NbRecord? _mergeKinds(Iterable<NbRecord> all) {
    NbRecord? best;
    int rank(NbRecord r) => switch (r.kind) { RecordKind.tombstone => 2, RecordKind.alias => 1, RecordKind.live => 0 };
    for (final r in all) {
      if (best == null) {
        best = r;
        continue;
      }
      final a = rank(r) - rank(best);
      final b = a != 0 ? a : (r.at - best.at != 0 ? (r.at - best.at).sign : r.text.compareTo(best.text).sign);
      if (b > 0) best = r;
    }
    return best;
  }
}

/// One top-level folder of the share, as far as notebooks are concerned: its record files.
class ShareDir {
  ShareDir(this.dir);

  final String dir;

  /// The record as the file has it, and the copies sync kept when two devices wrote it at once.
  NbRecord? main;
  String? mainText;
  final List<String> copyPaths = [];
  final List<NbRecord> copies = [];

  NbRecord? get merged => NbRecord.merge([?main, ...copies]);
}

/// Reads every `<dir>/notebook.json` (and the conflict copies of it) of the share. Throws [NotebookFormatTooNew] when one says a
/// newer format.
Future<Map<String, ShareDir>> readShareDirs(SyncFolder folder) async {
  final copy = RegExp(r'^([^/]+)/notebook \(conflict, .*\)\.json$');
  final out = <String, ShareDir>{};
  for (final f in await folder.list('')) {
    final String dir;
    final bool isCopy;
    if (RegExp('^[^/]+/$kRecordFile\$').hasMatch(f.path)) {
      dir = f.path.substring(0, f.path.indexOf('/'));
      isCopy = false;
    } else if (copy.firstMatch(f.path) case final m?) {
      dir = m.group(1)!;
      isCopy = true;
    } else {
      continue;
    }
    final text = await folder.readText(f.path);
    final rec = NbRecord.parse(text);
    final d = out.putIfAbsent(dir, () => ShareDir(dir));
    if (isCopy) {
      d.copyPaths.add(f.path);
      if (rec != null) d.copies.add(rec);
    } else {
      d.main = rec;
      d.mainText = text;
    }
  }
  return out;
}

/// Whether the share still has version 1 folders: a top-level folder with notes in it and no record.
Future<List<String>> legacyFiles(SyncFolder folder, {Set<String>? v2Dirs}) async {
  final dirs = v2Dirs ?? (await readShareDirs(folder)).keys.toSet();
  return [
    for (final f in await folder.list(''))
      if (f.path.contains('/') && !dirs.contains(f.path.substring(0, f.path.indexOf('/'))) && _isLegacyPath(f.path)) f.path,
  ];
}

bool _isLegacyPath(String path) {
  final top = path.substring(0, path.indexOf('/'));
  if (top == 'Conflicts') return false;
  if (top == 'photos') return path.endsWith('.jpg');
  return path.endsWith('.md');
}
