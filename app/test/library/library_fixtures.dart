import 'dart:convert';
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_prefs.dart';
import 'package:cache/library/shelf_source.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:flutter/material.dart';

import '../browse/fakes.dart';

/// One book of a sample library: its doc id, title, and the division its pack suggests (with a second best).
typedef SampleBook = (String doc, String title, String? div, String? second);

/// A library of books as cache-build writes it (cache-library.json, shard/, documents.tsv, packs/ with each book's header) and,
/// optionally, a seed log.
Directory writeBookLibrary(Directory root, String name, List<SampleBook> books, {String? log, Map<String, dynamic>? compression}) {
  final d = Directory('${root.path}/$name')..createSync(recursive: true);
  Directory('${d.path}/shard').createSync();
  File('${d.path}/cache-library.json').writeAsStringSync(jsonEncode({'format': 1, 'library_id': name, 'title': 'Field library', 'version': '1'}));
  final tsv = StringBuffer('doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\n');
  for (final b in books) {
    tsv.writeln('${b.$1}\t1\t${b.$2}\tabc\t10\t120');
  }
  File('${d.path}/documents.tsv').writeAsStringSync(tsv.toString());
  Directory('${d.path}/packs').createSync();
  for (final b in books) {
    final header = {
      'cdoc': 1,
      'doc_id': b.$1,
      'doc_version': 1,
      'title': b.$2,
      'source': {'blake3': 'abc', 'size': 41000000, 'file_name': '${b.$1}.pdf'},
      'page_count': 120,
      'pieces': 1,
      'book': {
        'title': b.$2,
        'source_title': null,
        'original_blake3': 'abc',
        'compression': compression,
        'ocr': null,
        'suggested': b.$3 == null ? null : {'div': b.$3, 'label': '', 'score': 0.4, 'classifier_version': 3, 'source': 'classifier', 'second_div': b.$4},
      },
    };
    final body = '${jsonEncode(header)}\n${jsonEncode({'i': 0, 'text': 'x' * 2000, 'page': '1'})}\n';
    File('${d.path}/packs/${b.$1}@1.cdoc').writeAsBytesSync(gzip.encode(utf8.encode(body)));
  }
  if (log != null) {
    Directory('${d.path}/log').createSync();
    File('${d.path}/log/builder-$name.jsonl').writeAsStringSync(log);
  }
  return d;
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
  final List<String> opened = [];
  final List<String> removed = [];
  final List<String> deleted = [];

  @override
  BookFileState stateOf(ShelfBook book) => BookFileState(where, bytes: book.bytes, from: where == BookFileWhere.elsewhere ? 'Kitchen tablet' : null);
  @override
  Future<void> Function()? open(ShelfBook book) => where == BookFileWhere.here ? () async => opened.add(book.id) : null;
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
}) =>
    LibraryDeps(
      browse: browse,
      shelves: shelves,
      files: files ?? BookFilesUnavailable(),
      looks: looks ?? ShelfLookPrefs(dirOverride: Directory.systemTemp.createTempSync('looks')),
      zims: (_) => const Scaffold(body: Center(child: Text('ZIM list'))),
      addToLibrary: (_) => added?.add('add'),
      openGuide: (_) async {},
      openOwnLibrary: (_, _) {},
      holdsBooks: (l) => shelves is CdsShelfSource && shelves.holdsBooks(l),
      whatsNew: () async => const ['- **A new Library:** four places in one.'],
    );
