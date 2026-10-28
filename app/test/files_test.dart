import 'dart:io';

import 'package:cache/files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('files'));
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> names() => [for (final e in dir.listSync()) e.path.split(RegExp(r'[\\/]')).last]..sort();

  test('the temp file is hidden and next to the file it is for', () {
    final t = hiddenTempFor(File('${dir.path}/settings.json'));
    expect(t.parent.path, dir.path);
    expect(t.path.split(RegExp(r'[\\/]')).last, startsWith('.settings.json.'));
    expect(hiddenTempFor(File('${dir.path}/settings.json')).path, isNot(t.path), reason: 'two writes never share a temp');
  });

  test('a write creates the file, a second replaces it, and no temp file is left', () async {
    final f = File('${dir.path}/settings.json');
    await writeStringAtomic(f, '{"a":1}');
    expect(f.readAsStringSync(), '{"a":1}');
    await writeStringAtomic(f, '{"a":2}');
    expect(f.readAsStringSync(), '{"a":2}');
    writeStringAtomicSync(f, '{"a":3}');
    expect(f.readAsStringSync(), '{"a":3}');
    await writeBytesAtomic(File('${dir.path}/icon.png'), [1, 2, 3]);
    expect(File('${dir.path}/icon.png').readAsBytesSync(), [1, 2, 3]);
    expect(names(), ['icon.png', 'settings.json']);
  });

  test('writes that overlap each end whole', () async {
    final f = File('${dir.path}/settings.json');
    await Future.wait([for (var i = 0; i < 20; i++) writeStringAtomic(f, 'value $i')]);
    expect(f.readAsStringSync(), matches(RegExp(r'^value \d+$')));
    expect(names(), ['settings.json']);
  });

  test('a write that cannot be put in place throws and leaves no temp file', () async {
    final f = File('${dir.path}/settings.json')..writeAsStringSync('old');
    // A folder where the file should be: the rename over it fails.
    final blocked = Directory('${dir.path}/blocked')..createSync();
    Directory('${blocked.path}/x').createSync();
    await expectLater(writeStringAtomic(File(blocked.path), 'new'), throwsA(isA<FileSystemException>()));
    expect(() => writeStringAtomicSync(File(blocked.path), 'new'), throwsA(isA<FileSystemException>()));
    expect(f.readAsStringSync(), 'old');
    expect(names(), ['blocked', 'settings.json']);
  });

  test('a rename puts the file over an existing one', () async {
    final a = File('${dir.path}/a')..writeAsStringSync('new');
    File('${dir.path}/b').writeAsStringSync('old');
    await renameOver(a, '${dir.path}/b');
    expect(File('${dir.path}/b').readAsStringSync(), 'new');
    expect(names(), ['b']);
  });
}
