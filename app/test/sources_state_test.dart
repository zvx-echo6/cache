import 'dart:io';
import 'dart:typed_data';

import 'package:cache/browse/opds.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';

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
}
