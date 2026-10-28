import 'dart:io';

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
}
