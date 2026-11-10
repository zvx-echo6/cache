import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/browse/browse_screen.dart' show BrowseScreen, LibraryItemScreen;
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/zim_download.dart';
import 'package:cache/screens/libraries_screen.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';
import 'browse/web_fakes.dart';
import 'package:cache/browse/web/device_api.dart';
import 'package:cache/browse/web/device_library.dart';

// A "library file" in these tests is JSON standing in for a snapshot: {"fake_library":true,"docs":N,"settings":{...}|null,
// "guessable":bool,"whole":bool,"fails_to_open":bool}. The fake core below unpacks it into the folder as fake.json and answers
// for it as the real core does (the real core's jobs are tested in Rust, tests/libadd_ffi.rs).

Map<String, dynamic> _fakeAt(String shard) {
  final f = File('$shard/fake.json');
  return f.existsSync() ? (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>() : const {};
}

String _base(String p) => p.split(RegExp(r'[\\/]')).last;

Map<String, dynamic> _resolved(Map<String, dynamic>? settings, String dir, Map<String, dynamic> fake) {
  if (settings != null) {
    return {
      'format': 1,
      'library_id': settings['library_id'],
      'version': settings['version']?.toString(),
      'title': settings['title'] ?? settings['library_id'],
      'keyword_index': settings['keyword_index'] ?? 'auto',
      'guessed': false,
    };
  }
  return {'format': 1, 'library_id': _base(dir), 'version': null, 'title': _base(dir), 'keyword_index': 'auto', 'guessed': true};
}

Map<String, dynamic> _check(String shard, Map<String, dynamic>? settings, {String? source}) {
  final fake = _fakeAt(shard);
  final guessable = fake['guessable'] == true;
  final ok = settings != null || guessable;
  return {
    'segments': 1,
    'docs': fake['docs'] ?? 0,
    'settings': settings,
    'resolved': ok ? _resolved(settings, Directory(shard).parent.path, fake) : null,
    'settings_error': ok ? null : {'code': 'unsupported', 'message': 'cannot guess the library settings'},
    'whole_library_only': fake['whole'] ?? false,
    'own_text_index': false,
    if (source != null || settings == null) 'settings_source': source,
  };
}

class _LibNative implements CsNative {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  List<Map<String, dynamic>> sources = [];
  String? indexesDir;
  final Map<int, Map<String, dynamic>> jobs = {};
  int next = 0;
  String? err;

  @override
  int open(String configJson) {
    final c = jsonDecode(configJson) as Map;
    sources = [for (final s in (c['sources'] as List)) (s as Map).cast<String, dynamic>()];
    indexesDir = c['indexes_dir'] as String?;
    return 1;
  }

  @override
  int setSources(int handle, String configJson) => open(configJson) - 1;

  @override
  String? status(int handle) => jsonEncode({
        'sources': [
          for (final s in sources)
            if (s['kind'] == 'library') _libStatus(s) else {'id': s['path'], 'kind': 'zim', 'path': s['path'], 'title': 'z', 'indexed': true, 'docs': 1},
        ],
      });

  Map<String, dynamic> _libStatus(Map<String, dynamic> s) {
    final path = s['path'] as String;
    final fake = _fakeAt(path);
    final settings = (s['settings'] as Map?)?.cast<String, dynamic>();
    final dir = Directory(path).parent.path;
    if (fake['fails_to_open'] == true || !Directory(path).existsSync()) {
      return {'id': null, 'kind': 'library', 'path': path, 'title': _base(dir), 'docs': 0, 'error': {'code': 'io', 'message': 'cannot open'}};
    }
    final r = _resolved(settings, dir, fake);
    // "opening_reads": N: the core is still opening the library (on its background thread) for the next N status reads.
    final reads = (fake['opening_reads'] as int?) ?? 0;
    if (reads > 0) File('$path/fake.json').writeAsStringSync(jsonEncode({...fake, 'opening_reads': reads - 1}));
    return {
      'id': r['library_id'],
      'kind': 'library',
      'path': path,
      'title': r['title'],
      // Built in the old place, or a snapshot of the library in the indexes folder (built here, or synced in).
      'indexed': File('${s['index_dir']}/done').existsSync() ||
          (indexesDir != null && Directory('$indexesDir/library/${r['library_id']}/snap').existsSync()),
      'building': false,
      'opening': reads > 0,
      'updating': false,
      'docs': fake['docs'] ?? 0,
      'whole_library_only': fake['whole'] ?? false,
      'keyword_source': 'device',
      'error': null,
    };
  }

  @override
  String? lastError(int handle) => err;

  @override
  void close(int handle) {}

  @override
  int clearLocation(int handle) => 0;

  @override
  int jobStart(String kind, String paramsJson) {
    final p = (jsonDecode(paramsJson) as Map).cast<String, dynamic>();
    Map<String, dynamic> done(Map<String, dynamic>? detail) => {'state': 'done', 'done': 1, 'total': 1, 'error': null, 'detail': ?detail};
    Map<String, dynamic> result;
    switch (kind) {
      case 'unpack_library':
        final text = File(p['snapshot_path'] as String).readAsStringSync();
        Map<String, dynamic> fake;
        try {
          fake = (jsonDecode(text) as Map).cast<String, dynamic>();
        } catch (_) {
          err = jsonEncode({'code': 'io', 'message': 'the snapshot is not a tar archive: its first header has a bad checksum'});
          return 0;
        }
        final shard = p['dir'] as String;
        Directory(shard).createSync(recursive: true);
        File('$shard/fake.json').writeAsStringSync(jsonEncode(fake));
        for (final entry in ((fake['metadata'] as Map?) ?? const {}).entries) {
          File('$shard/${entry.key}').writeAsStringSync(entry.value as String);
        }
        final given = (p['settings'] as Map?)?.cast<String, dynamic>();
        final archive = (fake['settings'] as Map?)?.cast<String, dynamic>();
        result = done(_check(shard, given ?? archive, source: given != null ? 'given' : (archive != null ? 'archive' : null)));
      case 'check_library':
        result = done(_check(p['library_path'] as String, (p['settings'] as Map?)?.cast<String, dynamic>()));
      case 'index_library':
        if (p['indexes_dir'] != null) {
          // A snapshot of the library's source (its library_id) in the indexes folder; nothing in the old place.
          final id = ((p['settings'] as Map?)?['library_id'] ?? 'guessed') as String;
          File('${p['indexes_dir']}/library/$id/snap/b1/manifest.json').createSync(recursive: true);
          File('${p['indexes_dir']}/params.json').writeAsStringSync(paramsJson);
        } else {
          File('${p['index_dir']}/done').createSync(recursive: true);
        }
        result = done(null);
      case 'library_template':
        File(p['out_path'] as String).writeAsStringSync(jsonEncode({
          'fake_library': true,
          'docs': 0,
          'settings': {'format': 1, 'library_id': 'my-library', 'version': '1', 'title': 'My library', 'fields': {'text': 'text'}},
        }));
        result = done(null);
      default:
        err = jsonEncode({'code': 'bad_json', 'message': 'unknown job kind'});
        return 0;
    }
    jobs[++next] = result;
    return next;
  }

  @override
  String? jobProgress(int job) => jsonEncode(jobs[job]);

  @override
  int jobCancel(int job) => 0;

  @override
  void jobFree(int job) => jobs.remove(job);
}

CsNative _makeNative() => _LibNative();

/// A downloader that "downloads" by writing the bytes the test gives for each link.
class _FakeDownloader extends ZimDownloader {
  _FakeDownloader(this.files);

  final Map<String, String> files;
  final List<Uri> asked = [];

  @override
  Future<DownloadResult> download({
    required Uri url,
    required File part,
    Uri? sha256Url,
    Uri? md5Url,
    String? expectedSha256,
    void Function(int done, int total)? onProgress,
    void Function()? onVerifying,
    CancelToken? cancel,
  }) async {
    asked.add(url);
    final body = files[url.toString()];
    if (body == null) throw const DownloadException('That file is no longer on the download server.');
    onProgress?.call(1, 2);
    part.writeAsStringSync(body);
    onProgress?.call(2, 2);
    return DownloadResult(file: part, bytes: body.length, verified: false);
  }
}

String _lib({int docs = 3, String id = 'manuals', Object? version = '1', String title = 'Manuals', bool withSettings = true, bool guessable = true, bool whole = false, bool failsToOpen = false}) =>
    jsonEncode({
      'fake_library': true,
      'docs': docs,
      'settings': withSettings ? {'format': 1, 'library_id': id, 'version': version, 'title': title, 'fields': {'text': 'text'}} : null,
      'guessable': guessable,
      'whole': whole,
      'fails_to_open': failsToOpen,
    });

void main() {
  late Directory tmp;
  late SourcesState sources;
  late LibrariesState libs;
  late _FakeDownloader downloader;
  String? picked;
  final saved = <String, Uint8List>{};

  Future<void> setUpLibs({bool wifi = true, Future<File?> Function()? guide, String? indexesDir}) async {
    sources = SourcesState(
      zimsDirOverride: Directory('${tmp.path}/zims'),
      indexesDirOverride: Directory('${tmp.path}/indexes'),
      nativeFactory: _makeNative,
      coreExtras: {'indexes_dir': ?indexesDir},
    );
    downloader = _FakeDownloader({});
    libs = LibrariesState(
      sources: sources,
      policy: testPolicy(wifi: wifi),
      downloader: downloader,
      dirOverride: Directory('${tmp.path}/libraries'),
      tempDirOverride: Directory('${tmp.path}/tmp')..createSync(recursive: true),
      pickFile: () async => picked,
      saveBytes: (name, bytes) async {
        saved[name] = bytes;
        return true;
      },
      pollInterval: const Duration(milliseconds: 5),
      bundledGuide: guide,
    );
    await sources.init();
    await libs.init();
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('libraries');
    picked = null;
    saved.clear();
  });
  tearDown(() {
    libs.dispose();
    sources.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File libFile(String name, String body) => File('${tmp.path}/$name')..writeAsStringSync(body);
  List<String> folders() => [for (final d in Directory('${tmp.path}/libraries').listSync()) _base(d.path)]..sort();

  Future<bool> never(String n, String? a, String? b) async => fail('no update was expected');
  Future<String?> noSettings(String reason) async => fail('no settings file was expected');

  group('LibrariesState', () {
    test('a .cache-library file is added with its settings, indexed and ready; nothing is asked', () async {
      await setUpLibs();
      await libs.addFile(libFile('manuals.cache-library', _lib()), confirmUpdate: never, askSettings: noSettings);
      expect(libs.task, isNull);
      final l = libs.libraries.single;
      expect(l.folderName, 'manuals');
      expect(libs.phaseOf(l), LibraryPhase.ready);
      expect(libs.docsOf(l), 3);
      expect(libs.titleOf(l), 'Manuals');
      expect(libs.versionOf(l), '1');
      expect(File('${l.dir.path}/cache-library.json').existsSync(), isTrue);
      expect(Directory(l.indexPath).existsSync(), isTrue, reason: 'the keyword index is built when the library is added');
      expect(folders(), ['manuals'], reason: 'no hidden work folder is left');
      // The core is given the library as shard folder + index folder + settings.
      final c = l.config.toJson();
      expect(c['kind'], 'library');
      expect(c['path'], endsWith('shard'));
      expect(c['index_dir'], endsWith('index'));
      expect((c['settings'] as Map)['library_id'], 'manuals');
    });

    test('archive catalog, original identities and copies are installed beside settings', () async {
      await setUpLibs();
      const catalog = 'doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\n';
      final identities = jsonEncode({'version': 1, 'entries': []});
      const copies = '{"doc_id":"a","version":1,"copy":"a"}\n';
      final archive = (jsonDecode(_lib()) as Map).cast<String, dynamic>()
        ..['metadata'] = {'documents.tsv': catalog, 'source-identities.json': identities, 'copies.jsonl': copies};
      await libs.addFile(libFile('manuals.cache-library', jsonEncode(archive)),
          confirmUpdate: never, askSettings: noSettings);
      final library = libs.libraries.single;
      expect(libs.phaseOf(library), LibraryPhase.ready);
      expect(File('${library.path}/documents.tsv').readAsStringSync(), catalog);
      expect(File('${library.path}/source-identities.json').readAsStringSync(), identities);
      expect(File('${library.path}/copies.jsonl').readAsStringSync(), copies);
      for (final name in ['documents.tsv', 'source-identities.json', 'copies.jsonl']) {
        expect(File('${library.shardPath}/$name').existsSync(), isFalse);
      }
      expect(folders(), ['manuals']);
    });

    test('legacy archives without portable identity metadata still install', () async {
      await setUpLibs();
      await libs.addFile(libFile('legacy.cache-library', _lib()),
          confirmUpdate: never, askSettings: noSettings);
      final library = libs.libraries.single;
      expect(libs.phaseOf(library), LibraryPhase.ready);
      for (final name in ['documents.tsv', 'source-identities.json']) {
        expect(File('${library.path}/$name').existsSync(), isFalse);
        expect(File('${library.shardPath}/$name').existsSync(), isFalse);
      }
    });

    test('with an indexes folder the keyword index is built there, as a snapshot that syncs, not in the library', () async {
      final shared = Directory('${tmp.path}/shared-indexes')..createSync();
      await setUpLibs(indexesDir: shared.path);
      await libs.addFile(libFile('manuals.cache-library', _lib(id: 'manuals')), confirmUpdate: never, askSettings: noSettings);
      final l = libs.libraries.single;
      final params = jsonDecode(File('${shared.path}/params.json').readAsStringSync()) as Map;
      expect(params['indexes_dir'], shared.path);
      expect(params.containsKey('index_dir'), isFalse);
      expect(Directory('${shared.path}/library/manuals/snap').existsSync(), isTrue);
      expect(Directory(l.indexPath).existsSync(), isFalse, reason: 'nothing in the library\'s own index/');
      expect(libs.phaseOf(l), LibraryPhase.ready);
    });

    test('a plain snapshot without settings is guessed; when it cannot be, the settings file is asked for', () async {
      await setUpLibs();
      await libs.addFile(libFile('a.snapshot', _lib(withSettings: false)), confirmUpdate: never, askSettings: noSettings);
      expect(libs.libraries.single.settings, isNull, reason: 'guessed: nothing is stored, the core works them out');
      final settingsFile = libFile('cache-library.json', jsonEncode({'format': 1, 'library_id': 'notes', 'title': 'Notes', 'fields': {'text': 'text'}}));
      String? reason;
      await libs.addFile(libFile('b.snapshot', _lib(withSettings: false, guessable: false)), confirmUpdate: never, askSettings: (r) async {
        reason = r;
        return settingsFile.path;
      });
      expect(reason, contains('cannot guess'));
      expect(libs.libraries.map(libs.titleOf), containsAll(['Notes']));
      expect(libs.libraries.length, 2);
    });

    test('the same library_id again offers an update and swaps the copy in; declining keeps the old one', () async {
      await setUpLibs();
      await libs.addFile(libFile('m1.cache-library', _lib(version: '1')), confirmUpdate: never, askSettings: noSettings);
      final asked = <List<String?>>[];
      await libs.addFile(libFile('m2.cache-library', _lib(version: '2', docs: 9)), confirmUpdate: (n, a, b) async {
        asked.add([n, a, b]);
        return false;
      }, askSettings: noSettings);
      expect(asked, [
        ['Manuals', '1', '2'],
      ]);
      expect(libs.versionOf(libs.libraries.single), '1');
      expect(folders(), ['manuals']);
      await libs.addFile(libFile('m3.cache-library', _lib(version: 3, docs: 9)), confirmUpdate: (n, a, b) async => true, askSettings: noSettings);
      final l = libs.libraries.single;
      expect(libs.versionOf(l), '3');
      expect(libs.docsOf(l), 9);
      expect(libs.phaseOf(l), LibraryPhase.ready);
      expect(folders(), ['manuals'], reason: 'one library, no old copy left');
    });

    test('a new copy that does not open after the swap is undone and the old one kept', () async {
      await setUpLibs();
      await libs.addFile(libFile('m1.cache-library', _lib(version: '1')), confirmUpdate: never, askSettings: noSettings);
      await libs.addFile(libFile('bad.cache-library', _lib(version: '2', failsToOpen: true)), confirmUpdate: (n, a, b) async => true, askSettings: noSettings);
      expect(libs.task?.error, contains('kept as it was'));
      final l = libs.libraries.single;
      expect(libs.versionOf(l), '1');
      expect(libs.phaseOf(l), LibraryPhase.ready);
      expect(folders(), ['manuals']);
    });

    test('a file that is not a library says so and leaves nothing', () async {
      await setUpLibs();
      await libs.addFile(libFile('x.txt', 'hello'), confirmUpdate: never, askSettings: noSettings);
      expect(libs.task?.error, "This file isn't a Cache library.");
      expect(libs.libraries, isEmpty);
      expect(folders(), isEmpty);
    });

    test('the blank template says it is empty and needs filling, in plain words', () async {
      await setUpLibs();
      final f = File('${tmp.path}/cache-library-template.tar')
        ..writeAsBytesSync(_tar({'README.md': utf8.encode('# Template'), 'cache-library.json': utf8.encode('{}'), 'blank-library.snapshot': List.filled(700, 1)}));
      expect(tarEntryNames(f), ['README.md', 'cache-library.json', 'blank-library.snapshot']);
      await libs.addFile(f, confirmUpdate: never, askSettings: noSettings);
      expect(libs.task?.error, 'This is an empty library template. Fill it with your own entries first (see the README inside).');
      expect(libs.libraries, isEmpty);
    });

    test('the template written compressed (gzip) is still recognised as the template', () async {
      await setUpLibs();
      final f = File('${tmp.path}/cache-library-template.tar.gz')
        ..writeAsBytesSync(gzip.encode(_tar({'README.md': utf8.encode('# Template'), 'cache-library.json': utf8.encode('{}'), 'blank-library.snapshot': List.filled(700, 1)})));
      expect(tarEntryNames(f), ['README.md', 'cache-library.json', 'blank-library.snapshot']);
      expect(kLibraryTemplateName, endsWith('.tar.gz'));
    });

    test('the guide that ships in the app is installed on start, kept, and installed again when it is gone', () async {
      var copies = 0;
      await setUpLibs(guide: () async {
        copies++;
        return libFile('guide-$copies.cache-library', _lib(id: kGuideLibraryId, version: kGuideVersion, title: 'Cache guide'));
      });
      await libs.whenIdle();
      expect(libs.libraries.map(libs.titleOf), ['Cache guide']);
      expect(libs.isGuide(libs.libraries.single), isTrue);
      expect(copies, 1);
      await libs.ensureGuide();
      expect(copies, 1, reason: 'the same copy is there: nothing is done');
      await libs.remove(libs.libraries.single);
      expect(libs.libraries, isEmpty);
      await libs.ensureGuide();
      expect(libs.libraries.map(libs.titleOf), ['Cache guide']);
      expect(copies, 2);
    });

    test('a library the core is still opening at start is read again until it is open, then its index is resumed', () async {
      await setUpLibs();
      await libs.addFile(libFile('m.cache-library', _lib()), confirmUpdate: never, askSettings: noSettings);
      final shard = libs.libraries.single.shardPath;
      // The app is started again: the core opens the library on its own thread, so the first lists say it is opening, and the
      // keyword index was not finished before the app closed.
      libs.dispose();
      sources.dispose();
      File('$shard/fake.json').writeAsStringSync(jsonEncode({...jsonDecode(_lib()) as Map, 'opening_reads': 3}));
      Directory(libs.libraries.single.indexPath).deleteSync(recursive: true);
      await setUpLibs();
      await libs.whenIdle();
      final l = libs.libraries.single;
      expect(libs.statusOf(l)!.opening, isFalse, reason: 'nothing else reads the list again; the row must not stay on Getting ready');
      expect(libs.phaseOf(l), LibraryPhase.ready, reason: 'the index left unfinished is built once the library is open');
    });

    test('a library just added that the core is still opening is read again until it is open: no restart, no other change', () async {
      // Pixel testing: a newly added library stayed on "Getting ready" until the app was restarted or another library changed.
      await setUpLibs();
      final notified = <LibraryPhase>[];
      await libs.addFile(
        libFile('m.cache-library', jsonEncode({...jsonDecode(_lib()) as Map, 'opening_reads': 4})),
        confirmUpdate: never,
        askSettings: noSettings,
      );
      final l = libs.libraries.single;
      libs.addListener(() => notified.add(libs.phaseOf(libs.libraries.single)));
      await libs.whenIdle();
      expect(libs.statusOf(l)!.opening, isFalse, reason: 'the status is read again until the core has opened it');
      expect(libs.phaseOf(l), LibraryPhase.ready);
      expect(notified.last, LibraryPhase.ready, reason: 'the list is told, so the row leaves Getting ready at once');
    });

    test('a tar that is not a library, and a core error with internals, say so in plain words', () async {
      await setUpLibs();
      final f = File('${tmp.path}/photos.tar')..writeAsBytesSync(_tar({'a.jpg': List.filled(10, 2)}));
      await libs.addFile(f, confirmUpdate: never, askSettings: noSettings);
      expect(libs.task?.error, "This file isn't a Cache library.");
      expect(tarEntryNames(File('${tmp.path}/none')), isNull);
    });

    test('a download link is fetched into a hidden partial file and added; http is refused', () async {
      await setUpLibs();
      downloader.files['https://example.org/lib/manuals.cache-library'] = _lib();
      await libs.addLink('http://example.org/x', confirmUpdate: never, askSettings: noSettings);
      expect(libs.task?.error, contains('https://'));
      libs.dismissTask();
      await libs.addLink('https://example.org/lib/manuals.cache-library', confirmUpdate: never, askSettings: noSettings);
      expect(libs.task, isNull);
      expect(libs.titleOf(libs.libraries.single), 'Manuals');
      expect(Directory('${tmp.path}/libraries/.partial').listSync(), isEmpty, reason: 'the downloaded file is gone once added');
    });

    test('on mobile data with downloads on it off, a link waits for "Download anyway"', () async {
      await setUpLibs(wifi: false);
      downloader.files['https://example.org/m.cache-library'] = _lib();
      await libs.addLink('https://example.org/m.cache-library', confirmUpdate: never, askSettings: noSettings);
      expect(libs.task!.blockedByMobileData, isTrue);
      expect(downloader.asked, isEmpty);
      await libs.addLink('https://example.org/m.cache-library', confirmUpdate: never, askSettings: noSettings, anyway: true);
      expect(libs.libraries, hasLength(1));
    });

    test('a library a sync brings shows in the list as soon as the shared folder settles, with no restart', () async {
      await setUpLibs();
      await libs.addFile(libFile('manuals.cache-library', _lib()), confirmUpdate: never, askSettings: noSettings);
      final sync = _StatusSync();
      final sharing = SharingState(policy: testPolicy(wifi: true), supportDir: () async => tmp, kinds: const [], opener: (_) async => sync);
      final rescans = <Set<String>>[];
      sharing.onShareChanged = (ids) {
        rescans.add(ids);
        if (ids.contains('libraries')) unawaited(libs.rescan());
      };
      sync.share = {'id': 'libraries', 'files': 4, 'bytes': 1000, 'pending_files': 0};
      await sharing.setUp();
      expect(rescans, isEmpty, reason: 'the first look only notes where the folder stands');
      // A linked device starts sending a library: nothing is read while files are still coming.
      sync.share = {'id': 'libraries', 'files': 6, 'bytes': 1500, 'pending_files': 3};
      await sharing.refresh();
      expect(rescans, isEmpty);
      // The copy lands (as sync writes it: a whole folder) and the folder settles.
      _copyTree(Directory('${tmp.path}/libraries/manuals'), Directory('${tmp.path}/libraries/synced'));
      final settings = File('${tmp.path}/libraries/synced/cache-library.json');
      settings.writeAsStringSync(settings.readAsStringSync().replaceAll('"manuals"', '"synced"'));
      expect(libs.libraries.length, 1, reason: 'before: the list still shows what was there');
      sync.share = {'id': 'libraries', 'files': 9, 'bytes': 2000, 'pending_files': 0};
      await sharing.refresh();
      expect(rescans, [
        {'libraries'},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await libs.rescan();
      expect([for (final l in libs.libraries) l.folderName]..sort(), ['manuals', 'synced']);
      // Nothing new: no more reads.
      await sharing.refresh();
      expect(rescans.length, 1);
      sharing.dispose();
    });

    test('removing deletes the library and its index', () async {
      await setUpLibs();
      await libs.addFile(libFile('m.cache-library', _lib()), confirmUpdate: never, askSettings: noSettings);
      await libs.remove(libs.libraries.single);
      expect(libs.libraries, isEmpty);
      expect(folders(), isEmpty);
    });

    test('the blank template is made on the device, saved, and adds back as an empty ready library', () async {
      await setUpLibs();
      expect(await libs.saveTemplate(), isTrue);
      expect(saved.keys, [kLibraryTemplateName]);
      // add it back
      await libs.addFile(File('${tmp.path}/t.cache-library')..writeAsBytesSync(saved[kLibraryTemplateName]!), confirmUpdate: never, askSettings: noSettings);
      final l = libs.libraries.single;
      expect(libs.titleOf(l), 'My library');
      expect(libs.docsOf(l), 0);
      expect(libs.phaseOf(l), LibraryPhase.ready);
      expect(Directory('${tmp.path}/tmp').listSync(), isEmpty, reason: 'the template is made in a temporary folder that is removed');
    });

    test('leftovers of a cut-off add or swap are put right at start', () async {
      final dir = Directory('${tmp.path}/libraries')..createSync(recursive: true);
      Directory('${dir.path}/.add-123/shard').createSync(recursive: true);
      Directory('${dir.path}/.manuals.old/shard').createSync(recursive: true);
      File('${dir.path}/.manuals.old/shard/fake.json').writeAsStringSync(_lib());
      await setUpLibs();
      await libs.whenIdle();
      expect(folders(), ['manuals'], reason: 'the old copy came back because the new one never got into place');
    });
  });

  group('LibrariesScreen', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: LibrariesScreen(libraries: libs, pickSettingsFile: () async => null)));
      await tester.pumpAndSettle();
    }

    /// Lets the add run (files, the core's worker) and the screen catch up, until [until] holds.
    Future<void> settle(WidgetTester tester, bool Function() until) async {
      for (var i = 0; i < 200 && !until(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pump();
    }

    testWidgets('Your own library: add from a file; the library is ready with its entries', (tester) async {
      await tester.runAsync(setUpLibs);
      picked = libFile('manuals.cache-library', _lib(docs: 1)).path;
      await pump(tester);
      expect(find.text('Your own library'), findsOneWidget);
      expect(find.text('From a download link'), findsOneWidget);
      expect(find.byKey(const ValueKey('library-template')), findsOneWidget, reason: 'the blank template lives here');
      await tester.tap(find.byKey(const ValueKey('add-from-file')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester, () => libs.libraries.isNotEmpty && libs.task == null);
      expect(libs.titleOf(libs.libraries.single), 'Manuals');
      expect(libs.versionOf(libs.libraries.single), '1');
      expect(libs.docsOf(libs.libraries.single), 1);
    });

    testWidgets('add from a download link', (tester) async {
      await tester.runAsync(setUpLibs);
      downloader.files['https://example.org/manuals.cache-library'] = _lib(docs: 2);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('add-from-link')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byKey(const ValueKey('library-link')), 'https://example.org/manuals.cache-library');
      await tester.tap(find.byKey(const ValueKey('download-library')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester, () => libs.libraries.isNotEmpty && libs.task == null);
      expect(libs.docsOf(libs.libraries.single), 2);
    });

    testWidgets('the same library again is offered as an update with both versions', (tester) async {
      await tester.runAsync(() async {
        await setUpLibs();
        await libs.addFile(libFile('m1.cache-library', _lib(version: '1')), confirmUpdate: never, askSettings: noSettings);
      });
      picked = libFile('m2.cache-library', _lib(version: '2', docs: 5)).path;
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('add-from-file')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester, () => find.byKey(const ValueKey('update-library')).evaluate().isNotEmpty);
      expect(find.text('Update Manuals (version 1 → version 2)?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-library')));
      await tester.pump();
      await settle(tester, () => libs.task == null && libs.libraries.isNotEmpty && libs.versionOf(libs.libraries.single) == '2');
      expect(libs.docsOf(libs.libraries.single), 5);
      expect(libs.libraries, hasLength(1));
    });

    testWidgets('the Library calls the guide that ships in the app built in, and a library the person added their own', (tester) async {
      late BrowseState browse;
      await tester.runAsync(() async {
        await setUpLibs(guide: () async => libFile('guide.cache-library', _lib(id: kGuideLibraryId, version: kGuideVersion, title: 'Cache guide')));
        await libs.addFile(libFile('m.cache-library', _lib(docs: 2)), confirmUpdate: never, askSettings: noSettings);
        await libs.whenIdle();
        browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
        await browse.init();
      });
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: BrowseScreen(browse: browse, active: true)));
      await tester.pump();
      // The 1.1 Library: every library is a search index in Catalog, the guide built in, the person's own under Your own.
      await tester.tap(find.byKey(const ValueKey('library-catalog')));
      await tester.pumpAndSettle();
      expect(find.text('Ready · Built in'), findsOneWidget, reason: 'the guide is not one of the person\'s own');
      expect(find.text('Ready · 2 entries'), findsOneWidget);
      expect(find.text('YOUR OWN'), findsOneWidget);
      expect(find.text('Getting ready'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      browse.dispose();
    });

    testWidgets('the template action saves the blank template', (tester) async {
      await tester.runAsync(setUpLibs);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('library-template')));
      await tester.pump();
      await settle(tester, () => saved.isNotEmpty && !libs.makingTemplate);
      expect(saved.keys, [kLibraryTemplateName]);
      expect(find.text('Template saved. Its README says how to fill it.'), findsOneWidget);
    });

    testWidgets('an opened library shows what it holds, says when it can only be replaced as a whole, and has the "..." menu', (tester) async {
      await tester.runAsync(() async {
        await setUpLibs();
        await libs.addFile(libFile('m.cache-library', _lib(whole: true)), confirmUpdate: never, askSettings: noSettings);
      });
      var menus = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: LibraryItemScreen(libraries: libs, item: libs.libraries.single, menu: (_) async => menus++),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Manuals'), findsOneWidget);
      expect(find.text('Whole library only'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('item-menu')));
      await tester.pump();
      expect(menus, 1);
    });
  });

  // The browser's Library: the app's own install procedure run against the device's files (AppFs) and core, with the same prompts.
  group('LibrariesState on the device (in a browser)', () {
    late FakeDeviceApi api;
    late DeviceLibrary device;
    late Directory docs;
    late Directory support;

    Future<void> setUpDevice() async {
      docs = Directory('${tmp.path}/docs')..createSync(recursive: true);
      support = Directory('${tmp.path}/support')..createSync(recursive: true);
      api = FakeDeviceApi();
      // The "device" lists what is in its libraries folder, forgets a library when asked, and counts the rescans.
      api.onRemove = (id) => Directory('${docs.path}/libraries/${id.substring('library-'.length)}').deleteSync(recursive: true);
      device = DeviceLibrary(api: _FolderApi(api, docs), fs: diskFs(support, docs), leaveWarning: (_) {});
      sources = SourcesState(
        zimsDirOverride: Directory('${tmp.path}/zims'),
        indexesDirOverride: Directory('${tmp.path}/indexes'),
        nativeFactory: _makeNative,
        coreExtras: const {},
      );
      libs = LibrariesState(
        sources: sources,
        device: device,
        appFs: diskFs(support, docs),
        saveBytes: (name, bytes) async {
          saved[name] = bytes;
          return true;
        },
        pollInterval: const Duration(milliseconds: 5),
      );
      await sources.init();
      await libs.init();
    }

    File incoming(String name, String body) => touch('${docs.path}/incoming/$name', body) ;
    List<String> inLibs() => [for (final d in Directory('${docs.path}/libraries').listSync()) _base(d.path)]..sort();
    Future<bool> never(String n, String? a, String? b) async => fail('no update was expected');
    Future<String?> noSettings(String reason) async => fail('no settings file was expected');

    test('an uploaded package is added from the docs root: unpacked, indexed, put in place, the package deleted, the core told', () async {
      await setUpDevice();
      incoming('manuals.cache-library', _lib());
      await libs.addDeviceFile('manuals.cache-library', confirmUpdate: never, askSettings: noSettings);
      expect(libs.task, isNull);
      final l = libs.libraries.single;
      expect(l.folderName, 'manuals');
      expect(l.path, '${docs.path}/libraries/manuals');
      expect(libs.phaseOf(l), LibraryPhase.ready);
      expect(libs.docsOf(l), 3);
      expect(File('${docs.path}/libraries/manuals/cache-library.json').existsSync(), isTrue);
      expect(inLibs(), ['manuals'], reason: 'no hidden work folder is left');
      expect(File('${docs.path}/incoming/manuals.cache-library').existsSync(), isFalse);
      expect(api.rescans, greaterThan(0));
    });

    test('the same library again asks about the update, swaps it in through the device, and keeps the old one when it will not open', () async {
      await setUpDevice();
      incoming('m1.cache-library', _lib(version: '1'));
      await libs.addDeviceFile('m1.cache-library', confirmUpdate: never, askSettings: noSettings);
      final asked = <List<String?>>[];
      incoming('m2.cache-library', _lib(version: '2', docs: 9));
      await libs.addDeviceFile('m2.cache-library', confirmUpdate: (n, a, b) async {
        asked.add([n, a, b]);
        return true;
      }, askSettings: noSettings);
      expect(asked, [
        ['Manuals', '1', '2'],
      ]);
      expect(libs.versionOf(libs.libraries.single), '2');
      expect(libs.docsOf(libs.libraries.single), 9);
      expect(inLibs(), ['manuals'], reason: 'no old copy left');
      incoming('bad.cache-library', _lib(version: '3', failsToOpen: true));
      await libs.addDeviceFile('bad.cache-library', confirmUpdate: (n, a, b) async => true, askSettings: noSettings);
      expect(libs.task?.error, contains('kept as it was'));
      expect(libs.versionOf(libs.libraries.single), '2');
      expect(libs.phaseOf(libs.libraries.single), LibraryPhase.ready);
      expect(inLibs(), ['manuals']);
    });

    test('a settings file the core cannot do without is asked for, then read from the device', () async {
      await setUpDevice();
      final settings = incoming('s.json', jsonEncode({'format': 1, 'library_id': 'notes', 'title': 'Notes', 'fields': {'text': 'text'}}));
      incoming('b.snapshot', _lib(withSettings: false, guessable: false));
      String? reason;
      await libs.addDeviceFile('b.snapshot', confirmUpdate: never, askSettings: (r) async {
        reason = r;
        return settings.path;
      });
      expect(reason, contains('cannot guess'));
      expect(libs.titleOf(libs.libraries.single), 'Notes');
    });

    test('a file that is not a library, and the blank template, say so; nothing is left on the device', () async {
      await setUpDevice();
      incoming('x.txt', 'hello');
      await libs.addDeviceFile('x.txt', confirmUpdate: never, askSettings: noSettings);
      expect(libs.task?.error, "This file isn't a Cache library.");
      libs.dismissTask();
      incoming('cache-library-template.tar.gz', 'not json');
      await libs.addDeviceFile('cache-library-template.tar.gz', confirmUpdate: never, askSettings: noSettings);
      expect(libs.task?.error, startsWith('This is an empty library template.'));
      expect(libs.libraries, isEmpty);
      expect(inLibs(), isEmpty);
    });

    test('remove goes through the device, and a download link is a device download that waits as a package', () async {
      await setUpDevice();
      incoming('manuals.cache-library', _lib());
      await libs.addDeviceFile('manuals.cache-library', confirmUpdate: never, askSettings: noSettings);
      await libs.remove(libs.libraries.single);
      expect(api.removed, ['library-manuals']);
      expect(libs.libraries, isEmpty);
      await libs.addLink('http://example.org/x', confirmUpdate: never, askSettings: noSettings);
      expect(libs.task?.error, contains('https://'));
      libs.dismissTask();
      await libs.addLink('https://example.org/lib/pack.cache-library', confirmUpdate: never, askSettings: noSettings);
      expect(api.downloads.single['kind'], 'library');
      expect(api.downloads.single['url'], 'https://example.org/lib/pack.cache-library');
    });

    test('work a cut-off add left on the device is cleaned up or put back at start', () async {
      docs = Directory('${tmp.path}/docs')..createSync(recursive: true);
      touch('${docs.path}/libraries/.add-5/shard/x', '1');
      touch('${docs.path}/libraries/.manuals.old/shard/fake.json', _lib());
      await setUpDevice();
      expect(inLibs(), ['manuals'], reason: 'the half-made one is gone and the old copy is back');
    });

    test('the blank template is made on the device and handed to the browser\'s save', () async {
      await setUpDevice();
      expect(await libs.saveTemplate(), isTrue);
      expect(saved.keys, [kLibraryTemplateName]);
      expect(Directory('${docs.path}/incoming').listSync().where((e) => _base(e.path).startsWith('.template')), isEmpty);
    });
  });
}

