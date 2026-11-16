import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// This test is plain Dart (`dart test`): if settings_files.dart imported Flutter, or anything that does, it would not compile here.
import '../../../app/lib/sharing/settings_files.dart';

void main() {
  late Directory tmp;
  late SettingsFiles files;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('settings_files_test');
    files = SettingsFiles(IoSettingsFileAccess(tmp));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, dynamic> json(String name) => (jsonDecode(File('${tmp.path}/$name').readAsStringSync()) as Map).cast<String, dynamic>();

  test('the 17 settings are all mapped, each to a file and fields', () {
    expect(kSettingsFileMap.length, 17);
    for (final e in kSettingsFileMap.entries) {
      expect(e.value.file, isNotEmpty, reason: e.key);
      expect(e.value.fields, isNotEmpty, reason: e.key);
    }
  });

  test('a folder with no files reads as a new install; a write makes the file and keeps what is in it', () async {
    expect(await files.read('appearance.theme'), 'dark');
    expect(await files.read('home.bar'), ['ask', 'maps', 'library']);
    expect(await files.read('weather.watch_here'), isTrue);
    expect(await files.read('weather.own_sources'), isEmpty);
    File('${tmp.path}/settings.json').writeAsStringSync(jsonEncode({'lastModel': 'm.gguf', 'theme': 'dark', 'names': {'a': 'b'}}));
    await files.write('appearance.theme', 'light');
    expect(json('settings.json'), {'lastModel': 'm.gguf', 'theme': 'light', 'names': {'a': 'b'}});
    expect(await files.read('ask.model'), 'm.gguf');
    expect(Directory(tmp.path).listSync().where((e) => e.path.contains('.tmp')), isEmpty, reason: 'no temp file left');
  });

  test('maps.json keeps the camera, opacity and definitions when the layers on change', () async {
    File('${tmp.path}/maps.json').writeAsStringSync(jsonEncode({
      'enabled': ['a'],
      'opacity': {'a': 0.5},
      'definitions': {'x': true},
      'camera': {'lat': 1.0, 'lon': 2.0, 'zoom': 3.0},
    }));
    await files.write('maps.layers_on', ['b', 'c']);
    final j = json('maps.json');
    expect(j['enabled'], ['b', 'c']);
    expect(j['opacity'], {'a': 0.5});
    expect(j['definitions'], {'x': true});
    expect(j['camera'], {'lat': 1.0, 'lon': 2.0, 'zoom': 3.0});
    expect(await files.read('maps.layers_on'), ['b', 'c']);
  });

  test('your own sources are kept as the phone keeps them (one folder with the list, the definitions and a note)', () async {
    final value = [
      {
        'entry': {'id': 'own-a', 'title': 'River A', 'path': 'x'},
        'definition': '{"id":"own-a"}',
      },
    ];
    await files.write('weather.own_sources', value);
    final read = await files.read('weather.own_sources') as List;
    expect(read.length, 1);
    expect((read.single as Map)['definition'], '{"id":"own-a"}');
    expect(((read.single as Map)['entry'] as Map)['path'], 'defs/own-a.json');
    final dirs = Directory('${tmp.path}/live-catalogues').listSync();
    expect(dirs.length, 1);
    expect(File('${dirs.single.path}/defs/own-a.json').existsSync(), isTrue);
    expect(File('${dirs.single.path}/meta.json').existsSync(), isTrue);
  });
}
