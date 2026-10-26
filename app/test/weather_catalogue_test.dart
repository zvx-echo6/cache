import 'dart:convert';
import 'dart:io';

import 'package:cache/weather/catalogue.dart';
import 'package:cache/weather/catalogue_store.dart';
import 'package:cache/weather/connector.dart';
import 'package:cache/weather/live_folder.dart';
import 'package:cache_search/cache_search.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/weather_fakes.dart';

const base = 'https://cache.echo6.co/connectors/';

String cat({int format = 1, String baseUrl = base, List<Map<String, dynamic>>? connectors, String id = 'cache-connectors'}) => jsonEncode({
  'format': format,
  'id': id,
  'title': 'Cache connectors',
  'maintainer': 'Cache project',
  'homepage': 'https://example.org',
  'base_url': baseUrl,
  'updated': '2026-10-26',
  'connectors': connectors ?? [entry('a', 'weather', 'A')],
});

void main() {
  group('the catalogue format', () {
    test('a catalogue is read: its words, and where each definition is', () {
      final c = Catalogue.parse(cat(connectors: [entry('a', 'weather', 'A'), entry('k', 'fire', 'K', keyAlias: 'firms')]));
      expect(c.title, 'Cache connectors');
      expect(c.entries.map((e) => e.id), ['a', 'k']);
      expect(c.entries[1].needsKey, isTrue);
      expect(c.entries[1].keyAlias, 'firms');
      expect(c.definitionUrl(c.entries[0]).toString(), '${base}weather/a.json');
    });

    test('another format number is refused, a newer one with a reason that says to update', () {
      expect(() => Catalogue.parse(cat(format: 2)), throwsA(isA<CatalogueException>().having((e) => e.message, 'message', contains('Update Cache'))));
      expect(() => Catalogue.parse(cat(format: 0)), throwsA(isA<CatalogueException>()));
    });

    test('not a catalogue at all', () {
      expect(() => Catalogue.parse('<html>'), throwsA(isA<CatalogueException>().having((e) => e.message, 'message', contains('connector catalogue'))));
      expect(() => Catalogue.parse('[1]'), throwsA(isA<CatalogueException>()));
    });

    test('the base address must be https (this phone excepted)', () {
      expect(() => Catalogue.parse(cat(baseUrl: 'http://example.org/c/')), throwsA(isA<CatalogueException>()));
      expect(Catalogue.parse(cat(baseUrl: 'http://127.0.0.1:8123/')).baseUrl.host, '127.0.0.1');
      expect(() => Catalogue.parse(cat(baseUrl: 'http://192.168.1.5:8123/')), throwsA(isA<CatalogueException>()));
    });

    test('a path that leaves the catalogue folder is refused', () {
      for (final p in ['../x.json', '/x.json', 'a/../../x.json', 'a//b.json', 'a\\b.json', 'x.json?y=1']) {
        expect(
          () => Catalogue.parse(cat(connectors: [entry('a', 'weather', 'A', path: p)])),
          throwsA(isA<CatalogueException>().having((e) => e.message, 'message', contains('leaves the catalogue'))),
          reason: p,
        );
      }
      expect(() => Catalogue.parse(cat(connectors: [entry('a', 'weather', 'A', path: 'http://example.org/a.json')])), throwsA(isA<CatalogueException>()));
      expect(Catalogue.parse(cat(connectors: [entry('a', 'weather', 'A', path: 'https://other.example.org/a.json')])).entries.single.path, 'https://other.example.org/a.json');
    });

    test('a connector with no title, a bad id, or listed twice', () {
      expect(() => Catalogue.parse(cat(connectors: [entry('a', 'weather', '')])), throwsA(isA<CatalogueException>()));
      expect(() => Catalogue.parse(cat(connectors: [entry('Bad Id', 'weather', 'A')])), throwsA(isA<CatalogueException>()));
      expect(() => Catalogue.parse(cat(connectors: [entry('a', 'weather', 'A'), entry('a', 'weather', 'B')])), throwsA(isA<CatalogueException>().having((e) => e.message, 'message', contains('twice'))));
    });
  });

  group('downloading a catalogue', () {
    late FakeWeb web;
    late FakeLiveCore core;
    late Directory dir;
    late CatalogueLoader loader;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('catalogue');
      web = FakeWeb();
      core = FakeLiveCore(Directory('${dir.path}/live'));
      loader = CatalogueLoader(
        fetch: web.fetch,
        check: (t) async {
          try {
            await core.check(t);
          } on CacheSearchException catch (e) {
            throw CatalogueException(e.message);
          }
        },
      );
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('every definition is checked with the core before it is accepted', () async {
      web.serve(base, standardCatalogue());
      final l = await loader.load('${base}catalogue.json');
      expect(l.definitions.length, 11);
      expect(l.skipped, isEmpty);
      expect(core.checked.length, 11);
      expect(l.connectors.map((c) => c.id), contains('firms-viirs-near'));
    });

    test('a bad definition is left out with the core\'s own message, the rest are kept', () async {
      web.serve(base, standardCatalogue());
      core.invalid.add('swpc-kp');
      final l = await loader.load('${base}catalogue.json');
      expect(l.definitions.containsKey('swpc-kp'), isFalse);
      expect(l.skipped['swpc-kp'], 'items[0].label: missing the field "path"');
      expect(l.definitions.length, 10);
    });

    test('a file that is not the definition it is listed as is left out', () async {
      final files = standardCatalogue();
      files['space-weather/swpc-kp.json'] = miniDefinition('something-else');
      web.serve(base, files);
      final l = await loader.load('${base}catalogue.json');
      expect(l.skipped['swpc-kp'], contains('something-else'));
    });

    test('the checksum, when the catalogue gives one, must match', () async {
      final def = miniDefinition('a', title: 'A');
      final good = sha256.convert(utf8.encode(def)).toString();
      final files = {
        'catalogue.json': cat(connectors: [
          {...entry('a', 'weather', 'A'), 'sha256': good},
          {...entry('b', 'weather', 'B'), 'sha256': '0' * 64},
        ]),
        'weather/a.json': def,
        'weather/b.json': miniDefinition('b', title: 'B'),
      };
      web.serve(base, files);
      final l = await loader.load('${base}catalogue.json');
      expect(l.definitions.keys, ['a']);
      expect(l.skipped['b'], contains('checksum'));
    });

    test('a connection that fails part way fails the whole load, never a half catalogue', () async {
      final files = standardCatalogue()..remove('alerts/nws-alerts-point.json');
      web.serve(base, files);
      await expectLater(loader.load('${base}catalogue.json'), throwsA(isA<NetworkProblem>()));
    });

    test('an address that is not https is refused before anything is asked', () async {
      await expectLater(loader.load('http://example.org/catalogue.json'), throwsA(isA<CatalogueException>().having((e) => e.message, 'message', contains('https'))));
      await expectLater(loader.load('not an address'), throwsA(isA<CatalogueException>()));
      expect(web.requested, isEmpty);
    });

    test('a catalogue in another format is refused with its reason', () async {
      web.serve(base, buildCatalogue(format: 7, connectors: [entry('a', 'weather', 'A')]));
      await expectLater(loader.load('${base}catalogue.json'), throwsA(isA<CatalogueException>().having((e) => e.message, 'message', contains('newer format'))));
    });
  });

  group('the catalogue kept on the phone', () {
    late Directory dir;
    late CatalogueStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('catstore');
      store = CatalogueStore(dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    LoadedCatalogue make(String url, List<String> ids, {String title = 'Cache connectors', Map<String, String> skipped = const {}}) {
      final c = Catalogue.parse(cat(connectors: [for (final i in ids) entry(i, 'weather', i.toUpperCase())]).replaceAll('"Cache connectors"', '"$title"'));
      return LoadedCatalogue(url: url, catalogue: c, definitions: {for (final i in ids) i: miniDefinition(i)}, skipped: skipped);
    }

    test('it survives a restart: read back whole', () {
      store.save(make('${base}catalogue.json', ['a', 'b'], skipped: {'c': 'refused'}));
      final back = CatalogueStore(dir).loadAll();
      expect(back.single.url, '${base}catalogue.json');
      expect(back.single.connectors.map((c) => c.id), ['a', 'b']);
      expect(back.single.skipped, {'c': 'refused'});
    });

    test('an update replaces the old copy whole: a source that left the catalogue is gone', () {
      store.save(make('${base}catalogue.json', ['a', 'b']));
      store.save(make('${base}catalogue.json', ['b', 'c'], title: 'Cache connectors 2'));
      final back = store.loadAll().single;
      expect(back.catalogue.title, 'Cache connectors 2');
      expect(back.connectors.map((c) => c.id), ['b', 'c']);
      expect(File('${store.root.path}/${store.folderOf('${base}catalogue.json')}/defs/a.json').existsSync(), isFalse);
    });

    test('removing a catalogue removes its folder and only its folder', () {
      store.save(make('${base}catalogue.json', ['a']));
      store.save(make('https://example.org/c/catalogue.json', ['x']));
      store.remove('https://example.org/c/catalogue.json');
      expect(store.loadAll().map((c) => c.url), ['${base}catalogue.json']);
    });

    test('a damaged folder or a half-written update is ignored', () {
      store.save(make('${base}catalogue.json', ['a']));
      Directory('${dir.path}/abc123').createSync();
      File('${dir.path}/abc123/catalogue.json').writeAsStringSync('{broken');
      Directory('${dir.path}/zzz.new').createSync();
      expect(store.loadAll().length, 1);
      expect(Directory('${dir.path}/zzz.new').existsSync(), isFalse);
    });
  });

  group('the core\'s source folder', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('livefolder'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('holds the sources that are on, drops the ones turned off, and leaves a file somebody added alone', () {
      final f = LiveFolder(dir);
      File('${dir.path}/mine.json').writeAsStringSync('{"id":"mine"}');
      f.apply({'a': '{"id":"a"}', 'b': '{"id":"b"}'});
      expect(dir.listSync().map((e) => e.uri.pathSegments.last).toSet(), containsAll(['a.json', 'b.json', 'mine.json']));
      f.apply({'b': '{"id":"b2"}'});
      expect(File('${dir.path}/a.json').existsSync(), isFalse);
      expect(File('${dir.path}/b.json').readAsStringSync(), '{"id":"b2"}');
      expect(File('${dir.path}/mine.json').existsSync(), isTrue);
    });

    test('the first time, the definitions earlier versions of the app wrote are cleared when they are not wanted', () {
      File('${dir.path}/weather.json').writeAsStringSync('{"id":"weather"}');
      File('${dir.path}/alerts.json').writeAsStringSync('{"id":"alerts"}');
      LiveFolder(dir).apply({'alerts': '{"id":"alerts"}'}, formerly: ['weather', 'alerts']);
      expect(File('${dir.path}/weather.json').existsSync(), isFalse);
      expect(File('${dir.path}/alerts.json').existsSync(), isTrue);
    });
  });

  test('a connector reads its words from the definition and the catalogue entry', () {
    final c = Catalogue.parse(cat(connectors: [entry('k', 'fire', 'Satellite fires', provider: 'NASA FIRMS', keyAlias: 'firms', docs: 'https://example.org/docs')]));
    final k = Connector.parse(miniDefinition('k', keyAlias: 'firms', refresh: 30), entry: c.entries.single);
    expect(k.title, 'Satellite fires');
    expect(k.provider, 'Provider');
    expect(k.keyAlias, 'firms');
    expect(k.needsKey, isTrue);
    expect(k.refreshMinutes, 30);
    expect(k.docs, 'https://example.org/docs');
    expect(() => Connector.parse('nope'), throwsA(isA<CatalogueException>()));
    expect(() => Connector.parse('{"title":"x"}'), throwsA(isA<CatalogueException>()));
  });
}
