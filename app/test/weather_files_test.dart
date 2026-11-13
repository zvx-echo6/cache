import 'dart:convert';
import 'dart:io';

import 'package:cache/app_fs.dart';
import 'package:cache/weather/alert_watch.dart';
import 'package:cache/weather/catalogue.dart';
import 'package:cache/weather/catalogue_store.dart';
import 'package:cache/weather/live_folder.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:cache/weather/weather_files.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/weather_fakes.dart';
import 'weather_catalogue_test.dart' show base, cat;

/// The weather part's files the way a browser keeps them: in memory from a read at start, with every change sent on to the folder
/// (here AppFs over temp folders, which is what Cache Server's fs.* operations are on its disk).
void main() {
  late Directory support, docs;
  late AppFs fs;

  setUp(() {
    support = Directory.systemTemp.createTempSync('wf-support');
    docs = Directory.systemTemp.createTempSync('wf-docs');
    fs = createAppFs(supportOverride: support, docsOverride: docs);
  });
  tearDown(() {
    support.deleteSync(recursive: true);
    docs.deleteSync(recursive: true);
  });

  LoadedCatalogue make(String url, List<String> ids, {String title = 'Cache connectors'}) {
    final c = Catalogue.parse(cat(connectors: [for (final i in ids) entry(i, 'weather', i.toUpperCase())]).replaceAll('"Cache connectors"', '"$title"'));
    return LoadedCatalogue(url: url, catalogue: c, definitions: {for (final i in ids) i: miniDefinition(i)}, skipped: const {});
  }

  test('the files are read at open, answered from memory, and every change reaches the folder in order', () async {
    File('${support.path}/live-catalogues/x/y.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('hello');
    final f = await AppFsFiles.open(fs, AppRoot.support, 'live-catalogues');
    expect(f.read('x/y.txt'), 'hello');
    expect(f.folders(''), ['x']);
    f.write('status.json', '{"a":1}');
    expect(f.read('status.json'), '{"a":1}');
    f.write('status.json', '{"a":2}');
    f.delete('x');
    await f.flush();
    expect(File('${support.path}/live-catalogues/status.json').readAsStringSync(), '{"a":2}');
    expect(Directory('${support.path}/live-catalogues/x').existsSync(), isFalse);
    expect(f.exists('x'), isFalse);
  });

  test('reload reads a file another process wrote', () async {
    final f = await AppFsFiles.open(fs, AppRoot.support, 'live-catalogues');
    expect(f.read('status.json'), isNull);
    File('${support.path}/live-catalogues/status.json').writeAsStringSync('{"run":5}');
    await f.reload('status.json');
    expect(f.read('status.json'), '{"run":5}');
  });

  test('a catalogue store on the browser files saves, replaces and removes whole, and a restart reads it back', () async {
    final f = await AppFsFiles.open(fs, AppRoot.support, 'live-catalogues');
    final store = CatalogueStore.files(f);
    store.save(make('${base}catalogue.json', ['a', 'b']));
    store.save(make('${base}catalogue.json', ['b', 'c'], title: 'Cache connectors 2'));
    store.save(make('https://example.org/c/catalogue.json', ['x']));
    store.remove('https://example.org/c/catalogue.json');
    expect(store.loadAll().single.connectors.map((c) => c.id), ['b', 'c']);
    await f.flush();
    final again = CatalogueStore.files(await AppFsFiles.open(fs, AppRoot.support, 'live-catalogues')).loadAll();
    expect(again.single.catalogue.title, 'Cache connectors 2');
    expect(again.single.connectors.map((c) => c.id), ['b', 'c']);
    // and the phone's own reading of the same folder agrees
    expect(CatalogueStore(Directory('${support.path}/live-catalogues')).loadAll().single.connectors.map((c) => c.id), ['b', 'c']);
  });

  test('the core\'s source folder is kept in the documents folder, with a file somebody added left alone', () async {
    File('${docs.path}/live-defs/mine.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"id":"mine"}');
    final f = await AppFsFiles.open(fs, AppRoot.docs, 'live-defs');
    final folder = LiveFolder.files(f);
    folder.apply({'a': '{"id":"a"}', 'b': '{"id":"b"}'});
    folder.apply({'b': '{"id":"b2"}'});
    await f.flush();
    final d = Directory('${docs.path}/live-defs');
    expect(File('${d.path}/a.json').existsSync(), isFalse);
    expect(File('${d.path}/b.json').readAsStringSync(), '{"id":"b2"}');
    expect(File('${d.path}/mine.json').existsSync(), isTrue);
    expect(jsonDecode(File('${d.path}/.managed').readAsStringSync()), ['b']);
  });

  test('the told list and the place rules are in the support folder, shared by whoever reads them', () async {
    final told = ToldStore.appFs(fs);
    await told.add(['live:nws/home/a1']);
    expect(await ToldStore.appFs(fs).read(), {'live:nws/home/a1'});
    expect(jsonDecode(File('${support.path}/alerts_told.json').readAsStringSync()), ['live:nws/home/a1']);

    final rules = PlaceAlerts.appFs(fs);
    await rules.set('here', const PlaceAlertRule(mode: PlaceAlertMode.custom, miles: 10, kinds: {'fire'}));
    final again = PlaceAlerts.appFs(fs);
    await again.load();
    expect(again.ruleFor('here'), const PlaceAlertRule(mode: PlaceAlertMode.custom, miles: 10, kinds: {'fire'}));
    expect(File('${support.path}/$kPlaceAlertsFile').readAsStringSync(), '{"here":{"mode":"custom","miles":10,"kinds":["fire"]}}');
  });
}
