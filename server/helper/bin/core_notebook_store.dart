import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../app/lib/notebook/notebook_model.dart';
import '../../../app/lib/notebook/notebook_store.dart';
import '../../../packages/cache_search/lib/src/errors.dart';

/// A limit no notebook reaches: `entries` with it answers every entry (the core answers 1000 when a call gives none, and notebook
/// sync takes an entry it did not read for a deleted one).
const int kAllEntries = 100000000;

/// One of the core's notebook calls (cs_notebook): the op and its arguments, the answer as JSON. The helper's is the dispatcher's
/// `notebook` op; tests give an in-memory one.
typedef NotebookCall = FutureOr<Map<String, dynamic>> Function(String op, Map<String, dynamic> args);

/// Cache for Linux's [NotebookStore]: the notebooks as the core keeps them, with no Flutter, for whatever on the server needs the
/// notebook engine (notebook sync between devices now; a folder sync with Obsidian or Logseq later, which only needs another folder).
/// The photos are files of the core's media folder (`<support>/notebook/photos/<id>.jpg`, `thumbs/<id>.jpg`), where the browser's
/// notebook viewer reads them.
///
/// The engine's reads (`notebooks`, `notebook`, `journal`, `nameTaken`) answer from the list read by the last [reload] or write,
/// as the phone's store does.
class CoreNotebookStore implements NotebookStore {
  CoreNotebookStore({required this.call, required this.mediaDir});

  final NotebookCall call;

  /// The folder of `photos/`, `thumbs/` and `files/` (the core's `media_dir`).
  final Directory mediaDir;

  List<Notebook> _notebooks = const [];

  @override
  List<Notebook> get notebooks => _notebooks;

  @override
  Notebook? notebook(String id) {
    for (final n in _notebooks) {
      if (n.id == id) return n;
    }
    return null;
  }

  @override
  Notebook? get journal {
    for (final n in _notebooks) {
      if (n.template == 'journal') return n;
    }
    return null;
  }

  @override
  bool nameTaken(String name, {String? exceptId}) {
    final n = name.trim().split(RegExp(r'\s+')).join(' ').toLowerCase();
    return _notebooks.any((x) => x.id != exceptId && x.name.toLowerCase() == n);
  }

  @override
  Future<void> reload() async {
    final r = await call('notebooks', const {});
    _notebooks = [for (final n in r['notebooks'] as List) Notebook.fromJson(n as Map)];
  }

  Future<T> _change<T>(Future<T> Function() f) async {
    final r = await f();
    await reload();
    return r;
  }

  /// Notebook [id] as the core has it now; null when there is none.
  Future<Notebook?> _stored(String id) async {
    try {
      return Notebook.fromJson(await call('notebook', {'id': id}));
    } on CacheSearchException catch (e) {
      if (e.code == 'not_found') return null;
      rethrow;
    }
  }

  @override
  Future<Notebook?> storedNotebook(String id) => _stored(id);

  @override
  Future<void> deleteNotebook(String id) => _change(() async {
        await call('notebook_delete', {'id': id});
      });

  /// As the phone's store: a notebook that exists keeps the fields it has, hidden ones included, whatever [def] lists.
  @override
  Future<Notebook> saveNotebook({String? id, String? template, required NotebookDef def, bool? private, bool? map, String? templateRef}) => _change(() async {
        final have = id == null ? null : await _stored(id);
        return Notebook.fromJson(await call('notebook_save', {
          'id': ?id,
          'template': ?template,
          'def': (have == null ? def : def.copyWith(fields: have.def.fields)).toJson(),
          'private': ?private,
          'map': ?map,
          'template_ref': ?templateRef,
        }));
      });

  @override
  Future<Notebook> ensureSavedPlaces() async {
    for (final n in _notebooks) {
      if (n.savedPlaces) return n;
    }
    return _change(() async => Notebook.fromJson(await call('saved_places', const {})));
  }

  @override
  Future<List<NbEntry>> entries(String notebookId) async =>
      [for (final e in (await call('entries', {'notebook_id': notebookId, 'limit': kAllEntries}))['entries'] as List) NbEntry.fromJson(e as Map)];

  @override
  Future<NbEntry?> entry(String id) async {
    try {
      return NbEntry.fromJson(await call('entry', {'id': id}));
    } on CacheSearchException catch (e) {
      if (e.code == 'not_found') return null;
      rethrow;
    }
  }

  @override
  Future<NbEntry> saveEntry({
    String? id,
    required String notebookId,
    required String occurredAt,
    String? title,
    String? body,
    Map<String, dynamic> values = const {},
    NbPlace? place,
    List<NbPhoto> photos = const [],
    List<NbFile> files = const [],
    bool draft = false,
    bool private = false,
    Map<String, dynamic> props = const {},
  }) =>
      _change(() async => NbEntry.fromJson(await call('entry_save', {
            'id': ?id,
            'notebook_id': notebookId,
            'occurred_at': occurredAt,
            'title': ?title,
            'body': ?body,
            'values': values,
            'place': place?.toJson(),
            'photos': [for (final p in photos) p.toJson()],
            'files': [for (final f in files) f.toJson()],
            'draft': draft,
            'private': private,
            if (props.isNotEmpty) 'props': props,
          })));

  @override
  Future<void> deleteEntry(String id) => _change(() async {
        await call('entry_delete', {'id': id});
      });

  // ---- photos ----

  @override
  Future<File> photoFile(String id) async => File('${mediaDir.path}/photos/$id.jpg');

  File thumbFile(String id) => File('${mediaDir.path}/thumbs/$id.jpg');

  @override
  Future<Uint8List?> photoBytes(String id) async {
    final f = await photoFile(id);
    return f.existsSync() ? f.readAsBytes() : null;
  }

  /// Stores a photo that came from a folder under its own id, where the browser's viewer reads it. The bytes are a phone's own
  /// photo (upright, at most 2048 px, no EXIF); the helper cannot make the 256 px thumbnail (no image library on the server), so
  /// the thumbnail is the same file.
  Future<void> storePhoto(String id, Uint8List bytes) async {
    final f = await photoFile(id);
    await f.parent.create(recursive: true);
    await _atomic(f, bytes);
    final t = thumbFile(id);
    await t.parent.create(recursive: true);
    await _atomic(t, bytes);
  }

  static Future<void> _atomic(File f, Uint8List bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<bool> copyPhoto(String from, String to) async {
    final bytes = await photoBytes(from);
    if (bytes == null) return false;
    final f = await photoFile(to);
    await f.parent.create(recursive: true);
    await _atomic(f, bytes);
    final t = thumbFile(from);
    if (t.existsSync()) {
      final dst = thumbFile(to);
      await dst.parent.create(recursive: true);
      await _atomic(dst, await t.readAsBytes());
    }
    return true;
  }
}
