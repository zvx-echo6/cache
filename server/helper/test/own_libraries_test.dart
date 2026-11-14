import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../bin/core_open.dart';
import '../bin/own_libraries.dart';
import 'fake_native.dart';

/// A fake core whose `own_library_sync` gives a library with no shard one, as the real job does (ownlib.rs, tests/ownlib_ffi.rs).
class _OwnNative extends FakeNative {
  @override
  int jobStart(String kind, String paramsJson) {
    if (kind == 'own_library_sync') {
      final dir = (jsonDecode(paramsJson) as Map)['library_dir'] as String;
      final rebuilt = !Directory('$dir/shard').existsSync();
      Directory('$dir/shard').createSync(recursive: true);
      progressScript
        ..clear()
        ..add(jsonEncode({'state': 'done', 'done': 1, 'total': 1, 'detail': {'own': true, 'rebuilt': rebuilt, 'reason': rebuilt ? 'first rebuild on this device' : null, 'books': 1, 'points': 3, 'conflicts_removed': <String>[]}}));
    }
    return super.jobStart(kind, paramsJson);
  }
}

void main() {
  late Directory tmp;
  late AppDirs dirs;
  late _OwnNative fake;
  late CoreDispatcher d;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('own_libraries_test');
    dirs = AppDirs(Directory('${tmp.path}/support')..createSync(), Directory('${tmp.path}/docs')..createSync());
    fake = _OwnNative()..statusFn = () => jsonEncode({'sources': <Object>[]});
    d = CoreDispatcher(() => fake);
    d.handle('open', {'sources': <Object>[], 'extra': null});
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void lib(String name, Map<String, dynamic> settings) {
    final dir = Directory('${dirs.docs.path}/libraries/$name')..createSync(recursive: true);
    File('${dir.path}/cache-library.json').writeAsStringSync(jsonEncode(settings));
    File('${dir.path}/packs/b@1.cdoc').createSync(recursive: true);
  }

  test("an own library that arrived without its shard is made from its packs, the core gets the list and the index driver is kicked", () async {
    lib('my-books', {'library_id': 'my-books-a', 'own': true, 'own_default': true});
    lib('field-library', {'library_id': 'field-library'});
    lib('first-aid', {'library_id': 'first-aid', 'own': true});
    final changes = <List<Map<String, dynamic>>>[];
    var kicks = 0;
    final own = OwnLibrarySync(d, dirs, onChanged: changes.add, onDone: () => kicks++, poll: const Duration(milliseconds: 1));
    expect(await own.run(), isTrue);
    final asked = [for (final c in fake.calls) if (c.startsWith('jobStart:own_library_sync:')) (jsonDecode(c.substring('jobStart:own_library_sync:'.length)) as Map)['library_dir']];
    expect(asked, ['${dirs.docs.path}/libraries/my-books'], reason: 'only own libraries, told apart by settings and folder name');
    expect(changes.single.map((s) => s['path']), contains('${dirs.docs.path}/libraries/my-books/shard'));
    expect(fake.calls.where((c) => c.startsWith('setSources:')), isNotEmpty);
    expect(kicks, 1);
    // nothing to rebuild the next time: the core is not given the list again, and the driver is still kicked
    final sets = fake.calls.where((c) => c.startsWith('setSources:')).length;
    expect(await own.run(), isFalse);
    expect(fake.calls.where((c) => c.startsWith('setSources:')).length, sets);
    expect(kicks, 2);
  });
}
