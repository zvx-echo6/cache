import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/browse/opds.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';

/// The core as far as indexing goes: every source it is given is open and indexed, except one whose name has "slow" in it,
/// whose index job never ends.
class _IndexNative implements CsNative {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  List<String> paths = [];
  int jobs = 0;

  List<String> _paths(String configJson) => [
        for (final s in ((jsonDecode(configJson) as Map)['sources'] as List? ?? const [])) (s as Map)['path'] as String,
      ];

  @override
  int open(String configJson) {
    paths = _paths(configJson);
    return 1;
  }

  @override
  int setSources(int handle, String configJson) {
    paths = _paths(configJson);
    return 0;
  }

  @override
  String? status(int handle) => jsonEncode({
        'sources': [
          for (final p in paths)
            {'id': p, 'kind': 'zim', 'path': p, 'title': p, 'indexed': !p.contains('slow'), 'building': false, 'docs': 1},
        ],
      });

  @override
  String? lastError(int handle) => null;

  @override
  void close(int handle) {}

  @override
  int clearLocation(int handle) => 0;

  @override
  int jobStart(String kind, String paramsJson) => ++jobs;

  @override
  String? jobProgress(int job) => jsonEncode({'state': 'running', 'done': 0, 'total': 1});

  @override
  int jobCancel(int job) => 0;

  @override
  void jobFree(int job) {}
}

CsNative _makeIndexNative() => _IndexNative();

/// A core that does not open while the file its config names in "fail_while" exists (the worker isolate cannot share memory
/// with the test, so the switch is a file).
class _FlakyNative extends _IndexNative {
  @override
  int open(String configJson) {
    if (File((jsonDecode(configJson) as Map)['fail_while'] as String).existsSync()) return 0;
    return super.open(configJson);
  }

  @override
  String? lastError(int handle) => jsonEncode({'code': 'internal', 'message': 'the core could not open'});
}

CsNative _makeFlakyNative() => _FlakyNative();

/// A core that writes each config cs_set_sources is given into its indexes folder (the worker isolate cannot share memory with
/// the test), and reports a source id for every source.
class _RecordingNative extends _IndexNative {
  @override
  int setSources(int handle, String configJson) {
    final dir = (jsonDecode(configJson) as Map)['indexes_dir'];
    if (dir is String) File('$dir/set_sources.json').writeAsStringSync(configJson);
    return super.setSources(handle, configJson);
  }

  @override
  String? status(int handle) => jsonEncode({
        'sources': [
          for (final p in paths)
            {'id': 'u-$p', 'kind': 'zim', 'path': p, 'title': p, 'indexed': true, 'building': false, 'docs': 1, 'source_id': 'u-${p.split('/').last}'},
        ],
      });
}

CsNative _makeRecordingNative() => _RecordingNative();

/// A core whose ZIMs with "pic" in their name have an illustration (the PNG signature and four more bytes).
class _IllustrationNative extends _IndexNative implements CsZimIconNative {
  static const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4];

  @override
  bool get hasZimIllustration => true;

  @override
  String? zimIllustration(int handle, String zimId) => zimId.split('/').last.contains('pic') ? jsonEncode({'png_base64': base64Encode(png)}) : null;

  @override
  String? lastError(int handle) => jsonEncode({'code': 'not_found', 'message': 'no illustration'});
}

CsNative _makeIllustrationNative() => _IllustrationNative();

