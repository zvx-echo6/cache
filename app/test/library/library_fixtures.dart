import 'dart:convert';
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_prefs.dart';
import 'package:cache/library/shelf_source.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:flutter/material.dart';

import '../browse/fakes.dart';

/// One book of a sample library: its doc id, title, and the division its pack suggests (with a second best).
typedef SampleBook = (String doc, String title, String? div, String? second);

/// A library of books as cache-build writes it (cache-library.json, shard/, documents.tsv, packs/ with each book's header) and,
/// optionally, a seed log. [samebook]: a pack's `samebook` block by doc id.
/// The stored PDF's BLAKE3 a sample book is given (64 hex digits from its doc id; only the name matters here).
String sampleHash(String doc) => (doc.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join() * 32).substring(0, 64);

/// [pdfs]: the books whose PDF is on this device, as `bookshelf/<blake3>.pdf` (3,000 bytes each). [extra]: more keys for each
/// book's `book` block (a later pack revision's author or edition).
Directory writeBookLibrary(Directory root, String name, List<SampleBook> books,
    {String? log,
    Map<String, dynamic>? compression,
    Set<String> pdfs = const {},
    Map<String, Map<String, dynamic>> extra = const {},
    Map<String, Map<String, dynamic>> samebook = const {},
    bool own = false,
    Set<String> unsure = const {},
    Set<String> noFlag = const {}}) {
  final d = Directory('${root.path}/$name')..createSync(recursive: true);
  Directory('${d.path}/shard').createSync();
  File('${d.path}/cache-library.json').writeAsStringSync(jsonEncode({'format': 1, 'library_id': name, 'title': 'Field library', 'version': '1', if (own) 'own': true}));
  final tsv = StringBuffer('doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\n');
  for (final b in books) {
    tsv.writeln('${b.$1}\t1\t${b.$2}\t${sampleHash(b.$1)}\t10\t120');
  }
  File('${d.path}/documents.tsv').writeAsStringSync(tsv.toString());
  Directory('${d.path}/packs').createSync();
  for (final b in books) {
    final header = {
      'cdoc': 1,
      'doc_id': b.$1,
      'doc_version': 1,
      'title': b.$2,
      'source': {'blake3': sampleHash(b.$1), 'size': 41000000, 'file_name': '${b.$1}.pdf'},
      'page_count': 120,
      'pieces': 1,
      'book': {
        'title': b.$2,
        'source_title': null,
        // no original BLAKE3 unless [extra] gives one: each book's copy key in the Bookshelves log is then its doc id
        'original_blake3': null,
        'compression': compression,
        'ocr': null,
        // the sorter's verdict as a pack records it: confident (filed) unless the book is in [unsure] (not filed, with its top three) or
        // [noFlag] (a pack from before the flag: a division and a second, no flag, no list)
        'suggested': b.$3 == null
            ? null
            : {
                'div': b.$3, 'label': '', 'score': 0.4, 'classifier_version': 3, 'source': 'classifier', 'second_div': b.$4,
                if (!noFlag.contains(b.$1)) 'filed': !unsure.contains(b.$1),
                if (!noFlag.contains(b.$1)) 'suggestions': [for (final d in [b.$3, b.$4, if (b.$4 != null) '120']) if (d != null) {'div': d, 'label': '', 'score': 0.3}],
              },
        ...?extra[b.$1],
      },
      if (samebook[b.$1] != null) 'samebook': samebook[b.$1],
    };
    final body = '${jsonEncode(header)}\n${jsonEncode({'i': 0, 'text': 'x' * 2000, 'page': '1'})}\n';
    File('${d.path}/packs/${b.$1}@1.cdoc').writeAsBytesSync(gzip.encode(utf8.encode(body)));
  }
  for (final doc in pdfs) {
    File('${d.path}/bookshelf/${sampleHash(doc)}.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(3000, 0x20));
  }
  if (log != null) {
    Directory('${d.path}/log').createSync();
    File('${d.path}/log/builder-$name.jsonl').writeAsStringSync(log);
  }
  return d;
}

/// A Bookshelves folder as another of the person's devices ([dev]) left it: each of [placed] (copy key, division, number) shelved
/// by Cache, and every copy in [checked] already checked for same books (so nothing new is shelved on its own).
Directory writeShelves(Directory dir, {List<(String, String, int)> placed = const [], Iterable<String> checked = const [], String dev = 'tablet'}) {
  final log = StringBuffer();
  var at = 1000;
  for (final (copy, div, seq) in placed) {
    log
      ..writeln(jsonEncode({'v': 1, 'at': at++, 'dev': dev, 'ev': 'place', 'copy': copy, 'div': div, 'by': 'auto'}))
      ..writeln(jsonEncode({'v': 1, 'at': at++, 'dev': dev, 'ev': 'assign', 'copy': copy, 'div': div, 'seq': seq}));
  }
  File('${dir.path}/log/$dev.jsonl')
    ..createSync(recursive: true)
    ..writeAsStringSync(log.toString());
  File('${dir.path}/.local/detected.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode({'format': 1, 'copies': checked.toList()..sort()}));
  return dir;
}

/// The libraries state over [root] (no search core: every library reads "Not searchable yet").
Future<LibrariesState> librariesAt(Directory root, FakeSources sources) async {
  final libs = LibrariesState(sources: sources, dirOverride: root, pollInterval: const Duration(milliseconds: 1));
  libs.dir = root;
  await libs.rescan();
  return libs;
}

/// What a test sees of this device's copies of the books: the answers it is given.
class FakeBookFiles extends ChangeNotifier implements BookFiles {
  FakeBookFiles({this.where = BookFileWhere.here, this.outcome = RemoveOutcome.removed, this.remove = true, this.deleteAll = true});

  BookFileWhere where;
  RemoveOutcome outcome;
  bool remove;
  bool deleteAll;
  final List<String> removed = [];
  final List<String> deleted = [];

  @override
  BookFileState stateOf(ShelfBook book) => BookFileState(where, bytes: book.bytes, from: where == BookFileWhere.elsewhere ? 'Kitchen tablet' : null);
  @override
  Future<void> Function()? download(ShelfBook book) => where == BookFileWhere.elsewhere ? () async {} : null;
  @override
  bool get canRemove => remove;
  @override
  Future<(RemoveOutcome, int, int)> removeFromDevice(List<ShelfBook> books) async {
    if (outcome == RemoveOutcome.removed) removed.addAll(books.map((b) => b.id));
    return (outcome, outcome == RemoveOutcome.removed ? books.length : 0, outcome == RemoveOutcome.removed ? 0 : books.length);
  }

  @override
  bool get canDeleteEverywhere => deleteAll;
  @override
  Future<void> deleteEverywhere(ShelfBook book) async => deleted.add(book.id);
}

/// The Library's pages over [shelves], with the rest stood in.
LibraryDeps testDeps({
  required BrowseState browse,
  required ShelfSource shelves,
  BookFiles? files,
  ShelfLookPrefs? looks,
  List<String>? added,
  RegionsState? regions,
  SharingState? sharing,
}) =>
    LibraryDeps(
      browse: browse,
      shelves: shelves,
      files: files ?? BookFilesUnavailable(),
      looks: looks ?? ShelfLookPrefs(dirOverride: Directory.systemTemp.createTempSync('looks')),
      regions: regions,
      sharing: sharing,
      zims: (_) => const Scaffold(body: Center(child: Text('ZIM list'))),
      addToLibrary: (_) => added?.add('add'),
      openGuide: (_) async {},
      openOwnLibrary: (_, _) {},
      holdsBooks: (l) => shelves is CdsShelfSource && shelves.holdsBooks(l),
      booksIn: (l) => shelves is CdsShelfSource ? shelves.booksIn(l) : 0,
      whatsNew: () async => const ['- **A new Library:** four places in one.'],
    );
