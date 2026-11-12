import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../files.dart';
import 'share_format.dart';
import '../notebook_model.dart';
import '../notebook_state.dart';
import 'folder.dart';
import 'field_sync.dart';
import 'formats.dart';
import 'merge.dart';
import '../../platform/app_log.dart';

/// Where notebooks are kept outside Cache:
/// - [obsidian]: one Markdown file per entry, two-way;
/// - [logseq]: one block per entry on its day's journal page of a classic (file-based) Logseq graph, two-way;
/// - [logseqExport]: the same blocks for Logseq 2.x, which imports Markdown: written, never read back;
/// - [share]: Cache's own folder that notebook sync keeps the same on the linked devices, two-way, in the Obsidian format.
enum SyncKind { obsidian, logseq, logseqExport, share }

/// What needs a person's decision.
enum ConflictKind { bothChanged, removedOutside, unreadable }

class SyncConflict {
  const SyncConflict({required this.entryId, required this.kind, required this.title, required this.path, this.cacheText, this.fileText});

  final String entryId;
  final ConflictKind kind;
  final String title;
  final String path;
  final String? cacheText;
  final String? fileText;

  Map<String, dynamic> toJson() => {'entry': entryId, 'kind': kind.name, 'title': title, 'path': path, 'cache': ?cacheText, 'file': ?fileText};

  static SyncConflict fromJson(Map j) => SyncConflict(
        entryId: '${j['entry']}',
        kind: ConflictKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => ConflictKind.bothChanged),
        title: '${j['title'] ?? ''}',
        path: '${j['path'] ?? ''}',
        cacheText: j['cache'] as String?,
        fileText: j['file'] as String?,
      );
}

/// What one run did.
class SyncReport {
  int written = 0;
  int read = 0;
  int deleted = 0;

  /// Entries changed in both places whose changes were merged (the person is told, not asked).
  final List<String> merged = [];
  int conflicts = 0;

  /// Notes imported by their tag in this run (their titles), and the notebooks they went to.
  final List<String> imported = [];
  final Set<String> importedBooks = {};

  /// Tagged notes Cache could not import (it could not write its id into them: a read-only folder).
  int notAdded = 0;

  /// Imported notes whose entry was deleted in Cache: their id was taken out of them.
  int released = 0;
}

/// One entry's state at the last sync: where it is, the text it had there, and the entry's rev then.
class _Item {
  _Item(this.path, this.base, this.rev, {this.extra = const [], this.imp, this.w0, this.uk = const [], this.ht = false});

  String path;
  String base;
  int rev;
  List<String> extra;

  /// A note the person made that Cache imported by its tag: `note` (Obsidian), `page` or `block` (Logseq); null for Cache's own.
  final String? imp;

  /// The time Cache gave an imported note (its own date and time, or the import's).
  final String? w0;

  /// An imported Obsidian note's property names from before the import: kept as they are, never read as Cache's.
  final List<String> uk;

  /// An imported Obsidian note had a `title` property: it is always written (else only when it is not the file's name).
  final bool ht;

  Map<String, dynamic> toJson() => {
        'path': path, 'base': base, 'rev': rev, if (extra.isNotEmpty) 'extra': extra, if (imp != null) 'imp': imp, if (w0 != null) 'w0': w0, if (uk.isNotEmpty) 'uk': uk,
        if (ht) 'ht': true,
      };

  static _Item fromJson(Map j) => _Item('${j['path']}', '${j['base']}', (j['rev'] as num?)?.toInt() ?? 0,
      extra: [for (final l in (j['extra'] as List? ?? const [])) '$l'], imp: j['imp'] as String?, w0: j['w0'] as String?, uk: [for (final k in (j['uk'] as List? ?? const [])) '$k'], ht: j['ht'] == true);
}

/// A note the person made with the import tag and no Cache id, found by the scan.
class _Cand {
  _Cand(this.kind, this.path, this.text, this.notebook, {this.private = false});

  /// `note`, `page` or `block` (see [_Item.imp]).
  final String kind;
  final String path;

  /// The file (note, page) or the block, as found.
  final String text;

  /// The notebook its `#cachesync/<notebook>` names; null for the plain tag.
  final String? notebook;
  final bool private;
}

/// The notebook a note with the plain import tag goes to when there is no Journal (the Journal is Cache's default notebook).
const String kImportFallbackNotebook = 'Notes';

/// One entry as the folder has it now.
class _Unit {
  _Unit(this.path, this.text, this.doc);

  final String path;
  final String text;
  final EntryDoc doc;
}

