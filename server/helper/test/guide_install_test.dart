import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../bin/core_open.dart';
import '../bin/guide_install.dart';
import 'fake_native.dart';

/// A fake core whose `unpack_library` puts what the real job puts in the folder it is given.
class _UnpackNative extends FakeNative {
  @override
  int jobStart(String kind, String paramsJson) {
    if (kind == 'unpack_library') {
      final dir = Directory((jsonDecode(paramsJson) as Map)['dir'] as String)..createSync(recursive: true);
      File('${dir.path}/documents.tsv').writeAsStringSync('doc\ttitle\n');
      File('${dir.path}/copies.jsonl').writeAsStringSync('{}\n');
    }
    return super.jobStart(kind, paramsJson);
  }
}

String _done(String version, {String id = 'cache-guide'}) => jsonEncode({
      'state': 'done',
      'done': 1,
      'total': 1,
      'detail': {
        'settings': {'library_id': id, 'version': version},
        'resolved': {'library_id': id, 'title': 'Cache guide'},
      },
    });

void main() {
  late Directory tmp;
  late AppDirs dirs;
  late File package;
  late _UnpackNative fake;
  late CoreDispatcher d;
  late List<List<Map<String, dynamic>>> changes;
  late List<String> logs;
  late GuideInstaller installer;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('guide_install_test');
    dirs = AppDirs(Directory('${tmp.path}/support')..createSync(), Directory('${tmp.path}/docs')..createSync());
    package = File('${tmp.path}/cache-guide.cache-library')..writeAsBytesSync([1, 2, 3]);
    fake = _UnpackNative()..statusFn = () => jsonEncode({'sources': <Object>[]});
    d = CoreDispatcher(() => fake);
    d.handle('open', {'sources': <Object>[], 'extra': null});
    changes = [];
    logs = [];
    installer = GuideInstaller(d, dirs, package, onChanged: changes.add, log: logs.add, poll: const Duration(milliseconds: 1));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<String> unpacks() => fake.calls.where((c) => c.startsWith('jobStart:unpack_library:')).toList();
  String lib(String rest) => '${dirs.docs.path}/libraries/cache-guide/$rest';

  test('a server with no guide gets it: unpacked into libraries/cache-guide with its settings, the core and the index driver told', () async {
    fake.progressScript.add(_done('2026-11-08'));
    expect(await installer.ensure(), isTrue, reason: logs.join('\n'));
    expect(unpacks(), hasLength(1));
    expect((jsonDecode(unpacks().single.substring('jobStart:unpack_library:'.length)) as Map)['snapshot_path'], package.path);
    expect(Directory(lib('shard')).existsSync(), isTrue);
    expect(File(lib('documents.tsv')).existsSync(), isTrue, reason: 'the catalogue moves to the library root');
    expect(File(lib('copies.jsonl')).existsSync(), isTrue);
    expect(File(lib('shard/documents.tsv')).existsSync(), isFalse);
    expect((jsonDecode(File(lib('cache-library.json')).readAsStringSync()) as Map)['version'], '2026-11-08');
    expect(changes.single.single['path'], lib('shard'));
    expect(changes.single.single['kind'], 'library');
    expect(fake.calls.where((c) => c.startsWith('setSources:')), isNotEmpty);
    expect(Directory('${dirs.docs.path}/libraries').listSync().whereType<Directory>().map((e) => e.path), ['${dirs.docs.path}/libraries/cache-guide'], reason: 'no staging folder is left');
    expect(File('${dirs.support.path}/guide-installed.json').existsSync(), isTrue);
  });

  test('the next start does nothing while the package is the same; a package of another version replaces the old copy', () async {
    fake.progressScript.add(_done('2026-11-08'));
    await installer.ensure();
    expect(await installer.ensure(), isFalse);
    expect(unpacks(), hasLength(1), reason: 'the marker spares the unpacking');

    // the app carries a newer guide
    package.writeAsBytesSync([1, 2, 3, 4, 5]);
    fake.progressScript
      ..clear()
      ..add(_done('2026-11-20'));
    changes.clear();
    expect(await installer.ensure(), isTrue, reason: logs.join('\n'));
    expect((jsonDecode(File(lib('cache-library.json')).readAsStringSync()) as Map)['version'], '2026-11-20');
    expect(Directory('${dirs.docs.path}/libraries/.cache-guide.old').existsSync(), isFalse);
    expect(changes, hasLength(1));
    // the old copy was let go before it was moved: some setSources call had no guide in it
    final lists = [for (final c in fake.calls.where((c) => c.startsWith('setSources:'))) (jsonDecode(c.substring('setSources:'.length)) as Map)['sources'] as List];
    expect(lists.any((l) => l.isEmpty), isTrue);
  });

  test('a package with the version already installed changes nothing', () async {
    fake.progressScript.add(_done('2026-11-08'));
    await installer.ensure();
    File('${dirs.support.path}/guide-installed.json').deleteSync();
    changes.clear();
    expect(await installer.ensure(), isFalse);
    expect(changes, isEmpty);
    expect(File('${dirs.support.path}/guide-installed.json').existsSync(), isTrue, reason: 'the marker is written again');
    expect(Directory('${dirs.docs.path}/libraries').listSync().whereType<Directory>(), hasLength(1));
  });

  test('a package that is not the guide, a failed unpack and a missing file install nothing and leave no staging folder', () async {
    fake.progressScript.add(_done('1', id: 'something-else'));
    expect(await installer.ensure(), isFalse);
    expect(logs.last, contains('not "cache-guide"'));
    fake.progressScript
      ..clear()
      ..add('{"state":"failed","done":0,"total":1,"error":{"code":"bad","message":"not a library"}}');
    expect(await installer.ensure(), isFalse);
    expect(logs.last, contains('not a library'));
    package.deleteSync();
    expect(await installer.ensure(), isFalse);
    final libs = Directory('${dirs.docs.path}/libraries');
    expect(libs.existsSync() ? libs.listSync() : const [], isEmpty);
  });

  test('open starts the install only when the sources were found on disk, not given by a sources.json', () async {
    fake.progressScript.add(_done('2026-11-08'));
    final op = OpenOp(dirs, d, guide: installer);
    op.handle('open', {'sources': [{'kind': 'zim', 'path': '/x.zim', 'index_dir': '/i'}]});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(unpacks(), isEmpty, reason: 'an operator\'s own list is left alone');
    op.handle('open', const {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(unpacks(), hasLength(1));
  });
}