/// A ustar archive of [files] (name to bytes), as the template's tar.
List<int> _tar(Map<String, List<int>> files) {
  final out = <int>[];
  for (final e in files.entries) {
    final h = List<int>.filled(512, 0);
    void put(int at, String v) => h.setRange(at, at + v.length, v.codeUnits);
    put(0, e.key);
    put(100, '0000644\x00');
    put(108, '0000000\x00');
    put(116, '0000000\x00');
    put(124, '${e.value.length.toRadixString(8).padLeft(11, '0')}\x00');
    put(136, '00000000000\x00');
    h[156] = 0x30;
    put(257, 'ustar\x0000');
    h.setRange(148, 156, List.filled(8, 32));
    final sum = h.fold<int>(0, (a, b) => a + b);
    put(148, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ');
    out
      ..addAll(h)
      ..addAll(e.value)
      ..addAll(List.filled((512 - e.value.length % 512) % 512, 0));
  }
  return out..addAll(List.filled(1024, 0));

}

/// A sync engine whose status lists one shared folder as the test sets it.
class _StatusSync implements SyncCoreLike {
  Map<String, Object?>? share;

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async =>
      method == 'status' ? {'name': 'Test phone', 'shares': [?share], 'peers': const [], 'offers': const []} : {'ok': true};

  @override
  Future<void> close() async {}
}

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync()) {
    final name = e.path.split(RegExp(r'[\\/]')).last;
    if (e is Directory) {
      _copyTree(e, Directory('${to.path}/$name'));
    } else if (e is File) {
      e.copySync('${to.path}/$name');
    }
  }
}

/// The device's answers about its libraries come from its folder; everything else is the fake's.
class _FolderApi extends FakeDeviceApiView {
  _FolderApi(super.inner, this.docs);

  final Directory docs;

  @override
  Future<List<DeviceItem>> items() async {
    final libs = Directory('${docs.path}/libraries');
    if (!libs.existsSync()) return const [];
    return [
      for (final d in libs.listSync().whereType<Directory>())
        if (!_base(d.path).startsWith('.') && Directory('${d.path}/shard').existsSync())
          DeviceItem(id: 'library-${_base(d.path)}', kind: 'library', name: _base(d.path), title: _base(d.path), bytes: 10, path: 'app/docs/libraries/${_base(d.path)}'),
    ];
  }
}
