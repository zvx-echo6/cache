import 'dart:io';

import 'package:test/test.dart';

import '../bin/starter_layers.dart';

void main() {
  late Directory tmp, from, to;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('starter-layers');
    from = Directory('${tmp.path}/web/assets/packages/cache_search/layers')..createSync(recursive: true);
    to = Directory('${tmp.path}/support/layer-defs');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the bundled definitions are put in the core folder; only what is missing or differs is written', () {
    File('${from.path}/mapterhorn.json').writeAsStringSync('{"id":"elevation"}');
    File('${from.path}/hillshade.json').writeAsStringSync('{"id":"hillshade"}');
    File('${from.path}/README.txt').writeAsStringSync('not a definition');
    Directory('${from.path}/nested').createSync();
    File('${from.path}/nested/inner.json').writeAsStringSync('{}');

    expect(installStarterLayers(from, to), 2, reason: 'the folder is made and both definitions written');
    expect(File('${to.path}/mapterhorn.json').readAsStringSync(), '{"id":"elevation"}');
    expect(File('${to.path}/hillshade.json').readAsStringSync(), '{"id":"hillshade"}');
    expect(File('${to.path}/README.txt').existsSync(), isFalse, reason: 'only .json files');
    expect(File('${to.path}/inner.json').existsSync(), isFalse, reason: 'only the top level, as on the phone');

    // A second start with nothing changed writes nothing.
    final before = File('${to.path}/mapterhorn.json').lastModifiedSync();
    expect(installStarterLayers(from, to), 0);
    expect(File('${to.path}/mapterhorn.json').lastModifiedSync(), before);

    // An update of Cache that changes one definition rewrites that one only; a file of the core's own is left alone.
    File('${from.path}/hillshade.json').writeAsStringSync('{"id":"hillshade","v":2}');
    File('${to.path}/user-made.json').writeAsStringSync('{"id":"mine"}');
    expect(installStarterLayers(from, to), 1);
    expect(File('${to.path}/hillshade.json').readAsStringSync(), '{"id":"hillshade","v":2}');
    expect(File('${to.path}/user-made.json').readAsStringSync(), '{"id":"mine"}');
  });

  test('with no starter folder nothing is written and nothing throws, and the reason is logged', () {
    final log = <String>[];
    expect(installStarterLayers(Directory('${tmp.path}/missing'), to, log: log.add), 0);
    expect(to.existsSync(), isFalse);
    expect(log.single, contains('is not there'));
  });
}
