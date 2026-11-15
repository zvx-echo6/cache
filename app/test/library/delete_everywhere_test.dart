// "Delete from all your devices" on this device (owner decisions, 2026-11-14): the book's packs and PDFs leave the person's own
// libraries, nothing else does; a book of a library they did not make is not theirs to delete; the Bookshelves log keeps its events
// (the shelf place and the call number come back when the book is added again). That the other devices follow is the sync's own
// delete of those two files plus each device's own_library_sync (tools/books-proof, scenarios del-*); the rebuild itself is tested in
// Rust (tests/ownlib_ffi.rs).
import 'dart:io';

import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/own_book_files.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'fake_shelves.dart';
import 'library_fixtures.dart';

void main() {
  late Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('delete-everywhere');
    final root = Directory('${tmp.path}/libraries');
    writeBookLibrary(root, 'my-books', const [('aid', 'Wilderness first aid', '210', null), ('bees', 'Keeping bees', '350', null)], pdfs: {'aid', 'bees'}, own: true);
    writeBookLibrary(root, 'field', const [('surgery', 'Emergency war surgery', '210', null)], pdfs: {'surgery'});
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
    libs = await librariesAt(root, sources);
    final shelvesDir = writeShelves(Directory('${tmp.path}/bookshelves'), placed: const [('aid', '210', 1), ('surgery', '210', 2)], checked: const ['aid', 'bees', 'surgery']);
    shelves = CdsShelfSource(libs, calls: FakeShelvesCalls(), bookshelvesDir: () async => shelvesDir, deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
    await shelves.whenRead();
  });
  tearDown(() {
    shelves.dispose();
    libs.dispose();
    tmp.deleteSync(recursive: true);
  });

  String lib(String rest) => '${tmp.path}/libraries/$rest';

  test("a book in the person's own library: its pack and PDF are what a delete removes; another library's book is not theirs", () {
    final files = OwnBookFiles(shelves);
    final aid = shelves.book('aid')!;
    final own = shelves.ownFilesOf(aid);
    expect(own, hasLength(1));
    expect(own.single.library.folderName, 'my-books');
    expect(own.single.packs.map((f) => f.path), [lib('my-books/packs/aid@1.cdoc')]);
    expect(own.single.pdf.path, lib('my-books/bookshelf/${sampleHash('aid')}.pdf'));
    expect(files.canDeleteBook(aid), isTrue);
    final surgery = shelves.book('surgery')!;
    expect(shelves.ownFilesOf(surgery), isEmpty);
    expect(files.canDeleteBook(surgery), isFalse, reason: 'a downloaded library is not the person\'s to delete');
    expect(files.canRemove, isFalse, reason: 'Remove from this device (offload) is 1.2');
  });

  test('Delete from all your devices removes only that book\'s pack and PDF, and keeps the Bookshelves events', () async {
    final log = File('${tmp.path}/bookshelves/log/tablet.jsonl').readAsStringSync();
    final n = await shelves.deleteOwnBook(shelves.book('aid')!);
    expect(n, 1);
    expect(File(lib('my-books/packs/aid@1.cdoc')).existsSync(), isFalse);
    expect(File(lib('my-books/bookshelf/${sampleHash('aid')}.pdf')).existsSync(), isFalse);
    // the rest stays: the other book of My books, the other library, the settings
    expect(File(lib('my-books/packs/bees@1.cdoc')).existsSync(), isTrue);
    expect(File(lib('my-books/bookshelf/${sampleHash('bees')}.pdf')).existsSync(), isTrue);
    expect(File(lib('field/packs/surgery@1.cdoc')).existsSync(), isTrue);
    expect(File(lib('field/bookshelf/${sampleHash('surgery')}.pdf')).existsSync(), isTrue);
    expect(File(lib('my-books/cache-library.json')).existsSync(), isTrue);
    expect(File('${tmp.path}/bookshelves/log/tablet.jsonl').readAsStringSync(), log, reason: 'its shelf place and call number are kept');
    expect(Directory('${tmp.path}/bookshelves/log').listSync().length, 1, reason: 'no event is written');
  });

  test('the real delete removes exactly CdsShelfSource.deleteTargets (the list the two-device harness removes too), every pack version, nothing else', () async {
    // a second version of the book's pack, as a replaced book leaves
    File(lib('my-books/packs/aid@2.cdoc')).writeAsBytesSync(File(lib('my-books/packs/aid@1.cdoc')).readAsBytesSync());
    List<String> all() => [
          for (final e in Directory('${tmp.path}/libraries').listSync(recursive: true))
            if (e is File) e.path.substring('${tmp.path}/libraries/'.length),
        ]..sort();
    final targets = CdsShelfSource.deleteTargets(lib('my-books'), 'aid', sampleHash('aid'));
    expect(shelves.ownFilesOf(shelves.book('aid')!).single.pdf.path, lib('my-books/${targets.last}'), reason: 'the app names the same PDF');
    expect(targets, ['packs/aid@1.cdoc', 'packs/aid@2.cdoc', 'bookshelf/${sampleHash('aid')}.pdf']);
    final before = all();
    await shelves.deleteOwnBook(shelves.book('aid')!);
    final gone = before.toSet().difference(all().toSet());
    expect(gone, {for (final t in targets) 'my-books/$t'});
  });

  test('a book with no copy in an own library is refused, and nothing is removed', () async {
    await expectLater(shelves.deleteOwnBook(shelves.book('surgery')!), throwsStateError);
    expect(File(lib('field/packs/surgery@1.cdoc')).existsSync(), isTrue);
  });
}