/// The two-way sync of the notebooks with one folder, with the rules of the notebook spec (5.4, 6.3): what changed on one side
/// since the last sync goes to the other; changed on both sides, the changes are merged word by word and the person is told;
/// only when both changed the same words is the person asked. Cache creates, changes or deletes only files and blocks that
/// carry its `cache_id` and the photos it wrote.
///
/// Obsidian and Logseq work on Cache's own files only, always (owner, 2026-10-31): a file or block Cache wrote (it carries
/// Cache's id and Cache has a record of it) is two-way; a note made in Obsidian or Logseq is never read, even inside Cache's
/// folder; and a Cache file deleted there is written back, because Cache is the source of truth (the entry is not deleted).
/// Notebook sync between the person's devices ([SyncKind.share]) keeps the full two-way rules.
///
/// Import by tag (1.0.30, owner-approved): a note the person made with the import tag ([importTag], `#cachesync`) and no Cache
/// id is imported once, into the notebook `#cachesync/<notebook>` names (made when there is none) or the Journal, and Cache
/// writes its id into it. From then on the id decides, as for Cache's own files: the tag is never read again. When its entry is
/// deleted in Cache, or the person chooses "Stop syncing this note" ([stopSyncing]), the id goes out of the note and
/// `cachesync: off` takes its place, so it is never imported or written again; the note's text stays as it is.
class NotebookSync {
  NotebookSync({
    required this.notebook,
    required this.kind,
    required this.folder,
    required this.stateFile,
    this.includePrivate = true,
    this.privateBooks = const {},
    this.logseqConfig,
    this.importTag = kDefaultImportTag,
    this.eligible,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// Notebook sync keeps the notebooks in `<id>/` folders (format 2, see share_format.dart).
  bool get idLayout => kind == SyncKind.share;

  /// The notebooks that existed at the upgrade (local when this device first started a version with format 2, or made from a format 1
  /// folder when converting): the only ones whose exact name settles which notebook they are. After that ids are the only identity,
  /// so two notebooks made with one name stay two. Shared with, and saved by, the connections.
  final Set<String>? eligible;

  /// The name each notebook folder of the share has (after a run), for listing a notebook that is only on a linked device.
  Map<String, String> dirNames = {};

  /// The tag that imports a note (Obsidian and two-way Logseq).
  final String importTag;

  final NotebookState notebook;
  final SyncKind kind;
  final SyncFolder folder;
  final File stateFile;

  /// Private items go to the folder (Obsidian and Logseq: yes; notebook sync: only when the person chose to include them).
  final bool includePrivate;

  /// Private notebooks that go to the folder anyway (their "Include in sync and sharing").
  final Set<String> privateBooks;

  /// A Logseq graph's `logseq/config.edn` (read once when it is connected).
  final ({String format, String dir, bool org})? logseqConfig;
  final DateTime Function() _now;

  Map<String, _Item> _items = {};
  Map<String, Map<String, String>> _props = {};

  /// What this device last applied of each notebook's fields (see field_sync.dart), by notebook id. A notebook without one has not met
  /// its record's `fields` yet: that is the migration.
  Map<String, FieldSnap> _fieldSnap = {};
  List<SyncConflict> _conflicts = [];
  final Set<String> _ignored = {};

  /// Entries the person stopped syncing with this folder: kept in Cache, never written here again.
  final Set<String> _stopped = {};

  /// Format 2: what each notebook's record said when it was last synced here (its name and when it got it), by notebook id.
  Map<String, ({String name, int at, String? icon, int iconAt, String? color, int colorAt})> _snap = {};

  /// Format 2: the notebook each folder of the share holds entries of (an alias points to the notebook it was merged into), the
  /// folders that are tombstones, and the notebooks they stand for.
  Map<String, String> _dirNb = {};
  final Set<String> _tombDirs = {};
  final Set<String> _tombBooks = {};

  /// Entries read before one of their photos had arrived (format 2): read again next time.
  final Set<String> _photoWait = {};

  /// Format 2: each notebook's definition as it was when it was last synced here, by id (a change since is a change made here).
  Map<String, String> _bookSnap = {};

  /// Format 2: notebooks kept although a tombstone came (changed here since, or the delete is not applied): their entries are
  /// written back, not deleted.
  final Set<String> _keepBooks = {};

  /// Notebook sync: ids of the entries of notebooks that are not in the share (private, not included). A file that carries one of
  /// them is never read, moved or given another private flag: those notebooks are never touched by the share.
  Set<String> _outIds = {};


  List<SyncConflict> get conflicts => List.unmodifiable(_conflicts);

  bool get _logseq => kind == SyncKind.logseq || kind == SyncKind.logseqExport;

  /// Obsidian and Logseq: only Cache's own files and blocks are synced (see the class comment).
  bool get _ownFilesOnly => kind != SyncKind.share;
  String get _attachments => _logseq ? 'assets' : (kind == SyncKind.share ? 'photos' : 'attachments');
  String get _journals => logseqConfig?.dir ?? 'journals';
  String get _format => logseqConfig?.format ?? 'yyyy_MM_dd';

  // ---- state ----

  Future<void> _load() async {
    try {
      if (!await stateFile.exists()) return;
      final j = jsonDecode(await stateFile.readAsString()) as Map;
      _items = {for (final e in (j['items'] as Map? ?? const {}).entries) '${e.key}': _Item.fromJson(e.value as Map)};
      _props = {for (final e in (j['props'] as Map? ?? const {}).entries) '${e.key}': (e.value as Map).cast<String, String>()};
      _conflicts = [for (final c in (j['conflicts'] as List? ?? const [])) SyncConflict.fromJson(c as Map)];
      _ignored
        ..clear()
        ..addAll([for (final x in (j['ignored'] as List? ?? const [])) '$x']);
      _stopped
        ..clear()
        ..addAll([for (final x in (j['stopped'] as List? ?? const [])) '$x']);
      _fieldSnap = {for (final e in (j['fields'] as Map? ?? const {}).entries) '${e.key}': FieldSnap.fromJson(e.value as Map)};
      _bookSnap = {for (final e in (j['book_snap'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
      _snap = {
        for (final e in (j['snap'] as Map? ?? const {}).entries)
          '${e.key}': (
            name: '${(e.value as Map)['name']}',
            at: ((e.value as Map)['at'] as num?)?.toInt() ?? 0,
            icon: (e.value as Map)['icon'] as String?,
            iconAt: ((e.value as Map)['icon_at'] as num?)?.toInt() ?? 0,
            color: (e.value as Map)['color'] as String?,
            colorAt: ((e.value as Map)['color_at'] as num?)?.toInt() ?? 0,
          ),
      };
    } catch (e) {
      logError('Notebook sync: state unreadable', error: e);
    }
  }

  Future<void> _save() async {
    await stateFile.parent.create(recursive: true);
    await writeStringAtomic(
      stateFile,
      jsonEncode({
        'items': {for (final e in _items.entries) e.key: e.value.toJson()},
        'props': _props,
        'conflicts': [for (final c in _conflicts) c.toJson()],
        'ignored': [..._ignored],
        if (_stopped.isNotEmpty) 'stopped': [..._stopped],
        if (_bookSnap.isNotEmpty) 'book_snap': _bookSnap,
        if (_fieldSnap.isNotEmpty) 'fields': {for (final e in _fieldSnap.entries) e.key: e.value.toJson()},
        if (_snap.isNotEmpty) 'snap': {
          for (final e in _snap.entries)
            e.key: {'name': e.value.name, 'at': e.value.at, 'icon': e.value.icon, 'icon_at': e.value.iconAt, 'color': e.value.color, 'color_at': e.value.colorAt},
        },
      }),
    );
  }

  // ---- entries as documents ----

  /// The field property names of a notebook: fixed per field id the first time a field is written (a label rename keeps
  /// the name, so old files stay readable).
  Map<String, String> _fieldProps(Notebook n) {
    final m = _props.putIfAbsent(n.id, () => {});
    for (final f in n.def.fields) {
      final fid = f.fid;
      if (fid == null || m.containsKey(fid)) continue;
      m[fid] = propName(f.label, taken: m.values);
    }
    return m;
  }

  /// The property names of a notebook's fields and the types they have. [stale]: the file is one this device wrote before it took
  /// the shared names, and has not written again; its keys are the ones this device used then, so an old name wins over a current one
  /// (a name this device used for one field may be another field's now).
  Map<String, FieldType> _propTypes(Notebook n, {bool stale = false}) {
    final m = _fieldProps(n);
    final out = {for (final f in n.def.fields) if (f.fid != null && m[f.fid] != null) m[f.fid]!: f.type};
    for (final e in _aliases(n).entries) {
      final f = n.def.field(e.value);
      if (f == null) continue;
      if (stale) {
        out[e.key] = f.type;
      } else {
        out.putIfAbsent(e.key, () => f.type);
      }
    }
    return out;
  }

  /// The old property names of a notebook's fields (name to local field id), kept from the migration.
  Map<String, String> _aliases(Notebook n) => _fieldSnap[n.id]?.pnames ?? const {};

  EntryDoc _docOf(Notebook n, NbEntry e) {
    final m = _fieldProps(n);
    return EntryDoc(
      id: e.id,
      notebook: n.name,
      when: wallTime(e.occurredAt),
      title: e.title,
      body: e.body ?? '',
      place: e.place == null ? null : NbPlace(lat: e.place!.lat, lon: e.place!.lon, label: e.place!.label),
      photos: [for (final p in e.photos) p.id],
      fields: {for (final f in n.def.fields) if (f.fid != null && e.values.containsKey(f.fid) && m[f.fid] != null) m[f.fid]!: e.values[f.fid]},
      private: e.private,
      extra: _items[e.id]?.extra ?? const [],
      // Only the Cache-to-Cache share carries them: a person's own Obsidian vault or Logseq graph gets no Cache properties it
      // did not have.
      props: kind != SyncKind.share || e.props.isEmpty ? null : {for (final k in const ['color', 'icon', 'on_map']) if (e.props[k] != null) k: e.props[k]},
    );
  }

  String _render(EntryDoc d) => _logseq ? renderLogseq(d) : renderObsidian(d, withNotebook: !idLayout);

  static String _baseName(String path) {
    final n = path.split('/').last;
    return n.endsWith('.md') ? n.substring(0, n.length - 3) : n;
  }

  /// Entry [id] as its file or block holds it: an imported note in its own shape, else Cache's.
  String _renderFor(String id, EntryDoc d) {
    final it = _items[id];
    return switch (it?.imp) {
      'note' => renderObsidian(d, imported: true, skip: it!.uk.toSet(), titleDefault: it.ht ? null : _baseName(it.path), whenDefault: it.w0),
      'page' => renderLsPage(d, pageTitle: lsPageTitle(it!.path)),
      'block' => renderLsBlock(d),
      _ => _render(d),
    };
  }

  /// [text] (entry [id]'s file or block) read back; [when] is the entry's time now (an imported note that does not say its time
  /// keeps it).
  EntryDoc? _parseAs(String id, String text, Notebook book, {required String when}) {
    final it = _items[id];
    switch (it?.imp) {
      case 'note':
        return parseObsidian(text, fallbackId: id, fallbackNotebook: book.name, fieldProps: _propTypes(book), fallbackWhen: when, userKeys: it!.uk.toSet(), fallbackTitle: _baseName(it.path));
      case 'page':
        return parseLsPage(text, pageTitle: lsPageTitle(it!.path), when: when, notebook: book.name);
      case 'block':
        return parseLsBlock(splitPage(text).blocks.firstOrNull ?? lsBlockOf(text), when: when, notebook: book.name);
    }
    return _logseq
        ? parseLogseq(splitPage(text).blocks.firstOrNull ?? LsBlock([text]), day: when.substring(0, 10), fallbackNotebook: book.name, fieldProps: _propTypes(book))
        : parseObsidian(text, fallbackId: id, fallbackNotebook: book.name, fieldProps: _propTypes(book, stale: it?.rev == -1));
  }

  /// Records entry [id]'s state, keeping what it is (imported or Cache's own).
  void _rec(String id, String path, String base, int rev, {List<String>? extra}) {
    final old = _items[id];
    _items[id] = _Item(path, base, rev, extra: extra ?? old?.extra ?? const [], imp: old?.imp, w0: old?.w0, uk: old?.uk ?? const [], ht: old?.ht ?? false);
  }

  String get _nowWall => wallTime(_now().toIso8601String());

  bool _included(Notebook n, NbEntry e) => !e.draft && (includePrivate || !e.private || privateBooks.contains(n.id));

  // ---- the folder ----

  Future<Map<String, _Unit>> _scan(Map<String, Notebook> byName, List<_Unit> newOutside, List<SyncConflict> unreadable,
      {Map<String, (Notebook, NbEntry)> cache = const {}, List<_Cand>? candidates}) async {
    final out = <String, _Unit>{};
    if (kind == SyncKind.logseqExport) return out;
    // An imported note's notebook and time are its entry's (the note does not say them).
    String nbOf(String id) => cache[id]?.$1.name ?? '';
    String whenOf(String id) => cache[id] == null ? _nowWall : wallTime(cache[id]!.$2.occurredAt);
    final importing = _ownFilesOnly && candidates != null;
    if (idLayout) return _scanIds(out, newOutside, unreadable, cache);
    if (_logseq) {
      for (final dir in [_journals, 'pages']) {
        for (final f in await folder.list(dir)) {
          if (!f.path.endsWith('.md')) continue;
          final text = await folder.readText(f.path);
          if (text == null) continue;
          final day = dayOfJournal(f.path.split('/').last, format: _format);
          final page = splitPage(text);
          final headId = lsPageId(text);
          if (headId != null && _items[headId]?.imp == 'page') {
            out.putIfAbsent(headId, () => _Unit(f.path, text, parseLsPage(text, pageTitle: lsPageTitle(f.path), when: whenOf(headId), notebook: nbOf(headId))));
            continue;
          }
          if (importing && dir == 'pages' && headId == null && !page.head.trimLeft().startsWith('---') && !page.blocks.any((b) => b.cacheId != null)) {
            final head = lsProps(page.head.split('\n'));
            final tag = lsSyncOff(head) ? null : importTagIn(lsTagValues(head['tags']), importTag);
            if (tag != null) {
              candidates.add(_Cand('page', f.path, text, tag.notebook, private: lsPrivate(head)));
              continue;
            }
          }
          for (final b in page.blocks) {
            final id = b.cacheId;
            if (id != null && _items[id]?.imp == 'block') {
              out.putIfAbsent(id, () => _Unit(f.path, b.text, parseLsBlock(b, when: whenOf(id), notebook: nbOf(id))));
              continue;
            }
            if (id == null && importing) {
              final bp = lsBlockProps(b);
              final tag = lsSyncOff(bp) ? null : importTagIn(lsBlockTags(b), importTag);
              if (tag != null) {
                candidates.add(_Cand('block', f.path, b.text, tag.notebook, private: lsPrivate(bp)));
                continue;
              }
            }
            final nbName = RegExp(r'^\s+notebook::\s*(.+)$', multiLine: true).firstMatch(b.text)?.group(1)?.trim();
            final book = nbName == null ? null : byName[nbName.replaceAll('"', '')];
            if (id == null && book == null) continue; // the person's own blocks
            final doc = parseLogseq(b, day: day ?? _now().toIso8601String().substring(0, 10), fallbackNotebook: book?.name ?? nbName ?? '', fieldProps: book == null ? const {} : _propTypes(book));
            final u = _Unit(f.path, b.text, doc);
            if (id == null) {
              newOutside.add(u);
            } else if (!out.containsKey(id)) {
              out[id] = u;
            }
          }
        }
      }
      return out;
    }
    void put(_Unit u) {
      final prev = out[u.doc.id];
      if (prev == null) {
        out[u.doc.id] = u;
      } else {
        // A duplicated file: the one Cache knows keeps the id; the other becomes a new entry.
        final keep = _items[u.doc.id]?.path == prev.path ? prev : u;
        final other = identical(keep, prev) ? u : prev;
        out[u.doc.id] = keep;
        newOutside.add(_Unit(other.path, other.text, EntryDoc(id: '', notebook: other.doc.notebook, when: other.doc.when, title: other.doc.title, body: other.doc.body, place: other.doc.place, photos: other.doc.photos, fields: other.doc.fields, private: other.doc.private, extra: other.doc.extra, props: other.doc.props)));
      }
    }

    for (final f in await folder.list('')) {
      if (!f.path.endsWith('.md') || f.path.startsWith('Conflicts/') || f.path.startsWith('.cache/')) continue;
      final text = await folder.readText(f.path);
      if (text == null) continue;
      final folderName = f.path.contains('/') ? f.path.substring(0, f.path.indexOf('/')) : '';
      final book = byName.values.where((n) => folderNameOf(n) == folderName).firstOrNull;
      final probe = parseObsidian(text, fallbackId: '', fallbackNotebook: book?.name ?? '', fieldProps: const {});
      if (probe == null) {
        final known = _items.entries.where((e) => e.value.path == f.path).firstOrNull;
        // A note that is not Cache's is never Cache's business, readable or not.
        if (_ownFilesOnly && known == null) continue;
        if (!_ignored.contains(f.path)) {
          unreadable.add(SyncConflict(entryId: known?.key ?? '', kind: ConflictKind.unreadable, title: f.path.split('/').last, path: f.path));
        }
        continue;
      }
      final it = probe.id.isEmpty ? null : _items[probe.id];
      if (it?.imp == 'note') {
        final c = cache[probe.id];
        final doc = parseObsidian(text,
            fallbackId: '', fallbackNotebook: nbOf(probe.id), fieldProps: c == null ? const {} : _propTypes(c.$1, stale: it?.rev == -1), fallbackWhen: whenOf(probe.id), userKeys: it!.uk.toSet(), fallbackTitle: _baseName(f.path))!;
        put(_Unit(f.path, text, doc));
        continue;
      }
      if (probe.id.isEmpty && _ownFilesOnly) {
        // The person's own note: imported when it has the import tag (and not `cachesync: off`), else never read.
        if (importing && kind == SyncKind.obsidian && !obsidianSyncOff(text)) {
          final tag = importTagIn(obsidianTags(text), importTag);
          if (tag != null) candidates.add(_Cand('note', f.path, text, tag.notebook, private: probe.private));
        }
        continue;
      }
      final owner = byName[probe.notebook] ?? book;
      final doc = parseObsidian(text, fallbackId: '', fallbackNotebook: owner?.name ?? '', fieldProps: owner == null ? const {} : _propTypes(owner))!;
      final u = _Unit(f.path, text, doc);
      if (doc.id.isEmpty) {
        if (owner != null) newOutside.add(u);
        continue;
      }
      put(u);
    }
    return out;
  }

  static String folderNameOf(Notebook n) => folderName(n.name);

  Future<String> _newPath(EntryDoc d, Notebook n) async {
    final dir = idLayout ? n.id : folderNameOf(n);
    final ext = idLayout ? kNoteExt : '.md';
    final base = noteFileName(d);
    var name = '$dir/$base$ext';
    var i = 2;
    while (await folder.exists(name) || _items.values.any((x) => x.path == name)) {
      name = '$dir/$base ${i++}$ext';
    }
    return name;
  }

  /// Where a notebook's photos are in the share: format 2 keeps them in the notebook's folder.
  String _photoDir(Notebook n) => idLayout ? '${n.id}/photos' : _attachments;

  Future<void> _copyPhotosOut(EntryDoc d, Notebook n) async {
    final ids = [...d.photos, for (final v in d.fields.values) if (v is List) ...v.whereType<String>()];
    for (final id in ids) {
      final path = '${_photoDir(n)}/cache-$id.jpg';
      if (await folder.exists(path)) continue;
      final f = await notebook.photoFile(id);
      if (await f.exists()) await folder.writeBytes(path, await f.readAsBytes());
    }
  }

  /// Writes [text] as entry [id]'s file or block; returns where it is.
  Future<String> _write(String id, EntryDoc d, Notebook n, String text) async {
    final it = _items[id];
    if (it?.imp == 'block') {
      // An imported block stays where the person wrote it.
      final cur = await folder.readText(it!.path) ?? '';
      final p = splitPage(cur);
      final at = p.blocks.indexWhere((b) => b.cacheId == id);
      final sep = cur.isEmpty || cur.endsWith('\n') ? '' : '\n';
      await folder.writeText(it.path, at >= 0 ? p.head + [for (var i = 0; i < p.blocks.length; i++) i == at ? text : p.blocks[i].text].join() : '$cur$sep$text');
      return it.path;
    }
    if (it?.imp == 'page') {
      await folder.writeText(it!.path, text);
      return it.path;
    }
    await _copyPhotosOut(d, n);
    if (!_logseq) {
      final path = _items[id]?.path ?? await _newPath(d, n);
      await folder.writeText(path, text);
      return path;
    }
    final page = '$_journals/${journalFileName(d.when.substring(0, 10), format: _format)}';
    final old = _items[id]?.path;
    if (old != null && old != page) await _removeBlock(old, id);
    final cur = await folder.readText(page) ?? '';
    final p = splitPage(cur);
    final at = p.blocks.indexWhere((b) => b.cacheId == id);
    final String next;
    if (at >= 0) {
      next = p.head + [for (var i = 0; i < p.blocks.length; i++) i == at ? text : p.blocks[i].text].join();
    } else {
      final sep = cur.isEmpty || cur.endsWith('\n') ? '' : '\n';
      next = '$cur$sep$text';
    }
    await folder.writeText(page, next);
    return page;
  }

  Future<void> _removeBlock(String page, String id) async {
    final cur = await folder.readText(page);
    if (cur == null) return;
    final p = splitPage(cur);
    if (!p.blocks.any((b) => b.cacheId == id)) return;
    await folder.writeText(page, p.head + [for (final b in p.blocks) if (b.cacheId != id) b.text].join());
  }

  Future<void> _deleteOutside(String id) async {
    final it = _items[id];
    if (it == null) return;
    if (_logseq) {
      await _removeBlock(it.path, id);
    } else {
      await folder.delete(it.path);
    }
  }

  /// Keeps the version not chosen in a conflict: `Conflicts/` (Obsidian), `pages/Cache conflicts.md` (Logseq).
  Future<void> _keepCopy(String title, String text) async {
    final stamp = _now().toIso8601String();
    if (_logseq) {
      const page = 'pages/Cache conflicts.md';
      final cur = await folder.readText(page) ?? '';
      final body = text.split('\n').where((l) => l.trim().isNotEmpty).map((l) => '\t$l').join('\n');
      await folder.writeText(page, '$cur${cur.isEmpty || cur.endsWith('\n') ? '' : '\n'}- ${stamp.substring(0, 16).replaceFirst('T', ' ')} $title\n$body\n');
      return;
    }
    final name = '${stamp.substring(0, 10)} ${stamp.substring(11, 13)}${stamp.substring(14, 16)} $title'.replaceAll(RegExp(r'[#|^:%\[\]/\\?*"<>]'), ' ').trim();
    await folder.writeText('Conflicts/$name.md', text);
  }

  // ---- reading into Cache ----

  Future<Notebook> _bookFor(EntryDoc d, Map<String, Notebook> byName) async {
    final have = byName[d.notebook];
    if (have != null) return have;
    final shared = await _sharedBook(d.notebook);
    final made = await _makeBook(id: shared?['id'] as String?, name: d.notebook, shared: shared);
    byName[made.name] = made;
    return made;
  }

  /// The icon and colour a record gives now (they change after the notebook was first shared) over the ones in its first definition.
  NotebookDef _withProps(NotebookDef d, Map<String, dynamic>? shared) {
    if (shared == null) return d;
    if (shared.containsKey('icon')) d = shared['icon'] is String ? d.copyWith(icon: shared['icon'] as String) : d.copyWith(clearIcon: true);
    if (shared.containsKey('color')) d = shared['color'] is String ? d.copyWith(color: shared['color'] as String) : d.copyWith(clearColor: true);
    return d;
  }

  /// A notebook made here the way another device made it: [shared] is its definition there (template, def, private, props).
  Future<Notebook> _makeBook({String? id, required String name, Map<String, dynamic>? shared}) async {
    var def = _withProps(shared?['def'] is Map ? NotebookDef.fromJson(_withoutFids(shared!['def'] as Map)).copyWith(name: name) : NotebookDef(name: name, fields: const [], sort: NotebookSort.recent), shared);
    // The record's `fields` (what every device agrees on now) over the definition it was first written with.
    final recFields = shared?['fields'] is List ? mergeFieldLists([shared!['fields']]) : null;
    if (recFields != null) {
      final plan = reconcileFields(notebookId: id ?? '', record: recFields, local: const [], snap: FieldSnap(), hasValues: (_) => false, now: _now().millisecondsSinceEpoch);
      def = def.copyWith(fields: plan.local);
    }
    final made = await notebook.saveNotebook(
      id: id,
      template: (shared?['template'] as String?) ?? 'notes',
      def: def,
      private: shared?['private'] == true,
      fromSync: recFields != null,
    );
    if (recFields != null) {
      final props = {for (final r in recFields) '${r['gid']}': '${r['pname']}'};
      _props[made.id] = {for (final f in made.def.fields) if (f.fid != null && f.gid != null && props[f.gid] != null) f.fid!: props[f.gid]!};
      _fieldSnap[made.id] = _snapOfFields(made, recFields);
      return made;
    }
    // The other device's property names, by label, so both write the same ones.
    final sharedProps = shared?['props'];
    final sharedFields = shared?['def'] is Map ? (shared!['def'] as Map)['fields'] as List? ?? const [] : const [];
    if (sharedProps is Map) {
      final byLabel = {for (final f in sharedFields) '${(f as Map)['label']}': sharedProps['${f['fid']}']};
      _props[made.id] = {
        for (final f in made.def.fields)
          if (f.fid != null && byLabel[f.label] is String) f.fid!: byLabel[f.label] as String,
      };
    }
    return made;
  }

  static Map _withoutFids(Map def) => {
        ...def,
        'fields': [for (final f in (def['fields'] as List? ?? const [])) if ((f as Map)['hidden'] != true) {...f}..remove('fid')],
      };

  Map<String, dynamic>? _sharedBooks;

  /// Format 2: the definition each live notebook folder gives, by exact notebook name (for this run).
  Map<String, Map<String, dynamic>> _recByName = {};

  Future<Map<String, dynamic>?> _sharedBook(String name) async {
    if (idLayout) return _recByName[name];
    if (_sharedBooks == null) {
      try {
        final t = await folder.readText('.cache/notebooks.json');
        final j = t == null ? null : jsonDecode(t);
        _sharedBooks = {for (final n in (j is Map ? j['notebooks'] as List? ?? const [] : const [])) '${(n as Map)['def']?['name']}': n};
      } catch (_) {
        _sharedBooks = {};
      }
    }
    final n = _sharedBooks![name];
    return n is Map ? n.cast<String, dynamic>() : null;
  }

  /// [d] into Cache as entry [id] (made or replaced); returns the entry as stored. Values that do not fit their field stay in
  /// the file as the person's own properties.
  Future<NbEntry> _apply(String id, EntryDoc d, Map<String, Notebook> byName, {String? text}) async {
    final known = byName.containsKey(d.notebook);
    var book = await _bookFor(d, byName);
    if (!known && text != null) {
      // The notebook was just made: read the fields again with its field names.
      final again = _parseAs(id, text, book, when: d.when);
      if (again != null) d = again;
    }
    if (book.savedPlaces == false && kind == SyncKind.share) {
      final shared = await _sharedBook(d.notebook);
      if (shared?['saved_places'] == true) book = await notebook.ensureSavedPlaces();
    }
    final existing = await notebook.entry(id);
    // An imported note keeps in Cache what its file does not hold (a Logseq page or block holds only its title and text).
    final keep = _items[id]?.imp != null && existing != null;
    final propToFid = {for (final e in _fieldProps(book).entries) e.value: e.key};
    final stale = _items[id]?.rev == -1;
    for (final e in _aliases(book).entries) {
      if (stale) {
        propToFid[e.key] = e.value;
      } else {
        propToFid.putIfAbsent(e.key, () => e.value);
      }
    }
    final values = <String, dynamic>{};
    final extra = [...d.extra];
    for (final e in d.fields.entries) {
      final fid = propToFid[e.key];
      final f = fid == null ? null : book.def.field(fid);
      final v = e.value;
      final ok = switch (f?.type) {
        FieldType.number => v is num,
        FieldType.yesNo => v is bool,
        FieldType.text || FieldType.choice => v is String || v is num || v is bool,
        FieldType.place => v is Map,
        FieldType.photo => v is List,
        null => false,
      };
      if (ok) {
        values[fid!] = f!.type == FieldType.text || f.type == FieldType.choice ? '$v' : v;
      } else if (v != null) {
        extra.add('${e.key}: ${yamlText('$v')}');
      }
    }
    final photoIds = [...d.photos, for (final v in values.values) if (v is List) ...v.whereType<String>()];
    for (final pid in photoIds) {
      final f = await notebook.photoFile(pid);
      if (await f.exists()) continue;
      var bytes = await folder.readBytes('${_photoDir(book)}/cache-$pid.jpg');
      if (bytes == null && idLayout) {
        // Photos written into the folder of an id merged into this notebook's.
        for (final e in _dirNb.entries) {
          if (e.value == book.id && e.key != book.id && bytes == null) bytes = await folder.readBytes('${e.key}/photos/cache-$pid.jpg');
        }
      }
      if (bytes != null) {
        await storePhotoBytes(pid, bytes);
      } else if (idLayout) {
        // The note came before its photo: it is read again on the next sync, until the photo is there too.
        _photoWait.add(id);
      }
    }
    final had = {for (final p in existing?.photos ?? const <NbPhoto>[]) p.id: p};
    final offset = offsetOf(existing?.occurredAt, now: _now());
    final place = d.place == null
        ? null
        : NbPlace(
            lat: d.place!.lat,
            lon: d.place!.lon,
            label: d.place!.label,
            key: existing?.place != null && existing!.place!.lat == d.place!.lat && existing.place!.lon == d.place!.lon ? existing.place!.key : existing?.place?.key,
          );
    final saved = await notebook.saveEntry(
      id: id,
      notebookId: book.id,
      occurredAt: existing != null && wallTime(existing.occurredAt) == d.when ? existing.occurredAt : withOffset(d.when, offset),
      title: (d.title ?? '').trim().isEmpty ? null : d.title!.trim(),
      body: d.body.trim().isEmpty ? null : d.body,
      values: keep ? {...existing.values, ...values} : values,
      place: place ?? (keep ? existing.place : null),
      photos: keep && d.photos.isEmpty
          ? existing.photos
          : [
              for (final pid in d.photos)
                if (had[pid] != null) had[pid]! else if (await (await notebook.photoFile(pid)).exists()) NbPhoto(id: pid),
            ],
      files: existing?.files ?? const [],
      private: kind == SyncKind.share ? d.private : (existing?.private ?? d.private),
      props: (kind == SyncKind.share ? d.props : null) ?? existing?.props ?? const {},
    );
    _rec(id, _items[id]?.path ?? '', '', saved.rev, extra: extra);
    return saved;
  }

  /// Writes a photo that came from the folder under its own id (the app stores it as a Notebook photo).
  Future<void> Function(String id, Uint8List bytes) storePhotoBytes = (id, bytes) async {};

  // ---- format 2: the notebooks' records ----

  static String _topDir(String path) => path.contains('/') ? path.substring(0, path.indexOf('/')) : '';

  EntryDoc _inBook(EntryDoc d, String name) => d.notebook == name
      ? d
      : EntryDoc(id: d.id, notebook: name, when: d.when, title: d.title, body: d.body, place: d.place, photos: d.photos, fields: d.fields, private: d.private, extra: d.extra, props: d.props);

  bool _inShare(Notebook n) => includePrivate || !n.private || privateBooks.contains(n.id);

  bool _eligible(String id) => eligible?.contains(id) ?? false;

  /// A name that no notebook here has: [name], else with the first characters of [id] added.
  String _freeName(String name, String id) {
    if (!notebook.nameTaken(name)) return name;
    final short = id.length < 6 ? id : id.substring(0, 6);
    var n = '$name ($short)';
    for (var i = 2; notebook.nameTaken(n); i++) {
      n = '$name ($short $i)';
    }
    return n;
  }

  /// A notebook's record body; [at] is the time its icon and colour (when it has them) are set.
  Map<String, dynamic> _recBody(Notebook n, {int at = 0}) =>
      {'name': n.name, if (n.def.icon != null) ...{'icon': n.def.icon, 'icon_at': at}, if (n.def.color != null) ...{'color': n.def.color, 'color_at': at}, if (_eligible(n.id)) 'legacy': true, 'template': n.template, 'def': n.def.toJson(), 'private': n.private, 'map': n.map, if (n.savedPlaces) 'saved_places': true, 'props': _fieldProps(n), ..._fieldsBody(n)};

  /// A record's `fields` for a notebook made or revived here: this device's fields as the list every device agrees on. Each keeps the
  /// id it has (one still without is given the one the first-share rule gives, which is the one a device that reads the record's
  /// definition comes to). Every property is at time 0, so any later change from any device wins.
  Map<String, dynamic> _fieldsBody(Notebook n) {
    final props = _fieldProps(n);
    final derived = fieldsOfSnapshot(n.id, [for (final f in n.def.fields) f.toJson()], props);
    final fields = <Map<String, dynamic>>[];
    for (var i = 0; i < derived.length && i < n.def.fields.length; i++) {
      final g = n.def.fields[i].gid;
      fields.add({...derived[i], if (g != null && g.isNotEmpty) 'gid': g});
    }
    return {'fields': fields, 'fields_at': 0};
  }

  /// What a device remembers of a notebook's fields after a sync: each field's state by gid, and their order.
  FieldSnap _snapOfFields(Notebook n, List<Map<String, dynamic>> record, {Map<String, String>? pnames, Set<String>? derived, bool pending = false}) {
    final recBy = {for (final r in record) '${r['gid']}': r};
    final state = <String, FieldState>{};
    for (final f in n.def.fields) {
      final g = f.gid;
      if (g == null || g.isEmpty) continue;
      state[g] = FieldState.ofLocal(f);
    }
    // a field the record has removed and this device has dropped stays known as removed, so it is not "removed here" again
    for (final r in record) {
      final g = '${r['gid']}';
      if (r['removed'] == true && !state.containsKey(g) && recBy.containsKey(g)) {
        state[g] = FieldState(name: '${r['name']}', type: '${r['type']}', removed: true);
      }
    }
    final prev = _fieldSnap[n.id];
    return FieldSnap(
      state: state,
      order: [for (final f in n.def.fields) if (!f.hidden && f.gid != null && f.gid!.isNotEmpty) f.gid!],
      pnames: pnames ?? prev?.pnames ?? const {},
      derived: derived ?? prev?.derived,
      forId: n.id,
      pending: pending,
    );
  }

  /// The fields of one notebook with a live record: the first time (the migration: this device's fields are matched to the record's
  /// and given their ids) and every time after (what changed here goes into the record, what the record says goes into the notebook).
  ///
  /// Safe to stop anywhere and run again. The migration is done again from the start when the device has not written down that it is
  /// done ([FieldSnap.pending], or nothing) or when the notebook's id changed since the ids were given by rule (they depend on it).
  /// Everything it works out is worked out from what is on disk (the store, the record, the names the files use now), so a run that
  /// stopped halfway leaves nothing the next one needs: the record is written first (any device's write of it is the same), then the
  /// notebook takes its ids (set once; the ones given by rule are written down as such first), and what this device remembers, with
  /// the names its files used before, comes last, together with the names the entries are written again under.
  Future<void> _syncFields(Notebook n, Map<String, NbRecord> recs, int now) async {
    final r = recs[n.id];
    if (r == null || r.kind != RecordKind.live) return;
    var book = notebook.notebook(n.id) ?? n;
    var record = r.body['fields'] is List ? mergeFieldLists([r.body['fields']]) : <Map<String, dynamic>>[];
    FieldSnap? snap = _fieldSnap[n.id];
    var local = book.def.fields;
    final propsBefore = {..._fieldProps(book)};
    final redo = snap == null || snap.pending || (snap.derived.isNotEmpty && snap.forId != n.id);
    final forget = snap?.derived ?? const <String>{};
    Set<String>? derived;
    final values = <String>{};
    for (final e in await notebook.entries(n.id)) {
      for (final v in e.values.entries) {
        if (v.value != null) values.add(v.key);
      }
    }
    if (redo) {
      // the ids given by rule for another id (or by a run that did not finish) are forgotten: the fields are matched again
      final asked = [for (final f in local) f.gid != null && forget.contains(f.gid) ? f.withoutGid() : f];
      final mig = migrateFields(
        notebookId: n.id,
        snapshot: (r.body['def'] is Map ? (r.body['def'] as Map)['fields'] as List? : null) ?? const [],
        snapProps: r.body['props'] is Map ? r.body['props'] as Map : const {},
        existing: r.body['fields'] is List ? record : null,
        local: asked,
        localProps: {...propsBefore},
        now: now,
      );
      record = mig.fields;
      for (final line in mig.log) {
        logInfo(line, job: 'notebook sync');
      }
      derived = {...mig.derived};
      local = [for (final f in asked) (f.gid == null || f.gid!.isEmpty) && mig.gids[f.fid] != null ? f.withGid(mig.gids[f.fid]!) : f];
      snap = FieldSnap(state: {for (final e in mig.baseline.entries) e.key: e.value}, order: mig.baselineOrder);
      // what this device added before the migration is its own from the start (not a change to carry)
      for (final f in local) {
        if (f.gid != null && f.gid!.isNotEmpty && snap.state[f.gid] == null) snap.state[f.gid!] = FieldState.ofLocal(f);
      }
      // The ids given by rule are written down (with the id they depend on) before the notebook takes them: a run that stops after
      // that is known, by the next one, to hold ids that are to be dropped if the notebook's id has changed.
      _fieldSnap[n.id] = FieldSnap(state: const {}, derived: {...derived, ...forget}, forId: n.id, pending: true, pnames: _fieldSnap[n.id]?.pnames ?? const {});
      await _save();
    }
    final plan = reconcileFields(
      notebookId: n.id,
      record: record,
      local: local,
      snap: snap,
      hasValues: values.contains,
      props: {...propsBefore},
      now: now,
    );
    for (final line in plan.log) {
      logInfo(line, job: 'notebook sync');
    }
    if (redo || plan.recordChanged) {
      final body = {...r.body, 'fields': plan.record, 'fields_at': fieldsAt(plan.record)};
      final rec = NbRecord.live(n.id, nameAt: r.at, body: body);
      if (rec.text != r.text) {
        await folder.writeText('${n.id}/$kRecordFile', rec.text);
        recs[n.id] = rec;
      }
    }
    if (!_sameFields(book.def.fields, plan.local)) {
      book = await notebook.saveNotebook(id: n.id, def: book.def.copyWith(fields: plan.local), fromSync: true);
    }
    // the names the files use, by the record's say; a field whose name changes keeps the old one to be read by, and its notes are
    // written again under the new one (every field, not only the ones that had no id: the names are compared with what is on disk)
    final aliases = {...?_fieldSnap[n.id]?.pnames};
    final m = _props.putIfAbsent(n.id, () => {});
    var renamed = false;
    for (final f in book.def.fields) {
      final g = f.gid;
      final np = g == null ? null : plan.pnames[g];
      if (f.fid == null || np == null) continue;
      final op = propsBefore[f.fid];
      if (op != null && op != np) {
        aliases[op] = f.fid!;
        renamed = true;
      }
      m[f.fid!] = np;
    }
    if (renamed) {
      for (final e in await notebook.entries(n.id)) {
        _items[e.id]?.rev = -1;
      }
      logInfo('Notebook fields: the name some fields use in the notes changed here; the notes are written again under the shared names', job: 'notebook sync');
    }
    _fieldSnap[n.id] = _snapOfFields(book, plan.record, pnames: aliases, derived: redo ? (derived ?? <String>{}).intersection({for (final f in book.def.fields) ?f.gid}) : null);
  }

  static bool _sameFields(List<LogField> a, List<LogField> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.fid != y.fid || x.gid != y.gid || x.label != y.label || x.type != y.type || x.hidden != y.hidden || (x.type == FieldType.number && x.unit != y.unit)) return false;
      if (x.type == FieldType.choice && jsonEncode(x.choices ?? const []) != jsonEncode(y.choices ?? const [])) return false;
    }
    return true;
  }

  /// Whether a notebook deleted on another device (a tombstone in its folder) is deleted here too. Always, today. This is the one
  /// place a "Don't replace my copies from this device" switch plugs in: for a device with it on, this returns false, the notebook
  /// is kept here, and the folder is written again.
  bool appliesRemoteNotebookDelete(Notebook n) => true;

  String _snapOf(Notebook n) => jsonEncode({'template': n.template, 'def': n.def.toJson(), 'private': n.private, 'map': n.map, 'sp': n.savedPlaces});

  /// Changed here since the last sync: its definition, or an entry made or changed here (or one that is not known to the share).
  Future<bool> _changedHere(Notebook n, String snap) async {
    if (_snapOf(n) != snap) return true;
    for (final e in await notebook.entries(n.id)) {
      if (!_included(n, e)) continue;
      final s = _items[e.id];
      if (s == null || s.rev != e.rev) return true;
    }
    return false;
  }

  /// Takes the files of a folder out of the share (the notebook was deleted here; its record is a tombstone now).
  Future<void> _clearDir(String dir) async {
    for (final f in await folder.list(dir)) {
      if (!f.path.startsWith('$dir/') || f.path == '$dir/$kRecordFile') continue;
      await folder.delete(f.path);
    }
    _items.removeWhere((_, v) => v.imp == null && v.path.startsWith('$dir/'));
  }

  /// A notebook's id changes (another device's id for it is lower): the journal in [NotebookState.reidNotebook], with the field
  /// names of this share's state moved too. What this device kept for the old id goes to the new one.
  Future<void> _reid(Notebook n, String to) async {
    final from = n.id;
    final sn = _snap.remove(from);
    if (sn != null) _snap[to] = sn;
    eligible?.add(to);
    await _save();
    await notebook.reidNotebook(from, to, also: {'share field names': (o, w) => moveProps(stateFile, o, w)});
    await _load();
    if (privateBooks.contains(from)) {
      privateBooks
        ..remove(from)
        ..add(to);
    }
  }

  /// Reads the share's notebook records and brings them and the notebooks here to one state: copies of a record that sync kept
  /// merged; one id per exact notebook name (the lowest, through the re-id journal); a rename that is newer on one side taken by the
  /// other, as any field is; notebooks made here for records that have none here; records written for notebooks that have none; a
  /// tombstone for a notebook deleted here; the folder of each notebook worked out for the entries.
  Future<void> _syncRecords() async {
    final dirs = await readShareDirs(folder);
    final now = _now().millisecondsSinceEpoch;
    final recs = <String, NbRecord>{};
    for (final d in dirs.values) {
      final m = d.merged;
      if (m == null || m.id != d.dir) continue;
      if (d.copyPaths.isNotEmpty || d.mainText != m.text) {
        await folder.writeText('${d.dir}/$kRecordFile', m.text);
        for (final p in d.copyPaths) {
          await folder.delete(p);
        }
      }
      recs[d.dir] = m;
    }
    // A record another device merged into a lower id: the notebook here with that id takes the lower one.
    for (final n in [...notebook.notebooks]) {
      final r = recs[n.id];
      if (r == null || r.kind != RecordKind.alias || !_inShare(n)) continue;
      var to = r.aliasOf!;
      for (var i = 0; i < 5 && recs[to]?.kind == RecordKind.alias; i++) {
        to = recs[to]!.aliasOf!;
      }
      if (to != n.id && notebook.notebook(to) == null) await _reid(n, to);
    }
    // One id per exact notebook name: the lowest wins everywhere. A notebook here that has a higher one takes it, and its folder
    // (when there is one) becomes an alias of the lower; the entries in it stay where they are.
    final ids = <String, Set<String>>{};
    // Only notebooks from before the migration are matched by name (see [eligible]); the others are told apart by id alone.
    for (final r in recs.values) {
      if (r.kind == RecordKind.live && r.body['legacy'] == true) ids.putIfAbsent(r.name, () => {}).add(r.id);
    }
    for (final n in notebook.notebooks) {
      if (_inShare(n) && _eligible(n.id)) ids.putIfAbsent(n.name, () => {}).add(n.id);
    }
    for (final e in ids.entries) {
      if (e.value.length < 2) continue;
      final sorted = e.value.toList()..sort();
      final lo = sorted.first;
      for (final h in sorted.skip(1)) {
        final mine = notebook.notebook(h);
        if (mine == null || !_inShare(mine) || notebook.notebook(lo) != null) continue;
        await _reid(mine, lo);
        if (recs[h]?.kind == RecordKind.live) {
          final a = NbRecord.alias(h, lo, now);
          await folder.writeText('$h/$kRecordFile', a.text);
          recs[h] = a;
        }
      }
    }
    // Each notebook here and its record.
    for (final n in [...notebook.notebooks]) {
      if (!_inShare(n)) continue;
      final r = recs[n.id];
      final snap = _snap[n.id];
      if (r == null) {
        final rec = NbRecord.live(n.id, nameAt: now, body: _recBody(n, at: now));
        await folder.writeText('${n.id}/$kRecordFile', rec.text);
        recs[n.id] = rec;
        _snap[n.id] = (name: n.name, at: now, icon: n.def.icon, iconAt: rec.iconAt, color: n.def.color, colorAt: rec.colorAt);
      } else if (r.kind == RecordKind.live) {
        // The name, the icon and the colour each go the way of the later writer. What changed here since the last sync is written
        // (later than the record's); what changed in the record and not here is taken here.
        final nameLocal = snap != null && n.name != snap.name;
        final iconLocal = snap != null && n.def.icon != snap.icon;
        final colorLocal = snap != null && n.def.color != snap.color;
        final body = {...r.body};
        var nameAt = r.at, iconAt = r.iconAt, colorAt = r.colorAt;
        if (nameLocal) {
          nameAt = max(now, r.at + 1);
          body['name'] = n.name;
        }
        if (iconLocal) {
          iconAt = max(now, r.iconAt + 1);
          body['icon'] = n.def.icon;
          body['icon_at'] = iconAt;
        }
        if (colorLocal) {
          colorAt = max(now, r.colorAt + 1);
          body['color'] = n.def.color;
          body['color_at'] = colorAt;
        }
        if (nameLocal || iconLocal || colorLocal) {
          final rec = NbRecord.live(n.id, nameAt: nameAt, body: body);
          await folder.writeText('${n.id}/$kRecordFile', rec.text);
          recs[n.id] = rec;
        }
        var d = n.def;
        var changed = false;
        if (!nameLocal && r.name != n.name && !notebook.nameTaken(r.name, exceptId: n.id)) {
          d = d.copyWith(name: r.name);
          changed = true;
        }
        if (!iconLocal && r.icon != n.def.icon) {
          d = r.icon == null ? d.copyWith(clearIcon: true) : d.copyWith(icon: r.icon);
          changed = true;
        }
        if (!colorLocal && r.color != n.def.color) {
          d = r.color == null ? d.copyWith(clearColor: true) : d.copyWith(color: r.color);
          changed = true;
        }
        final now0 = changed ? await notebook.saveNotebook(id: n.id, def: d) : n;
        _snap[n.id] = (name: now0.name, at: nameAt, icon: now0.def.icon, iconAt: iconAt, color: now0.def.color, colorAt: colorAt);
      }
      await _syncFields(n, recs, now);
    }
    // Tombstones: a notebook deleted on another device, and one deleted here (not when the list of notebooks could not be read:
    // everything would look deleted).
    _tombDirs.clear();
    _tombBooks.clear();
    _keepBooks.clear();
    final local = {for (final n in notebook.notebooks) n.id};
    final listed = notebook.error == null && !notebook.loading;
    for (final id in [..._snap.keys]) {
      if (local.contains(id) || !listed) continue;
      _snap.remove(id);
      _fieldSnap.remove(id);
      _bookSnap.remove(id);
      if (recs[id]?.kind == RecordKind.live) {
        // Deleted here: the tombstone goes in, and the notebook's files (and those of folders merged into it) come out.
        final t = NbRecord.tombstone(id, now);
        await folder.writeText('$id/$kRecordFile', t.text);
        recs[id] = t;
        for (final d in [id, for (final a in recs.entries) if (a.value.kind == RecordKind.alias && a.value.aliasOf == id) a.key]) {
          await _clearDir(d);
        }
      }
    }
    for (final e in recs.entries.toList()) {
      final r = e.value;
      if (r.kind != RecordKind.tombstone) continue;
      if (now - r.at > kTombstoneDays * 86400000) {
        await folder.delete('${e.key}/$kRecordFile');
        continue;
      }
      // Deleted on another device: deleted here too (the normal delete) when nothing here changed since the last sync; a notebook
      // changed here, or never synced here, wins and its folder is written again over the tombstone. A private notebook that is
      // not in the share was never part of it: untouched.
      final n = notebook.notebook(r.id);
      if (n != null && _inShare(n)) {
        final snap = _bookSnap[n.id];
        if (snap == null || n.savedPlaces || await _changedHere(n, snap) || !appliesRemoteNotebookDelete(n)) {
          final at = max(now, r.at + 1);
          final rec = NbRecord.live(n.id, nameAt: at, body: _recBody(n, at: at));
          await folder.writeText('${n.id}/$kRecordFile', rec.text);
          recs[n.id] = rec;
          _snap[n.id] = (name: n.name, at: at, icon: n.def.icon, iconAt: rec.iconAt, color: n.def.color, colorAt: rec.colorAt);
          _fieldSnap.remove(n.id);
          await _syncFields(n, recs, now);
          _keepBooks.add(n.id);
          continue;
        }
        for (final en in await notebook.entries(n.id)) {
          _items.remove(en.id);
        }
        await notebook.deleteNotebook(n.id);
        _snap.remove(n.id);
        _bookSnap.remove(n.id);
        _props.remove(n.id);
        _fieldSnap.remove(n.id);
        privateBooks.remove(n.id);
      }
      _tombDirs.add(e.key);
      _tombBooks.add(r.id);
    }
    // A record for a notebook that is not here yet: made here with the id the record has (unless a lower id has the same name:
    // that one is the notebook, and this record will be merged into it).
    _recByName = {for (final r in recs.values) if (r.kind == RecordKind.live) r.name: r.body};
    for (final r in recs.values.where((r) => r.kind == RecordKind.live).toList()) {
      if (notebook.notebook(r.id) != null) continue;
      if (r.body['legacy'] == true && (ids[r.name] ?? const <String>{}).any((x) => x.compareTo(r.id) < 0)) continue;
      // A name a notebook here already has (made on its own, not the same notebook): this one is another notebook, kept under its
      // name with a few characters of its id added here, and the record keeps the name it has.
      final name = _freeName(r.name, r.id);
      final made = await _makeBook(id: r.id, name: name, shared: r.body);
      _snap[r.id] = (name: name, at: r.at, icon: made.def.icon, iconAt: r.iconAt, color: made.def.color, colorAt: r.colorAt);
    }
    dirNames = {for (final e in recs.entries) if (e.value.kind == RecordKind.live) e.key: e.value.name};
    // Which notebook each folder's entries belong to (only notebooks here and in the share).
    _dirNb = {};
    for (final e in recs.entries) {
      var r = e.value;
      for (var i = 0; i < 5 && r.kind == RecordKind.alias && recs[r.aliasOf] != null; i++) {
        r = recs[r.aliasOf]!;
      }
      final n = r.kind == RecordKind.live ? notebook.notebook(r.id) : null;
      if (n != null && _inShare(n)) _dirNb[e.key] = n.id;
    }
  }

  /// Format 2: the entries in the share, by their id.
  Future<Map<String, _Unit>> _scanIds(Map<String, _Unit> out, List<_Unit> newOutside, List<SyncConflict> unreadable, Map<String, (Notebook, NbEntry)> cache) async {
    final ignored = <(_Unit, _Unit)>[];
    void put(_Unit u) {
      final prev = out[u.doc.id];
      if (prev == null) {
        out[u.doc.id] = u;
      } else if (_dirNb[_topDir(prev.path)] == _dirNb[_topDir(u.path)] && _topDir(prev.path) != _topDir(u.path) && (_dirNb[_topDir(u.path)] == _topDir(u.path) || _dirNb[_topDir(prev.path)] == _topDir(prev.path))) {
        // The same entry in a notebook's own folder and in the folder of an id merged into it (both devices wrote it before they
        // agreed on the id): the entry is the one in the notebook's own folder; the other is the old place, not a copy.
        final keep = _dirNb[_topDir(u.path)] == _topDir(u.path) ? u : prev;
        final other = identical(keep, u) ? prev : u;
        out[u.doc.id] = keep;
        ignored.add((other, keep));
      } else {
        // A duplicated file: the one Cache knows keeps the id; the other becomes a new entry.
        final keep = _items[u.doc.id]?.path == prev.path ? prev : u;
        final other = identical(keep, prev) ? u : prev;
        out[u.doc.id] = keep;
        newOutside.add(_Unit(other.path, other.text, EntryDoc(id: '', notebook: other.doc.notebook, when: other.doc.when, title: other.doc.title, body: other.doc.body, place: other.doc.place, photos: other.doc.photos, fields: other.doc.fields, private: other.doc.private, extra: other.doc.extra, props: other.doc.props)));
      }
    }

    for (final f in await folder.list('')) {
      if (!f.path.endsWith(kNoteExt) || !f.path.contains('/')) continue;
      final book = switch (_dirNb[_topDir(f.path)]) { final id? => notebook.notebook(id), null => null };
      if (book == null) continue;
      final text = await folder.readText(f.path);
      if (text == null) continue;
      final probe = parseObsidian(text, fallbackId: '', fallbackNotebook: book.name, fieldProps: const {});
      if (probe == null) {
        final known = _items.entries.where((e) => e.value.path == f.path).firstOrNull;
        if (!_ignored.contains(f.path)) {
          unreadable.add(SyncConflict(entryId: known?.key ?? '', kind: ConflictKind.unreadable, title: f.path.split('/').last, path: f.path));
        }
        continue;
      }
      final doc = _inBook(parseObsidian(text, fallbackId: '', fallbackNotebook: book.name, fieldProps: _propTypes(book))!, book.name);
      final u = _Unit(f.path, text, doc);
      if (_outIds.contains(doc.id)) continue;
      if (doc.id.isEmpty) {
        newOutside.add(u);
        continue;
      }
      put(u);
    }
    // The old place of an entry whose own-folder copy says the same goes (nothing is lost: the text is in the other file).
    for (final (other, keep) in ignored) {
      if (other.text == keep.text) await folder.delete(other.path);
    }
    return out;
  }

  /// A notebook's field names (kept in a sync state file, by notebook id) move to its new id; saved at once, and running it again
  /// changes nothing. A step of the re-id journal.
  static Future<void> moveProps(File f, String oldId, String newId) async {
    if (!await f.exists()) return;
    final j = jsonDecode(await f.readAsString());
    if (j is! Map) return;
    final out = {...j};
    for (final key in const ['props', 'fields']) {
      final map = j[key];
      if (map is! Map || !map.containsKey(oldId)) continue;
      final m = {...map};
      final moved = m.remove(oldId);
      m.putIfAbsent(newId, () => moved);
      out[key] = m;
    }
    await writeStringAtomic(f, jsonEncode(out));
  }

  // ---- the run ----

  /// One sync. Errors reaching the folder are thrown (the status line shows them); nothing in Cache is lost.
  Future<SyncReport> run() async {
    final r = SyncReport();
    await _load();
    _sharedBooks = null;
    if (!await folder.reachable()) throw const FileSystemException("Can't reach the folder");
    await notebook.reload();
    if (idLayout) await _syncRecords();
    final books = notebook.notebooks;
    final byName = {for (final n in books) n.name: n};
    if (kind == SyncKind.share) {
      _outIds = {};
      for (final n in books) {
        if (!_inShare(n)) _outIds.addAll([for (final e in await notebook.entries(n.id)) e.id]);
      }
    }
    final cache = <String, (Notebook, NbEntry)>{};
    for (final n in books) {
      for (final e in await notebook.entries(n.id)) {
        if (_included(n, e)) cache[e.id] = (n, e);
      }
    }
    final newOutside = <_Unit>[];
    final unreadable = <SyncConflict>[];
    final candidates = <_Cand>[];
    final outside = await _scan(byName, newOutside, unreadable, cache: cache, candidates: kind == SyncKind.share ? null : candidates);
    _stopped.removeWhere((id) => !cache.containsKey(id));
    // A Cache file removed outside is written back now (Obsidian and Logseq); a question kept from an older build is dropped.
    if (_ownFilesOnly) _conflicts = [for (final c in _conflicts) if (c.kind != ConflictKind.removedOutside) c];
    final open = {for (final c in _conflicts) c.entryId};
    final conflicts = <SyncConflict>[...unreadable];
    // A Cache file that is there but cannot be read (asked about, or ignored by the person's choice) is not missing: it is never
    // written over.
    final unreadableIds = {
      for (final c in unreadable) if (c.entryId.isNotEmpty) c.entryId,
      for (final e in _items.entries) if (_ignored.contains(e.value.path)) e.key,
    };
    final ids = {...cache.keys, ..._items.keys, ...outside.keys};
    // Notes whose id the person took out by hand in this run: never imported as new (see below).
    final held = <String>{};
    for (final id in ids) {
      if (_stopped.contains(id)) continue;
      if (open.contains(id)) {
        conflicts.addAll(_conflicts.where((c) => c.entryId == id));
        continue;
      }
      if (unreadableIds.contains(id) && !outside.containsKey(id)) continue;
      final c = cache[id];
      final s = _items[id];
      final f = outside[id];
      // Format 2: a notebook another device deleted: what to do with its entries is decided where its tombstone is read (_syncRecords), not by a missing file.
      if (idLayout && ((c != null && _tombBooks.contains(c.$1.id)) || (s != null && _tombDirs.contains(_topDir(s.path))))) continue;
      if (idLayout && s != null && f != null && f.path != s.path) s.path = f.path;
      if (s != null && s.imp != null) {
        // An imported note moved or renamed outside: it is followed there.
        if (f != null && f.path != s.path) s.path = f.path;
        if (c == null) {
          // Its entry was deleted in Cache: the note stays, without Cache's id, and says `cachesync: off`.
          if (await notebook.entry(id) != null) continue;
          await _release(id, s);
          _items.remove(id);
          r.released++;
          continue;
        }
        if (f == null && await _takenOver(id, s)) {
          // The note is there but the person took Cache's id out of it by hand: the same as Stop syncing. The note says
          // `cachesync: off` (so it is not imported again, tag or not), the entry stays in Cache, unsynced. When the note
          // cannot be written, nothing changes and the note is not imported either (no duplicate); the next sync tries again.
          held.add(s.imp == 'block' ? '${s.path}\u0000${lsBlockKey(s.base.split('\n').first)}' : s.path);
          try {
            await _markOff(s);
          } catch (e) {
            logError('Notebook sync: could not mark a note', error: e, detail: s.path);
            continue;
          }
          _items.remove(id);
          _stopped.add(id);
          continue;
        }
      }
      final cacheChanged = c != null && (s == null || c.$2.rev != s.rev);
      final fileChanged = kind != SyncKind.logseqExport && f != null && s != null && f.text != s.base;
      final missing = kind != SyncKind.logseqExport && f == null && s != null;
      if (c != null) {
        final doc = _docOf(c.$1, c.$2);
        final text = _renderFor(id, doc);
        if (s == null && f == null) {
          _items[id] = _Item(await _write(id, doc, c.$1, text), text, c.$2.rev);
          r.written++;
        } else if (s == null && f != null) {
          // Both have it and Cache has no record (a folder connected again, or a second device joining).
          if (f.text != text) {
            final m = merge3('', text, f.text);
            if (m.clean) {
              _items[id] = _Item(await _write(id, doc, c.$1, text), text, c.$2.rev);
              r.written++;
            } else {
              conflicts.add(SyncConflict(entryId: id, kind: ConflictKind.bothChanged, title: doc.title ?? doc.when, path: f.path, cacheText: text, fileText: f.text));
            }
          } else {
            _items[id] = _Item(f.path, f.text, c.$2.rev);
          }
        } else if (missing) {
          if (kind == SyncKind.share && !cacheChanged && !_keepBooks.contains(c.$1.id)) {
            await notebook.deleteEntry(id);
            _items.remove(id);
            r.deleted++;
          } else {
            // Notebook sync: changed here since, so written again. Obsidian and Logseq: Cache is the source of truth, so its
            // file or block is written back and the entry stays.
            _rec(id, await _write(id, doc, c.$1, text), text, c.$2.rev, extra: s.extra);
            r.written++;
          }
        } else if (cacheChanged && !fileChanged) {
          _rec(id, await _write(id, doc, c.$1, text), text, c.$2.rev, extra: s?.extra ?? const []);
          r.written++;
        } else if (!cacheChanged && fileChanged) {
          final saved = await _apply(id, f.doc, byName, text: f.text);
          _rec(id, f.path, f.text, saved.rev);
          r.read++;
        } else if (cacheChanged && fileChanged) {
          final m = merge3(s.base, text, f.text);
          if (m.clean) {
            final mergedDoc = _parseAs(id, m.text, c.$1, when: doc.when);
            if (mergedDoc == null) {
              conflicts.add(SyncConflict(entryId: id, kind: ConflictKind.bothChanged, title: doc.title ?? doc.when, path: f.path, cacheText: text, fileText: f.text));
              continue;
            }
            final saved = await _apply(id, mergedDoc, byName);
            final path = await _write(id, mergedDoc, c.$1, m.text);
            _rec(id, path, m.text, saved.rev);
            r.merged.add(doc.title ?? doc.when);
          } else {
            conflicts.add(SyncConflict(entryId: id, kind: ConflictKind.bothChanged, title: doc.title ?? doc.when, path: f.path, cacheText: text, fileText: f.text));
          }
        }
      } else if (s != null) {
        if (f == null || kind == SyncKind.logseqExport) {
          // Gone from Cache: gone from the folder too (unless only the folder had it, already gone).
          if (f == null && kind != SyncKind.logseqExport) {
            _items.remove(id);
          } else {
            await _deleteOutside(id);
            _items.remove(id);
            r.deleted++;
          }
        } else if (!fileChanged) {
          await _deleteOutside(id);
          _items.remove(id);
          r.deleted++;
        } else {
          // Deleted in Cache but changed in the folder: the file wins (an edit outside is newer intent).
          final saved = await _apply(id, f.doc, byName, text: f.text);
          _rec(id, f.path, f.text, saved.rev);
          r.read++;
        }
      } else if (f != null && !_ownFilesOnly) {
        // A file or block with an id Cache does not know: read as that entry (notebook sync only; in Obsidian and Logseq a
        // file Cache has no record of is not Cache's).
        final saved = await _apply(id, f.doc, byName, text: f.text);
        _rec(id, f.path, f.text, saved.rev);
        r.read++;
      }
    }
    // Notes the person made with the import tag and no id: imported once, and Cache's id written into them.
    for (final u in candidates) {
      if (held.contains(u.kind == 'block' ? '${u.path}\u0000${lsBlockKey(u.text.split('\n').first)}' : u.path)) continue;
      await _import(u, byName, r);
    }
    // New notes and blocks written outside (no id yet): read as new entries, and the id written into them (notebook sync only;
    // Obsidian and Logseq notes the person made are left alone).
    for (final u in _ownFilesOnly ? const <_Unit>[] : newOutside) {
      final id = _newId();
      final saved = await _apply(id, u.doc, byName, text: u.text);
      final book = notebook.notebook(saved.notebookId) ?? byName[u.doc.notebook]!;
      final doc = _docOf(book, saved);
      final text = _render(doc);
      if (_logseq) {
        final cur = await folder.readText(u.path) ?? '';
        final i = cur.indexOf(u.text);
        if (i >= 0) await folder.writeText(u.path, cur.replaceRange(i, i + u.text.length, text));
        _items[id] = _Item(u.path, text, saved.rev, extra: doc.extra);
      } else {
        _items[id] = _Item(u.path, text, saved.rev, extra: doc.extra);
        await folder.writeText(u.path, text);
      }
      r.read++;
    }
    _conflicts = conflicts;
    r.conflicts = conflicts.length;
    if (!_logseq && !idLayout) await _writeBooks(books);
    for (final id in _photoWait) {
      final it = _items[id];
      if (it != null) it.base = '';
    }
    _photoWait.clear();
    if (idLayout) {
      for (final id in [..._bookSnap.keys]) {
        if (notebook.notebook(id) == null) _bookSnap.remove(id);
      }
      for (final n in notebook.notebooks) {
        if (_inShare(n) && dirNames.containsKey(n.id) && !_tombBooks.contains(n.id)) _bookSnap[n.id] = _snapOf(n);
      }
    }
    await _save();
    return r;
  }

  /// `.cache/notebooks.json`: each notebook's definition, so a device that does not have it yet makes it the same way.
  Future<void> _writeBooks(List<Notebook> books) async {
    final list = [
      for (final n in books)
        if (includePrivate || !n.private || privateBooks.contains(n.id))
          {'id': n.id, 'template': n.template, 'def': n.def.toJson(), 'private': n.private, 'map': n.map, if (n.savedPlaces) 'saved_places': true, 'props': _fieldProps(n)},
    ];
    final text = '${const JsonEncoder.withIndent(' ').convert({'format': 'cache-notebooks', 'version': 1, 'notebooks': list})}\n';
    if (await folder.readText('.cache/notebooks.json') != text) await folder.writeText('.cache/notebooks.json', text);
  }

  String _newId() {
    final rnd = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(12, '0');
    final h = (rnd + rnd.split('').reversed.join() + rnd).substring(0, 32);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}';
  }

  /// The person's decision on a conflict. Both changed: [keepCache] writes Cache's version to the folder, else the folder's
  /// is read into Cache; the other is kept as a copy. Removed outside: [keepCache] writes it again, else deletes it here.
  /// Unreadable: [keepCache] = ignore the file from now on.
  Future<void> resolve(SyncConflict c, {required bool keepCache}) async {
    await _load();
    await notebook.reload();
    final byName = {for (final n in notebook.notebooks) n.name: n};
    final e = c.entryId.isEmpty ? null : await notebook.entry(c.entryId);
    final book = e == null ? null : notebook.notebook(e.notebookId);
    switch (c.kind) {
      case ConflictKind.unreadable:
        _ignored.add(c.path);
      case ConflictKind.removedOutside:
        if (keepCache && e != null && book != null) {
          final doc = _docOf(book, e);
          final text = _render(doc);
          _items.remove(c.entryId);
          _items[c.entryId] = _Item(await _write(c.entryId, doc, book, text), text, e.rev);
        } else {
          if (e != null) await notebook.deleteEntry(c.entryId);
          _items.remove(c.entryId);
        }
      case ConflictKind.bothChanged:
        if (e == null || book == null) break;
        final doc = _docOf(book, e);
        final text = _renderFor(c.entryId, doc);
        if (keepCache) {
          if (c.fileText != null) await _keepCopy(doc.title ?? doc.when, c.fileText!);
          _rec(c.entryId, await _write(c.entryId, doc, book, text), text, e.rev, extra: _items[c.entryId]?.extra ?? const []);
        } else {
          await _keepCopy(doc.title ?? doc.when, text);
          final fileDoc = c.fileText == null ? null : _parseAs(c.entryId, c.fileText!, book, when: doc.when);
          if (fileDoc != null) {
            final saved = await _apply(c.entryId, fileDoc, byName);
            _rec(c.entryId, c.path, c.fileText!, saved.rev);
          }
        }
    }
    _conflicts = [for (final x in _conflicts) if (!(x.entryId == c.entryId && x.path == c.path && x.kind == c.kind)) x];
    await _save();
  }

  // ---- import by tag ----

  /// The notebook a tagged note goes to: the one `#cachesync/<name>` names (by name or as a slug, `camping-trip` is "Camping
  /// trip"), made when there is none; the plain tag's is the Journal (Cache's default notebook), else "Notes".
  Future<Notebook> _importBook(String? name, Map<String, Notebook> byName) async {
    if (name == null) {
      final j = notebook.journal;
      if (j != null) return j;
      name = kImportFallbackNotebook;
    }
    final want = tagSlug(name);
    final have = byName.values.where((n) => !n.isPlaces && (n.name.toLowerCase() == name!.toLowerCase() || tagSlug(n.name) == want)).firstOrNull;
    if (have != null) return have;
    final shown = name.replaceAll(RegExp(r'[-_]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final made = await notebook.saveNotebook(template: 'notes', def: NotebookDef(name: shown.isEmpty ? name : shown, fields: const [], sort: NotebookSort.recent));
    byName[made.name] = made;
    return made;
  }

  static final Random _rnd = Random.secure();

  String _freshId() {
    String hex(int n) => [for (var i = 0; i < n; i++) _rnd.nextInt(16).toRadixString(16)].join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  /// Imports one tagged note: Cache's id goes into the note first (nothing else in it changes), then the entry is made; when
  /// the id cannot be written (a read-only folder) nothing is made, and when the entry cannot be made the note is put back.
  Future<void> _import(_Cand u, Map<String, Notebook> byName, SyncReport r) async {
    final cur = await folder.readText(u.path);
    if (cur == null) return;
    final id = _freshId();
    final now = _nowWall;
    final String newText;
    final String unitText;
    final String w0;
    var uk = const <String>[];
    var ht = false;
    EntryDoc? doc;
    late final Notebook book;
    switch (u.kind) {
      case 'note':
        if (cur != u.text || obsidianSyncOff(cur)) return; // changed while syncing: the next sync
        final t = withCacheId(cur, id);
        final probe = parseObsidian(cur, fallbackId: '', fallbackNotebook: '', fieldProps: const {}, fallbackWhen: now);
        if (t == null || probe == null) return;
        book = await _importBook(u.notebook, byName);
        // The note's own properties stay its own; only a text `title` becomes the entry's title (Cache keeps it up to date).
        final fm = splitFrontMatter(cur);
        uk = [
          for (final (k, lines) in fm?.props ?? const <(String, List<String>)>[])
            if (k != 'cache_id' && !(k == 'title' && propValue(lines) is String)) k,
        ];
        ht = fm?.props.any((p) => p.$1 == 'title') ?? false;
        // The note's own date and time when it gives them as Obsidian writes them, else now.
        w0 = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$').hasMatch(probe.when) && DateTime.tryParse(probe.when) != null ? probe.when : now;
        newText = t;
        unitText = t;
        doc = parseObsidian(t, fallbackId: id, fallbackNotebook: book.name, fieldProps: _propTypes(book), fallbackWhen: w0, userKeys: uk.toSet(), fallbackTitle: _baseName(u.path));
      case 'page':
        if (cur != u.text || lsSyncOff(lsProps(splitPage(cur).head.split('\n')))) return;
        book = await _importBook(u.notebook, byName);
        w0 = now;
        newText = 'cache-id:: $id\n$cur';
        unitText = newText;
        doc = parseLsPage(newText, pageTitle: lsPageTitle(u.path), when: w0, notebook: book.name);
      default:
        final at = cur.indexOf(u.text);
        if (at < 0) return;
        book = await _importBook(u.notebook, byName);
        final day = dayOfJournal(u.path.split('/').last, format: _format);
        w0 = day == null ? now : '$day${now.substring(10)}';
        unitText = lsBlockWithId(lsBlockOf(u.text), id);
        newText = cur.replaceRange(at, at + u.text.length, unitText);
        doc = parseLsBlock(lsBlockOf(unitText), when: w0, notebook: book.name);
    }
    if (doc == null) return;
    doc = EntryDoc(
        id: id, notebook: book.name, when: doc.when, title: doc.title, body: doc.body, place: doc.place, photos: doc.photos, fields: doc.fields, private: u.private, extra: doc.extra);
    try {
      await folder.writeText(u.path, newText);
    } catch (e) {
      logError('Notebook sync: could not import a note', error: e, detail: u.path);
      r.notAdded++;
      return;
    }
    _items[id] = _Item(u.path, unitText, 0, extra: doc.extra, imp: u.kind, w0: w0, uk: uk, ht: ht);
    try {
      final saved = await _apply(id, doc, byName);
      _items[id] = _Item(u.path, unitText, saved.rev, extra: _items[id]?.extra ?? doc.extra, imp: u.kind, w0: w0, uk: uk, ht: ht);
    } catch (e) {
      _items.remove(id);
      try {
        if (await folder.readText(u.path) == newText) await folder.writeText(u.path, cur);
      } catch (_) {}
      logError('Notebook sync: could not import a note', error: e, detail: u.path);
      r.notAdded++;
      return;
    }
    r.imported.add((doc.title ?? '').trim().isEmpty ? _baseName(u.path) : doc.title!.trim());
    r.importedBooks.add(book.id);
    await _save();
  }

  /// The note or block that holds Cache's id [id] now: where it was, else found by its id (moved since).
  Future<String?> _pathOf(String id, _Item s) async {
    bool has(String t) => s.imp == 'note' ? parseObsidian(t, fallbackId: '', fallbackNotebook: '', fieldProps: const {})?.id == id : (s.imp == 'page' ? lsPageId(t) == id : splitPage(t).blocks.any((b) => b.cacheId == id));
    final at = await folder.readText(s.path);
    if (at != null && has(at)) return s.path;
    for (final dir in s.imp == 'note' ? [''] : [_journals, 'pages']) {
      for (final f in await folder.list(dir)) {
        if (!f.path.endsWith('.md')) continue;
        final t = await folder.readText(f.path);
        if (t != null && t.contains(id) && has(t)) return f.path;
      }
    }
    return null;
  }

  /// Takes Cache's id out of imported note [id] and writes `cachesync: off` in its place; its text and the file stay.
  Future<void> _release(String id, _Item s) async {
    final path = await _pathOf(id, s);
    if (path == null) return;
    final cur = (await folder.readText(path))!;
    final String? next;
    switch (s.imp) {
      case 'note':
        next = releasedObsidian(cur);
      case 'page':
        next = lsPageReleased(cur);
      default:
        final p = splitPage(cur);
        next = p.head + [for (final b in p.blocks) b.cacheId == id ? lsBlockReleased(b) : b.text].join();
    }
    if (next != null && next != cur) await folder.writeText(path, next);
  }

  /// An imported note that is still there without Cache's id (the person took it out): a file or page at its place, a block
  /// with the same first line (tags aside) on its page.
  Future<bool> _takenOver(String id, _Item s) async {
    final cur = await folder.readText(s.path);
    if (cur == null) return false;
    if (s.imp != 'block') return true;
    final key = lsBlockKey(s.base.split('\n').first);
    return splitPage(cur).blocks.any((b) => b.cacheId == null && lsBlockKey(b.lines.first) == key);
  }

  /// Writes `cachesync: off` into a note the person took Cache's id out of (its text and tags stay as they are).
  Future<void> _markOff(_Item s) async {
    final cur = await folder.readText(s.path);
    if (cur == null) return;
    final String? next;
    switch (s.imp) {
      case 'note':
        next = obsidianWithOff(cur);
      case 'page':
        next = lsPageWithOff(cur);
      default:
        final key = lsBlockKey(s.base.split('\n').first);
        final p = splitPage(cur);
        final at = p.blocks.indexWhere((b) => b.cacheId == null && lsBlockKey(b.lines.first) == key);
        next = at < 0 ? null : p.head + [for (var i = 0; i < p.blocks.length; i++) i == at ? lsBlockWithOff(p.blocks[i]) : p.blocks[i].text].join();
    }
    if (next != null && next != cur) await folder.writeText(s.path, next);
  }

  /// "Stop syncing this note" (an imported note): Cache's id goes out of the note, `cachesync: off` takes its place, and the
  /// entry stays in Cache as an entry of its own; neither changes the other again. False when the folder cannot be reached
  /// (nothing is changed).
  Future<bool> stopSyncing(String id) async {
    await _load();
    final s = _items[id];
    if (s == null || s.imp == null) return true;
    if (!await folder.reachable()) return false;
    await _release(id, s);
    _items.remove(id);
    _stopped.add(id);
    _conflicts = [for (final c in _conflicts) if (c.entryId != id) c];
    await _save();
    return true;
  }

  /// What a connection's record says of the entries: the ones imported by their tag and syncing, and the ones that stopped.
  static Future<({Set<String> imported, Set<String> stopped})> links(File stateFile) async {
    try {
      if (!await stateFile.exists()) return (imported: <String>{}, stopped: <String>{});
      final j = jsonDecode(await stateFile.readAsString()) as Map;
      return (
        imported: {for (final e in (j['items'] as Map? ?? const {}).entries) if ((e.value as Map)['imp'] != null) '${e.key}'},
        stopped: {for (final x in (j['stopped'] as List? ?? const [])) '$x'},
      );
    } catch (_) {
      return (imported: <String>{}, stopped: <String>{});
    }
  }

  /// Drops the record of what was synced (the folder was disconnected): the next connection starts fresh.
  Future<void> forget() async {
    try {
      if (await stateFile.exists()) await stateFile.delete();
    } catch (_) {}
  }
}
