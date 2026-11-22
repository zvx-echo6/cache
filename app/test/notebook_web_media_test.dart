import 'dart:io';
import 'dart:typed_data';

import 'package:cache/app_fs.dart';
import 'package:cache/notebook/media.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/web_fakes.dart';

void main() {
  late Directory tmp;
  late AppFs fs;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nb-staged-');
    fs = diskFs(Directory('${tmp.path}/support')..createSync(), Directory('${tmp.path}/docs')..createSync());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('picked bytes reach the core as files with their own names, and are removed after', () async {
    late List<String> seen;
    final r = await withStagedFiles(
      [(name: 'a.kml', bytes: Uint8List.fromList([1, 2, 3])), (name: 'C:\\x/we ird:.csv', bytes: Uint8List.fromList([4]))],
      (paths) async {
        seen = paths;
        expect(File(paths[0]).readAsBytesSync(), [1, 2, 3]);
        expect(File(paths[1]).readAsBytesSync(), [4]);
        return paths.length;
      },
      fs: fs,
    );
    expect(r, 2);
    expect(seen[0].endsWith('/a.kml'), isTrue);
    expect(seen[1].endsWith('/we ird_.csv'), isTrue);
    expect(seen.every((p) => p.startsWith('${tmp.path}/support/import-tmp/')), isTrue);
    expect(Directory('${tmp.path}/support/import-tmp').listSync(), isEmpty);
  });

  test('the staged files are removed when the core fails', () async {
    await expectLater(withStagedFiles([(name: 'a.gpx', bytes: Uint8List(1))], (_) async => throw StateError('bad'), fs: fs), throwsStateError);
    expect(Directory('${tmp.path}/support/import-tmp').listSync(), isEmpty);
  });
}
