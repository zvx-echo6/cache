import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache_search/cache_search.dart' show SourceStatus;

import '../browse/fakes.dart' show FakeSources, testPolicy;
import 'fake_shelves.dart';
import 'library_fixtures.dart';

/// A search core's word that every library is open and searchable (so Catalog's rows read "Ready").
class ReadyLibrarySources extends FakeSources {
  ReadyLibrarySources(super.dir);

  final Map<String, String> titles0 = {};

  @override
  SourceStatus? statusAt(String path) {
    final p = path.replaceAll('\\', '/');
    for (final e in titles0.entries) {
      if (p.endsWith('/${e.key}/shard')) {
        return SourceStatus(id: e.key, kind: 'library', path: path, title: e.value, indexed: true, building: false, stale: false, opening: false, updating: false, docs: 1, sourceId: e.key);
      }
    }
    return super.statusAt(path);
  }
}

/// Two libraries of books with different counts: "Recon library" holds 7 and none is shelved, "Field library" holds 3 and two are.
class CatalogCountWorld {
  late Directory tmp;
  late ReadyLibrarySources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;
  late BrowseState browse;

  Future<void> make() async {
    tmp = Directory.systemTemp.createTempSync('catalog-count');
    final root = Directory('${tmp.path}/libraries');
    writeBookLibrary(root, 'recon', [for (var i = 1; i <= 7; i++) ('r$i', 'Recon book $i', null, null)]);
    writeBookLibrary(root, 'field', const [('f1', 'Wilderness first aid', '210', null), ('f2', 'Emergency war surgery', '210', null), ('f3', 'Small engine repair', '670', null)]);
    for (final (id, title) in [('recon', 'Recon library'), ('field', 'Field library')]) {
      File('${root.path}/$id/cache-library.json').writeAsStringSync('{"format":1,"library_id":"$id","title":"$title","version":"1"}');
    }
    sources = ReadyLibrarySources(Directory('${tmp.path}/zims')..createSync(recursive: true))
      ..titles0['recon'] = 'Recon library'
      ..titles0['field'] = 'Field library';
    libs = await librariesAt(root, sources);
    final dir = writeShelves(Directory('${tmp.path}/bookshelves'),
        placed: const [('f1', '210', 1), ('f2', '210', 2)], checked: const ['r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'f1', 'f2', 'f3']);
    shelves = CdsShelfSource(libs, calls: FakeShelvesCalls(), bookshelvesDir: () async => dir, deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
    await shelves.whenRead();
    browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
  }

  void dispose() {
    shelves.dispose();
    browse.dispose();
    libs.dispose();
    sources.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
