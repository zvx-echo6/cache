import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../bin/core_open.dart';
import '../bin/fs_ops.dart';
import '../bin/line_protocol.dart';
import 'fake_native.dart';

void main() {
  late Directory tmp;
  late Directory support, docs;
  late FsOps fs;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fs_ops_test');
    support = Directory('${tmp.path}/support')..createSync();
    docs = Directory('${tmp.path}/docs')..createSync();
    fs = FsOps(support: support, docs: docs);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String codeOf(void Function() f) {
    try {
      f();
    } on Exception catch (e) {
      return (e as dynamic).code as String;
    }
    return 'none';
  }

  test('write then read, readString, stat, exists, list in both roots', () {
    fs.handle('fs.write', {'root': 'support', 'path': 'a/b/c.txt', 'string': 'héllo'});
    fs.handle('fs.write', {'root': 'docs', 'path': 'bin.dat', 'bytes': Uint8List.fromList([0, 1, 255])});
    expect(fs.handle('fs.readString', {'root': 'support', 'path': 'a/b/c.txt'}), 'héllo');
    expect(fs.handle('fs.read', {'root': 'docs', 'path': './bin.dat'}), Uint8List.fromList([0, 1, 255]));
    expect(File('${support.path}/a/b/c.txt').existsSync(), isTrue);
    expect(File('${docs.path}/a/b/c.txt').existsSync(), isFalse);
    expect(fs.handle('fs.exists', {'root': 'support', 'path': 'a'}), isTrue);
    expect(fs.handle('fs.exists', {'root': 'support', 'path': 'nope'}), isFalse);
    final st = fs.handle('fs.stat', {'root': 'support', 'path': 'a/b/c.txt'}) as Map;
    expect(st['isDir'], isFalse);
    expect(st['size'], 6);
    final l = fs.handle('fs.list', {'root': 'support', 'path': 'a'}) as List;
    expect(l.single, containsPair('name', 'b'));
    expect((l.single as Map)['isDir'], isTrue);
    final top = fs.handle('fs.list', {'root': 'docs', 'path': ''}) as List;
    expect((top.single as Map)['name'], 'bin.dat');
  });

  test('missing things are not_found', () {
    expect(codeOf(() => fs.handle('fs.read', {'root': 'docs', 'path': 'x'})), 'not_found');
    expect(codeOf(() => fs.handle('fs.list', {'root': 'docs', 'path': 'x'})), 'not_found');
    expect(codeOf(() => fs.handle('fs.stat', {'root': 'docs', 'path': 'x'})), 'not_found');
    expect(fs.handle('fs.delete', {'root': 'docs', 'path': 'x'}), isFalse);
  });

  test('paths that leave the root are bad_path', () {
    for (final p in ['../x', 'a/../../x', '/etc/passwd', 'C:/x', 'a\\b', '..', 'a/..']) {
      expect(codeOf(() => fs.handle('fs.read', {'root': 'docs', 'path': p})), 'bad_path', reason: p);
      expect(codeOf(() => fs.handle('fs.write', {'root': 'docs', 'path': p, 'string': 'x'})), 'bad_path', reason: p);
    }
    expect(codeOf(() => fs.handle('fs.read', {'root': 'other', 'path': 'x'})), 'bad_path');
    expect(codeOf(() => fs.handle('fs.write', {'root': 'docs', 'path': '', 'string': 'x'})), 'bad_path');
    expect(codeOf(() => fs.handle('fs.delete', {'root': 'docs', 'path': '.'})), 'bad_path');
    expect(tmp.listSync().length, 2, reason: 'nothing was made beside the roots');
  });

  test('a symlink that points out of the root is refused (and not listed)', () {
    final outside = Directory('${tmp.path}/outside')..createSync();
    File('${outside.path}/secret.txt').writeAsStringSync('s');
    try {
      Link('${docs.path}/out').createSync(outside.path);
    } on FileSystemException {
      markTestSkipped('symlinks are not allowed here');
      return;
    }
    expect(codeOf(() => fs.handle('fs.readString', {'root': 'docs', 'path': 'out/secret.txt'})), 'bad_path');
    expect(codeOf(() => fs.handle('fs.write', {'root': 'docs', 'path': 'out/new.txt', 'string': 'x'})), 'bad_path');
    expect(File('${outside.path}/new.txt').existsSync(), isFalse);
    expect(codeOf(() => fs.handle('fs.list', {'root': 'docs', 'path': 'out'})), 'bad_path');
    expect((fs.handle('fs.list', {'root': 'docs', 'path': ''}) as List), isEmpty);
    // deleting the link removes the link only
    expect(fs.handle('fs.delete', {'root': 'docs', 'path': 'out'}), isTrue);
    expect(File('${outside.path}/secret.txt').existsSync(), isTrue);
  });

  test('a write is atomic: replaces whole, leaves no temp file, and a failed write keeps the old file', () {
    fs.handle('fs.write', {'root': 'support', 'path': 'f.json', 'string': 'old'});
    fs.handle('fs.write', {'root': 'support', 'path': 'f.json', 'string': 'new!'});
    expect(File('${support.path}/f.json').readAsStringSync(), 'new!');
    expect(support.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last), ['f.json']);
    // a target that is a folder fails and leaves no temp file
    Directory('${support.path}/d').createSync();
    expect(codeOf(() => fs.handle('fs.write', {'root': 'support', 'path': 'd', 'string': 'x'})), 'io_error');
    expect(support.listSync().length, 2);
    // a bad payload fails before touching the file
    expect(codeOf(() => fs.handle('fs.write', {'root': 'support', 'path': 'f.json', 'string': null})), 'bad_path');
    expect(File('${support.path}/f.json').readAsStringSync(), 'new!');
  });

  test('delete (recursive or not) and mkdir', () {
    fs.handle('fs.mkdir', {'root': 'docs', 'path': 'x/y'});
    fs.handle('fs.write', {'root': 'docs', 'path': 'x/y/f', 'string': '1'});
    expect(codeOf(() => fs.handle('fs.delete', {'root': 'docs', 'path': 'x'})), 'io_error');
    expect(fs.handle('fs.delete', {'root': 'docs', 'path': 'x', 'recursive': true}), isTrue);
    expect(Directory('${docs.path}/x').existsSync(), isFalse);
  });

  test('rename moves a file or a folder inside a root and stays confined', () {
    fs.handle('fs.write', {'root': 'docs', 'path': 'libraries/.add-1/shard/s', 'string': 'x'});
    fs.handle('fs.write', {'root': 'docs', 'path': 'f.txt', 'string': 'one'});
    fs.handle('fs.write', {'root': 'docs', 'path': 'g.txt', 'string': 'two'});
    // a folder moves whole
    fs.handle('fs.rename', {'root': 'docs', 'from': 'libraries/.add-1', 'to': 'libraries/guide'});
    expect(fs.handle('fs.readString', {'root': 'docs', 'path': 'libraries/guide/shard/s'}), 'x');
    expect(fs.handle('fs.exists', {'root': 'docs', 'path': 'libraries/.add-1'}), isFalse);
    // a file replaces a file
    fs.handle('fs.rename', {'root': 'docs', 'from': 'f.txt', 'to': 'g.txt'});
    expect(fs.handle('fs.readString', {'root': 'docs', 'path': 'g.txt'}), 'one');
    expect(fs.handle('fs.exists', {'root': 'docs', 'path': 'f.txt'}), isFalse);
    // a folder does not replace a folder that has something in it, and nothing is lost
    fs.handle('fs.write', {'root': 'docs', 'path': 'other/a', 'string': 'a'});
    expect(codeOf(() => fs.handle('fs.rename', {'root': 'docs', 'from': 'other', 'to': 'libraries/guide'})), 'io_error');
    expect(fs.handle('fs.readString', {'root': 'docs', 'path': 'other/a'}), 'a');
    expect(fs.handle('fs.readString', {'root': 'docs', 'path': 'libraries/guide/shard/s'}), 'x');
    // missing, and out of the root
    expect(codeOf(() => fs.handle('fs.rename', {'root': 'docs', 'from': 'nope', 'to': 'z'})), 'not_found');
    expect(codeOf(() => fs.handle('fs.rename', {'root': 'docs', 'from': 'g.txt', 'to': '../escaped.txt'})), 'bad_path');
    expect(codeOf(() => fs.handle('fs.rename', {'root': 'docs', 'from': '../support', 'to': 'z'})), 'bad_path');
    expect(codeOf(() => fs.handle('fs.rename', {'root': 'docs', 'from': '', 'to': 'z'})), 'bad_path');
    expect(codeOf(() => fs.handle('fs.rename', {'root': 'other', 'from': 'a', 'to': 'b'})), 'bad_path');
    expect(File('${tmp.path}/escaped.txt').existsSync(), isFalse);
    expect(fs.handle('fs.readString', {'root': 'docs', 'path': 'g.txt'}), 'one');
  });

  test('rename does not follow a link out of the root', () {
    final outside = Directory('${tmp.path}/outside')..createSync();
    File('${outside.path}/secret').writeAsStringSync('s');
    Link('${docs.path}/out').createSync(outside.path);
    expect(codeOf(() => fs.handle('fs.rename', {'root': 'docs', 'from': 'out/secret', 'to': 'stolen'})), 'bad_path');
    expect(File('${outside.path}/secret').existsSync(), isTrue);
    // the link itself can be moved; what it points at stays
    fs.handle('fs.rename', {'root': 'docs', 'from': 'out', 'to': 'out2'});
    expect(File('${outside.path}/secret').existsSync(), isTrue);
  }, skip: Platform.isWindows ? 'links need rights on Windows' : false);

  test('roots are the absolute paths of the two folders', () {
    final r = fs.handle('fs.roots', {}) as Map;
    expect(r['support'], support.absolute.path);
    expect(r['docs'], docs.absolute.path);
    expect(Directory(r['docs'] as String).existsSync(), isTrue);
    expect(fs.handles('fs.roots'), isTrue);
  });

  test('over the line protocol: bytes travel as {"\$bytes"}, errors carry the code', () {
    final d = CoreDispatcher(() => FakeNative());
    String run(Map<String, dynamic> req) => handleLine(jsonEncode(req), d, handlers: [fs]);
    var r = jsonDecode(run({'id': 1, 'op': 'fs.write', 'args': {'root': 'docs', 'path': 'p', 'bytes': {r'$bytes': base64Encode([9, 8])}}}));
    expect(r, {'id': 1, 'ok': true, 'result': null});
    r = jsonDecode(run({'id': 2, 'op': 'fs.read', 'args': {'root': 'docs', 'path': 'p'}}));
    expect(r['result'], {r'$bytes': base64Encode([9, 8])});
    r = jsonDecode(run({'id': 3, 'op': 'fs.read', 'args': {'root': 'docs', 'path': '../p'}}));
    expect(r['ok'], isFalse);
    expect(r['error']['code'], 'bad_path');
  });

  test('scanSources lists zims and libraries like the app, and the extras come from buildCoreExtras', () {
    Directory('${docs.path}/zims').createSync();
    File('${docs.path}/zims/Wiki.zim').writeAsStringSync('');
    File('${docs.path}/zims/.hidden.zim').writeAsStringSync('');
    File('${docs.path}/zims/notes.txt').writeAsStringSync('');
    Directory('${docs.path}/libraries/guide/shard').createSync(recursive: true);
    File('${docs.path}/libraries/guide/cache-library.json').writeAsStringSync('{"name":"Guide"}');
    Directory('${docs.path}/libraries/noshard').createSync(recursive: true);
    final dirs = AppDirs(support, docs);
    final s = scanSources(dirs);
    expect(s.length, 2);
    expect(s[0], {'kind': 'zim', 'path': '${docs.path}/zims/Wiki.zim', 'index_dir': '${support.path}/indexes/Wiki.zim.idx'});
    expect(s[1], {
      'kind': 'library',
      'path': '${docs.path}/libraries/guide/shard',
      'index_dir': '${docs.path}/libraries/guide/index',
      'settings': {'name': 'Guide'},
    });
    final x = serverCoreExtras(dirs);
    expect(x.keys.toSet(), {'user', 'live', 'places', 'layers', 'routing', 'notebook', 'regions'});
    expect((x['live'] as Map)['sources_dir'], '${docs.path}/live-defs');
    expect((x['notebook'] as Map)['db_path'], '${support.path}/notebook/notebook.sqlite');
    expect(Directory('${docs.path}/live-defs').existsSync(), isTrue);
  });

  test('the helper open sends the core the sources and the full extras', () {
    final fake = FakeNative();
    final d = CoreDispatcher(() => fake);
    final open = OpenOp(AppDirs(support, docs), d);
    final r = open.handle('open', {'sources': null}) as Map;
    expect(r['sources'], 0);
    expect(r['extras'], contains('notebook'));
    final sent = jsonDecode(fake.calls.firstWhere((c) => c.startsWith('open:')).substring(5)) as Map;
    expect(sent['notebook'], isNotNull);
    expect(sent['sources'], isEmpty);
  });

  test('sources.rescan scans the app folders and hands the core the new list', () {
    final fake = FakeNative();
    final d = CoreDispatcher(() => fake);
    d.handle('open', {'sources': [], 'extra': null});
    final logs = <String>[];
    final rescan = RescanOp(AppDirs(support, docs), d, log: logs.add);
    expect(rescan.handles('sources.rescan'), isTrue);
    expect(rescan.handles('open'), isFalse);
    Directory('${docs.path}/zims').createSync();
    File('${docs.path}/zims/Wiki.zim').writeAsStringSync('');
    Directory('${docs.path}/libraries/guide/shard').createSync(recursive: true);
    var r = rescan.handle('sources.rescan', {'sources': null}) as Map;
    expect(r, {'sources': 2});
    expect(logs.last, 'sources rescanned (2)');
    var sent = jsonDecode(fake.calls.lastWhere((c) => c.startsWith('setSources:')).substring('setSources:'.length)) as Map;
    expect((sent['sources'] as List).map((s) => (s as Map)['kind']), ['zim', 'library']);
    // a ZIM taken away is gone after the next rescan
    File('${docs.path}/zims/Wiki.zim').deleteSync();
    r = rescan.handle('sources.rescan', {}) as Map;
    expect(r, {'sources': 1});
    expect(logs.last, 'sources rescanned (1)');
    sent = jsonDecode(fake.calls.lastWhere((c) => c.startsWith('setSources:')).substring('setSources:'.length)) as Map;
    expect((sent['sources'] as List).single['kind'], 'library');
    // the server's own list (sources.json) wins over the scan
    r = rescan.handle('sources.rescan', {
      'sources': [
        {'kind': 'zim', 'path': '/z/a.zim', 'index_dir': '/i/a'},
      ],
    }) as Map;
    expect(r, {'sources': 1});
    sent = jsonDecode(fake.calls.lastWhere((c) => c.startsWith('setSources:')).substring('setSources:'.length)) as Map;
    expect((sent['sources'] as List).single['path'], '/z/a.zim');
    expect(logs.last, 'sources rescanned (1)');
  });
}
