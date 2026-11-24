// The browser's folder picker, from the helper's side (`devfs.list`): subfolders of a folder of this computer, marked when they are
// an Obsidian vault or a Logseq graph, with hidden folders left out and unreadable ones told.
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/errors.dart';
import '../bin/folder_pick_ops.dart';

void main() {
  late Directory tmp, home;
  late FolderPickOps ops;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('folder_pick_ops_test');
    home = Directory('${tmp.path}/home/me')..createSync(recursive: true);
    ops = FolderPickOps(home: home.path);
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<Map<String, dynamic>> list([String? path]) async => ((await ops.handle('devfs.list', {'path': ?path})) as Map).cast<String, dynamic>();
  List<String> names(Map<String, dynamic> r) => [for (final f in r['folders'] as List) (f as Map)['name'] as String];
  Map kid(Map<String, dynamic> r, String name) => (r['folders'] as List).cast<Map>().firstWhere((f) => f['name'] == name);

  test('it answers the devfs.list op only', () {
    expect(ops.handles('devfs.list'), isTrue);
    expect(ops.handles('fs.list'), isFalse);
  });

  test('with no path it starts at the home folder of the user Cache runs as, and lists the subfolders by name, files left out', () async {
    for (final n in ['Pictures', 'documents', 'Music']) {
      Directory('${home.path}/$n').createSync();
    }
    File('${home.path}/notes.txt').writeAsStringSync('x');
    final r = await list();
    expect(r['path'], home.path);
    expect(r['home'], home.path);
    expect(r['parent'], '${tmp.path}/home');
    expect(r['kind'], 'none');
    expect(names(r), ['documents', 'Music', 'Pictures']); // not case-sensitive
  });

  test('a folder with .obsidian is an Obsidian vault and one with logseq/config.edn a Logseq graph; others are none', () async {
    Directory('${home.path}/Vault/.obsidian').createSync(recursive: true);
    File('${home.path}/Graph/logseq/config.edn')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    Directory('${home.path}/Plain').createSync();
    Directory('${home.path}/logseq-ish/logseq').createSync(recursive: true); // no config.edn: not a graph
    final r = await list();
    expect(kid(r, 'Vault')['kind'], 'obsidian');
    expect(kid(r, 'Graph')['kind'], 'logseq');
    expect(kid(r, 'Plain')['kind'], 'none');
    expect(kid(r, 'logseq-ish')['kind'], 'none');
    // and the folder itself is told its own kind
    expect((await list('${home.path}/Vault'))['kind'], 'obsidian');
    expect((await list('${home.path}/Graph'))['kind'], 'logseq');
    expect((await list(home.path))['kind'], 'none');
  });

  test('hidden folders are left out, even a vault\'s own .obsidian', () async {
    Directory('${home.path}/Vault/.obsidian').createSync(recursive: true);
    Directory('${home.path}/Vault/Daily').createSync();
    Directory('${home.path}/.cache').createSync();
    final r = await list();
    expect(names(r), ['Vault']);
    expect(names(await list('${home.path}/Vault')), ['Daily']);
  });

  test('a folder Cache cannot open is told readable: false, and listing it answers io_error', () async {
    final locked = Directory('${home.path}/Locked')..createSync();
    Directory('${home.path}/Open').createSync();
    // root can read anything: the check is only meaningful for another user
    if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') return;
    Process.runSync('chmod', ['000', locked.path]);
    try {
      final r = await list();
      expect(kid(r, 'Locked')['readable'], isFalse);
      expect(kid(r, 'Open')['readable'], isTrue);
      await expectLater(list(locked.path), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'io_error')));
    } finally {
      Process.runSync('chmod', ['755', locked.path]);
    }
  });

  test('a folder that is not there is not_found; a relative path is bad_path; a file is not a folder', () async {
    await expectLater(list('${home.path}/nope'), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'not_found')));
    await expectLater(list('Documents'), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'bad_path')));
    File('${home.path}/a.txt').writeAsStringSync('x');
    await expectLater(list('${home.path}/a.txt'), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'io_error')));
  });

  test('the parent goes up past home to "/", which has none', () async {
    final up = await list(home.parent.path);
    expect(up['parent'], tmp.path);
    expect(names(up), ['me']);
    final top = await list('/');
    expect(top['path'], '/');
    expect(top['parent'], isNull);
    expect(names(top), isNotEmpty);
    final one = await list('/tmp');
    expect(one['parent'], '/');
  });

  test('a path is cleaned: "..", "." and a trailing slash are resolved, so the browser never sees a path that is not the folder\'s own', () async {
    Directory('${home.path}/Docs').createSync();
    final r = await list('${home.path}/Docs/../Docs/./');
    expect(r['path'], '${home.path}/Docs');
    expect((await list('/../..'))['path'], '/');
  });

  test('a link to a folder is listed as a folder; a link to a file is not', () async {
    Directory('${tmp.path}/elsewhere/Notes').createSync(recursive: true);
    File('${tmp.path}/f.txt').writeAsStringSync('x');
    Link('${home.path}/Linked').createSync('${tmp.path}/elsewhere/Notes');
    Link('${home.path}/LinkedFile').createSync('${tmp.path}/f.txt');
    expect(names(await list()), ['Linked']);
  });
}
