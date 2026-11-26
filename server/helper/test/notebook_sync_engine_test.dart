// The notebook sync engine runs with no Flutter (L4 slice 6a). This is plain Dart (`dart test`): if sync_engine_core.dart, or anything
// it imports, reached Flutter (package:flutter, dart:ui) or the app's NotebookState, it would not compile here, and the first test
// walks the imports to say so by name. The engine runs against a NotebookStore and a SyncFolder that live in memory.
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../../app/lib/notebook/notebook_model.dart';
import '../../../app/lib/notebook/notebook_store.dart';
import '../../../app/lib/notebook/sync/folder.dart';
import '../../../app/lib/notebook/sync/sync_engine_core.dart';
import '../../../app/lib/notebook/templates_model.dart';

class MemFolder implements SyncFolder {
  final Map<String, String> text = {};
  final Map<String, Uint8List> bytes = {};

  @override
  String get display => 'Share';

  @override
  Future<bool> reachable() async => true;

  @override
  Future<List<FolderFile>> list(String dir) async => [
        for (final p in ({...text.keys, ...bytes.keys}.toList()..sort()))
          if (dir.isEmpty || p.startsWith('$dir/')) FolderFile(p, 0, (text[p] ?? '').length),
      ];

  @override
  Future<String?> readText(String path) async => text[path];

  @override
  Future<Uint8List?> readBytes(String path) async => bytes[path];

  @override
  Future<void> writeText(String path, String t) async => text[path] = t;

  @override
  Future<void> writeBytes(String path, Uint8List b) async => bytes[path] = b;

  @override
  Future<void> delete(String path) async {
    text.remove(path);
    bytes.remove(path);
  }

  @override
  Future<bool> exists(String path) async => text.containsKey(path) || bytes.containsKey(path);
}

/// A NotebookStore in memory: what the engine calls, and nothing of the app.
class MemStore implements NotebookStore {
  MemStore(this.media);

  final Directory media;
  final List<Notebook> _books = [];
  final Map<String, NbEntry> _entries = {};
  int _n = 0;

  @override
  List<Notebook> get notebooks => List.unmodifiable(_books);

  @override
  Notebook? notebook(String id) => _books.where((b) => b.id == id).firstOrNull;

  @override
  Notebook? get journal => _books.where((b) => b.template == 'journal').firstOrNull;

  @override
  bool nameTaken(String name, {String? exceptId}) => _books.any((b) => b.id != exceptId && b.name.toLowerCase() == name.trim().toLowerCase());

  @override
  Future<void> reload() async {}

  @override
  Future<Notebook> saveNotebook({String? id, String? template, required NotebookDef def, bool? private, bool? map, String? templateRef}) async {
    final i = _books.indexWhere((b) => b.id == id);
    final made = Notebook(id: id ?? 'nb${++_n}', template: template ?? (i < 0 ? 'notes' : _books[i].template), def: def, private: private ?? false, map: map ?? true, templateRef: templateRef);
    i < 0 ? _books.add(made) : _books[i] = made;
    return made;
  }

  @override
  Future<Notebook?> storedNotebook(String id) async => notebook(id);

  @override
  Future<void> deleteNotebook(String id) async {
    _books.removeWhere((b) => b.id == id);
    _entries.removeWhere((_, e) => e.notebookId == id);
  }

  @override
  Future<Notebook> ensureSavedPlaces() => saveNotebook(template: 'places', def: const NotebookDef(name: 'Places', fields: [], sort: NotebookSort.recent));

  @override
  Future<List<NbEntry>> entries(String notebookId) async => [for (final e in _entries.values) if (e.notebookId == notebookId) e];

  @override
  Future<NbEntry?> entry(String id) async => _entries[id];

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
  }) async {
    final eid = id ?? 'e${++_n}';
    return _entries[eid] = NbEntry(
        id: eid, notebookId: notebookId, occurredAt: occurredAt, title: title, body: body, values: values, place: place, photos: photos, files: files, draft: draft, private: private, props: props);
  }

  @override
  Future<void> deleteEntry(String id) async => _entries.remove(id);

  @override
  Future<File> photoFile(String id) async => File('${media.path}/photos/$id.jpg');

  @override
  Future<Uint8List?> photoBytes(String id) async {
    final f = await photoFile(id);
    return f.existsSync() ? f.readAsBytes() : null;
  }

  @override
  Future<bool> copyPhoto(String from, String to) async {
    final bytes = await photoBytes(from);
    if (bytes == null) return false;
    final f = await photoFile(to);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return true;
  }
}

void main() {
  test('the engine and everything it imports are free of Flutter', () {
    final seen = <String>{};
    final bad = <String>[];
    void walk(File f) {
      if (!seen.add(f.absolute.path)) return;
      for (final m in RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true).allMatches(f.readAsStringSync())) {
        final u = m.group(1)!;
        if (u.startsWith('package:flutter') || u == 'dart:ui' || u.startsWith('package:cache/')) {
          bad.add('${f.path} imports $u');
        } else if (!u.startsWith('dart:') && !u.startsWith('package:')) {
          walk(File.fromUri(f.uri.resolve(u)));
        }
      }
    }

    walk(File('../../app/lib/notebook/sync/sync_engine_core.dart'));
    expect(bad, isEmpty);
    expect(seen.length, greaterThan(3));
  });

  test('a notebook and its entry go out through the share folder and arrive on a second store', () async {
    final tmp = Directory.systemTemp.createTempSync('nb_engine_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final folder = MemFolder();
    final a = MemStore(Directory('${tmp.path}/a'));
    final book = await a.saveNotebook(template: 'journal', def: const NotebookDef(name: 'Journal', fields: [], sort: NotebookSort.recent));
    await a.saveEntry(notebookId: book.id, occurredAt: '2026-11-17T09:00:00-07:00', title: 'Water cache', body: 'Swapped six jugs.');
    Future<SyncReport> run(MemStore s, String name) => NotebookSyncCore(
          notebook: s,
          kind: SyncKind.share,
          folder: folder,
          stateFile: File('${tmp.path}/$name.json'),
          clock: () => DateTime(2026, 11, 17, 9),
          templates: () async => const Templates([], []),
        ).run();

    expect((await run(a, 'a')).written, 1);
    expect(folder.text.keys.where((p) => p.endsWith('.md')), hasLength(1));

    final b = MemStore(Directory('${tmp.path}/b'));
    final r = await run(b, 'b');
    expect(r.arrived, 1);
    final got = b.notebooks.single;
    expect(got.name, 'Journal');
    final entry = (await b.entries(got.id)).single;
    expect(entry.title, 'Water cache');
    expect(entry.body, 'Swapped six jugs.');
  });
}
