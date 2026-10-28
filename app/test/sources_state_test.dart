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
}