void main() {
  late Directory tmp;
  late Directory zims;
  late FakeSources sources;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sources');
    zims = Directory('${tmp.path}/zims')..createSync();
    sources = FakeSources(zims);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// What is in the sources folder besides the partial folder, by name.
  List<String> names() => [
        for (final e in zims.listSync())
          if (e.path.split(RegExp(r'[\\/]')).last != '.partial') e.path.split(RegExp(r'[\\/]')).last,
      ]..sort();

  List<FileSystemEntity> partials() => sources.partialDir.existsSync() ? sources.partialDir.listSync() : [];

  group('adding a ZIM', () {
    test('the copy lands whole at its name and leaves no temp file behind', () async {
      final src = File('${tmp.path}/wiki.zim')..writeAsBytesSync(List.generate(300000, (i) => i & 0xff));
      await sources.addZim(src);
      expect(sources.error, isNull);
      expect(names(), ['wiki.zim']);
      expect(File('${zims.path}/wiki.zim').readAsBytesSync(), src.readAsBytesSync());
      expect(partials(), isEmpty);
      expect(sources.zims.single.fileName, 'wiki.zim');
    });

    test('a copy that fails leaves nothing at the final name, and an earlier file of that name is kept', () async {
      final old = File('${zims.path}/wiki.zim')..writeAsBytesSync([1, 2, 3]);
      await sources.addZim(File('${tmp.path}/missing.zim'), name: 'wiki.zim');
      expect(sources.error, contains('Could not copy'));
      expect(sources.copyProgress, isNull);
      expect(old.readAsBytesSync(), [1, 2, 3]);
      expect(names(), ['wiki.zim']);
      expect(partials(), isEmpty);
    });

    test('a file that is not a .zim is refused', () async {
      await sources.addZim(File('${tmp.path}/notes.txt')..writeAsStringSync('x'));
      expect(sources.error, contains('not a .zim'));
      expect(names(), isEmpty);
    });
  });

  group('installing a download', () {
    CatalogEntry entry() => CatalogEntry(
          id: 'e-1',
          title: 'Wikivoyage - Europe',
          summary: '',
          language: 'eng',
          name: 'wikivoyage_en_europe',
          flavour: 'nopic',
          category: 'wikivoyage',
          tags: const [],
          updated: '2026-09-14',
          size: 4,
          articleCount: 1,
          downloadUrl: Uri.parse('http://127.0.0.1:1/zim/wikivoyage_en_europe_nopic_2026-09.zim'),
          iconUrl: null,
        );

    test('the file, its origin and its icon are put in place with no temp file left in the folder', () async {
      sources.partialDir.createSync(recursive: true);
      final part = File('${sources.partialDir.path}/wikivoyage_en_europe_nopic_2026-09.zim.part')..writeAsBytesSync([5, 6, 7, 8]);
      final z = await sources.installDownloaded(part, entry: entry(), icon: Uint8List.fromList([1, 2, 3]), fileName: 'wikivoyage_en_europe_nopic_2026-09.zim');
      expect(names(), [
        'wikivoyage_en_europe_nopic_2026-09.zim',
        'wikivoyage_en_europe_nopic_2026-09.zim.icon.png',
        'wikivoyage_en_europe_nopic_2026-09.zim.origin.json',
      ]);
      expect(File(z.path).readAsBytesSync(), [5, 6, 7, 8]);
      expect(sources.originOf(z)!.catalogId, 'e-1');
      expect(sources.iconOf(z)!.readAsBytesSync(), [1, 2, 3]);
      expect(partials(), isEmpty);
    });

    test('a file of the same name is replaced by the new one', () async {
      File('${zims.path}/wikivoyage_en_europe_nopic_2026-09.zim').writeAsBytesSync([9]);
      sources.partialDir.createSync(recursive: true);
      final part = File('${sources.partialDir.path}/wikivoyage_en_europe_nopic_2026-09.zim.part')..writeAsBytesSync([5, 6, 7, 8]);
      final z = await sources.installDownloaded(part, fileName: 'wikivoyage_en_europe_nopic_2026-09.zim');
      expect(File(z.path).readAsBytesSync(), [5, 6, 7, 8]);
      expect(names(), ['wikivoyage_en_europe_nopic_2026-09.zim']);
      expect(part.existsSync(), isFalse);
    });

    test('a finished file from another folder is moved in the same way', () async {
      final elsewhere = File('${tmp.path}/w.zim')..writeAsBytesSync([4, 4]);
      final z = await sources.installDownloaded(elsewhere);
      expect(File(z.path).readAsBytesSync(), [4, 4]);
      expect(names(), ['w.zim']);
      expect(elsewhere.existsSync(), isFalse);
    });
  });

  test('a core that could not start is started again by retryCore (Try again), and what waits on it then goes on', () async {
    final failing = File('${tmp.path}/fail')..writeAsStringSync('');
    final s = SourcesState(
      zimsDirOverride: zims,
      indexesDirOverride: Directory('${tmp.path}/indexes'),
      nativeFactory: _makeFlakyNative,
      coreExtras: {'fail_while': failing.path},
    );
    addTearDown(s.dispose);
    var opened = false;
    unawaited(s.whenCoreOpen().then((_) => opened = true));
    await s.init();
    expect(s.coreReady, isFalse);
    expect(s.unavailable, 'the core could not open');
    expect(await s.whenCoreReady(), isNull);
    // still failing: Try again fails again, and says so
    expect(await s.retryCore(), isNull);
    expect(opened, isFalse);
    // the cause is gone: Try again opens it, and everything waiting on the core sees it
    failing.deleteSync();
    final again = s.retryCore();
    expect(identical(s.retryCore(), again), isTrue, reason: 'a second tap shares the start that is running');
    final core = await again;
    expect(core, isNotNull);
    expect(s.coreReady, isTrue);
    expect(s.unavailable, isNull);
    expect(await s.whenCoreReady(), same(core));
    await Future<void>.delayed(Duration.zero);
    expect(opened, isTrue);
    expect(await s.retryCore(), same(core), reason: 'an open core is not started again');
    await s.refresh(); // the list the retry reads in the background, done before the state goes
  });

  test('the index of a ZIM that is gone is deleted, but not one a job is still building, nor other folders', () async {
    final indexes = Directory('${tmp.path}/indexes')..createSync();
    File('${zims.path}/a.zim').writeAsBytesSync([0]);
    final slow = File('${zims.path}/slow.zim')..writeAsBytesSync([0]);
    for (final n in ['a.zim.idx', 'gone.zim.idx', 'slow.zim.idx', 'notes']) {
      File('${indexes.path}/$n/data').createSync(recursive: true);
    }
    final s = SourcesState(zimsDirOverride: zims, indexesDirOverride: indexes, nativeFactory: _makeIndexNative, coreExtras: const {});
    addTearDown(s.dispose);
    await s.init();
    expect(s.phaseOf(s.zims.firstWhere((z) => z.fileName == 'slow.zim')), ZimPhase.indexing);
    List<String> left() => [for (final d in indexes.listSync()) d.path.split(RegExp(r'[\\/]')).last]..sort();
    expect(left(), ['a.zim.idx', 'notes', 'slow.zim.idx']);

    // Its ZIM is deleted while the job runs: the index stays until the job is over.
    slow.deleteSync();
    await s.refresh();
    expect(s.zims.map((z) => z.fileName), ['a.zim']);
    expect(left(), ['a.zim.idx', 'notes', 'slow.zim.idx']);
  });

  test('the core is given the indexes folder again each time its sources are set, and says which source is which', () async {
    final indexes = Directory('${tmp.path}/shared-indexes')..createSync();
    File('${zims.path}/a.zim').writeAsBytesSync([1]);
    final s = SourcesState(
      zimsDirOverride: zims,
      indexesDirOverride: Directory('${tmp.path}/indexes'),
      nativeFactory: _makeRecordingNative,
      coreExtras: {'indexes_dir': indexes.path},
    );
    addTearDown(s.dispose);
    await s.init();
    final seen = jsonDecode(File('${indexes.path}/set_sources.json').readAsStringSync()) as Map;
    expect(seen['indexes_dir'], indexes.path, reason: 'cs_set_sources replaces indexes_dir, so it comes every time');
    expect(s.statuses.single.sourceId, 'u-a.zim');
  });

  test("a ZIM with no saved icon shows the one inside the ZIM, read once and kept; a ZIM without one keeps its letter", () async {
    File('${zims.path}/pic.zim').writeAsBytesSync([0]);
    File('${zims.path}/plain.zim').writeAsBytesSync([0]);
    File('${zims.path}/saved-pic.zim').writeAsBytesSync([0]);
    File('${zims.path}/saved-pic.zim.icon.png').writeAsBytesSync([9, 9]);
    final s = SourcesState(zimsDirOverride: zims, indexesDirOverride: Directory('${tmp.path}/indexes'), nativeFactory: _makeIllustrationNative, coreExtras: const {});
    addTearDown(s.dispose);
    await s.init();
    ZimFile zim(String n) => s.zims.firstWhere((z) => z.fileName == n);

    var told = 0;
    s.addListener(() => told++);
    expect(s.iconOf(zim('pic.zim')), isNull, reason: 'the list does not wait for it');
    for (var i = 0; i < 100 && !File('${zims.path}/pic.zim.illustration.png').existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(told, greaterThan(0), reason: 'the rows are told when it arrives');
    final own = s.iconOf(zim('pic.zim'))!;
    expect(own.path, '${zims.path}/pic.zim.illustration.png');
    expect(own.readAsBytesSync(), _IllustrationNative.png);

    // The catalogue's (or the person's) icon is kept over the ZIM's own; the ZIM without one has no file and stays a letter.
    expect(s.iconOf(zim('saved-pic.zim'))!.path, '${zims.path}/saved-pic.zim.icon.png');
    expect(s.iconOf(zim('plain.zim')), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(File('${zims.path}/plain.zim.illustration.png').existsSync(), isFalse);
    expect(File('${zims.path}/saved-pic.zim.illustration.png').existsSync(), isFalse);

    // Deleting the ZIM takes the cached picture with it.
    await s.remove(zim('pic.zim'));
    expect(File('${zims.path}/pic.zim.illustration.png').existsSync(), isFalse);
  });

  group('the browser takes the server features', () {
    test('every extras section comes through, routing and places included (so nav.available turns on)', () {
      final extras = SourcesState.webExtrasFrom({
        'routing': {'available': true, 'shim': '/opt/libvalhalla_shim.so'},
        'places': {'available': false, 'merged_dir': '/s/regions/places'},
        'extras': {
          'layers': {'dir': '/s/layers'},
          'places': {'merged_dir': '/s/regions/places'},
          'routing': {'valhalla': {'shim': '/opt/libvalhalla_shim.so'}},
        },
      });
      expect(extras.keys, containsAll(['layers', 'places', 'routing']));
      expect(extras.containsKey('routing'), isTrue);
    });

    test('a server without a road router leaves routing out, as a phone without one does', () {
      final extras = SourcesState.webExtrasFrom({
        'routing': {'available': false, 'shim': ''},
        'extras': {'layers': {'dir': '/s/layers'}},
      });
      expect(extras.containsKey('routing'), isFalse);
      expect(extras['layers'], {'dir': '/s/layers'});
    });

    test('an odd reply gives empty extras', () {
      expect(SourcesState.webExtrasFrom(null), isEmpty);
      expect(SourcesState.webExtrasFrom({'routing': {}}), isEmpty);
      expect(SourcesState.webExtrasFrom('x'), isEmpty);
    });
  });
}
