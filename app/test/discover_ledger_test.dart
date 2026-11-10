import 'dart:convert';

import 'package:cache/discover/ledger.dart';
import 'package:cache/discover/recipe.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/discover_fakes.dart';

Activity _activity(String id, List<Map<String, dynamic>> items, {List<Map<String, dynamic>> settings = const [], int revision = 1}) =>
    Activity.fromJson({'id': id, 'revision': revision, 'title': id[0].toUpperCase() + id.substring(1), 'tagline': '', 'items': items, 'settings': settings});

Map<String, dynamic> _lib(String name) => {'kind': 'library', 'name': name, 'approx_bytes': 100};
Map<String, dynamic> _live(String id) => {'kind': 'live_source', 'id': id};
Map<String, dynamic> _nb(String id) => {'kind': 'notebook', 'id': id};
const _region = {'kind': 'map_region', 'parts': ['map', 'routing']};
const _homeWeather = {'key': 'home:weather', 'value': true};

void main() {
  late FakeDiscoverDevice dev;
  late Ledger ledger;

  final ready = _activity('ready', [_lib('army'), _lib('water'), _region, _live('nws'), _nb('starter.water_rotation')], settings: [_homeWeather]);
  final backcountry = _activity('backcountry', [_lib('water'), _lib('knots'), _region, _live('nws'), _live('fire')], settings: [_homeWeather]);

  setUp(() {
    dev = FakeDiscoverDevice();
    ledger = Ledger();
  });

  group('install', () {
    test('adds what is not on the device, and records every setting it changed with its value before', () async {
      dev.settings['home:weather'] = false;
      final rec = await ledger.install(ready, dev);
      expect(dev.added, ['library:army', 'library:water', 'region:here', 'notebook:starter.water_rotation']);
      expect(rec.items, ['library:army', 'library:water', 'region:here', 'notebook:starter.water_rotation']);
      expect(dev.settings['live:nws'], true);
      expect(dev.settings['home:weather'], true);
      expect([for (final c in rec.changed) (c.key, c.before, c.after)], [('live:nws', false, true), ('home:weather', false, true)]);
    });

    test('a shared item is downloaded once and counted for each activity', () async {
      await ledger.install(ready, dev);
      dev.added.clear();
      await ledger.install(backcountry, dev);
      // water and the region are Ready's: Backcountry only asks that they are there (with its parts); knots is new
      expect(dev.added.where((k) => k == 'library:knots'), hasLength(1));
      expect(dev.added, isNot(contains('library:water')), reason: 'downloaded once, by Ready');
      expect(ledger.items['library:water']!.holders, {'ready', 'backcountry'});
      expect(ledger.items['region:here']!.holders, {'ready', 'backcountry'});
      expect(ledger.items['library:knots']!.holders, {'backcountry'});
    });

    test('an item the person had before is theirs: counted, never added again, never removed', () async {
      dev.present.add('library:water');
      await ledger.install(ready, dev);
      expect(dev.added, isNot(contains('library:water')));
      expect(ledger.items['library:water']!.preexisting, isTrue);
      await ledger.remove('ready', dev);
      expect(dev.dropped, isNot(contains('library:water')));
      expect(dev.present, contains('library:water'));
    });

    test('a setting already as the recipe wants it is not changed and not recorded', () async {
      dev.settings['live:nws'] = true;
      final rec = await ledger.install(ready, dev);
      expect(dev.writes, isNot(contains('live:nws=true')));
      expect(rec.changed.map((c) => c.key), isNot(contains('live:nws')));
      await ledger.remove('ready', dev);
      expect(dev.settings['live:nws'], true, reason: 'it was on before Ready: it stays on');
    });

    test('items switched off in Customize are not added', () async {
      final rec = await ledger.install(ready, dev, leftOut: {'library:army', 'live:nws'});
      expect(dev.added, isNot(contains('library:army')));
      expect(dev.settings['live:nws'], isNot(true));
      expect(rec.leftOut, {'library:army', 'live:nws'});
    });
  });

  group('remove', () {
    test('removes only what no other activity holds, the person did not have and does not use', () async {
      await ledger.install(ready, dev);
      await ledger.install(backcountry, dev);
      await ledger.remove('backcountry', dev);
      expect(dev.dropped, ['library:knots'], reason: 'water and the region are still Ready\'s');
      expect(ledger.items.keys, containsAll(['library:water', 'region:here']));
      await ledger.remove('ready', dev);
      expect(dev.dropped, ['library:knots', 'library:army', 'library:water', 'region:here', 'notebook:starter.water_rotation']);
      expect(ledger.items, isEmpty);
      expect(dev.dropped.where((k) => k == 'library:water'), hasLength(1), reason: 'a shared item is removed once');
    });

    test('a notebook the person has written in is kept', () async {
      await ledger.install(ready, dev);
      dev.used.add('notebook:starter.water_rotation');
      await ledger.remove('ready', dev);
      expect(dev.dropped, isNot(contains('notebook:starter.water_rotation')));
      expect(dev.present, contains('notebook:starter.water_rotation'));
    });

    test('puts a changed setting back to its value before', () async {
      dev.settings['home:weather'] = false;
      await ledger.install(ready, dev);
      await ledger.remove('ready', dev);
      expect(dev.settings['home:weather'], false);
      expect(dev.settings['live:nws'], false);
      expect(ledger.settings, isEmpty);
    });

    test('leaves a setting the person changed since as they set it', () async {
      dev.settings['home:weather'] = false;
      await ledger.install(ready, dev);
      // the person hides the weather card again, and switches the alerts off themselves
      dev.settings['home:weather'] = false;
      dev.settings['live:nws'] = false;
      dev.writes.clear();
      await ledger.remove('ready', dev);
      expect(dev.writes, isEmpty, reason: 'nothing the person changed is touched');
      expect(dev.settings['home:weather'], false);
      expect(ledger.settings, isEmpty);
    });

    test('a person who changed a setting since and changed it back to what the activity set: it is put back', () async {
      dev.settings['home:weather'] = false;
      await ledger.install(ready, dev);
      dev.settings['home:weather'] = false;
      dev.settings['home:weather'] = true;
      await ledger.remove('ready', dev);
      expect(dev.settings['home:weather'], false);
    });

    test('a setting two activities hold is put back only when the last one goes', () async {
      dev.settings['home:weather'] = false;
      await ledger.install(ready, dev);
      await ledger.install(backcountry, dev);
      await ledger.remove('ready', dev);
      expect(dev.settings['home:weather'], true, reason: 'Backcountry still holds it');
      expect(dev.settings['live:nws'], true);
      await ledger.remove('backcountry', dev);
      expect(dev.settings['home:weather'], false);
      expect(dev.settings['live:nws'], false);
      expect(dev.settings['live:fire'], false);
    });

    test('a setting the person changed between two activities: the second records the value it found', () async {
      dev.settings['live:nws'] = false;
      await ledger.install(ready, dev);
      dev.settings['live:nws'] = false; // the person switches it off
      await ledger.install(backcountry, dev); // Backcountry switches it on again, from off
      expect(ledger.settings['live:nws']!.holders, {'backcountry'});
      await ledger.remove('backcountry', dev);
      expect(dev.settings['live:nws'], false);
      await ledger.remove('ready', dev);
      expect(dev.settings['live:nws'], false);
    });

    test('the plan says what goes, what stays and why, and what is put back', () async {
      dev.settings['home:weather'] = false;
      await ledger.install(ready, dev);
      await ledger.install(backcountry, dev);
      dev.settings['live:fire'] = false; // changed since
      final p = await ledger.planRemove('backcountry', dev, titleOf: (id) => id == 'ready' ? 'Ready' : id);
      expect(p.goes.map((i) => i.key), ['library:knots']);
      expect(p.kept.map((k) => (k.$1.key, k.$2)), [('library:water', 'Used by Ready'), ('region:here', 'Used by Ready')]);
      expect(p.restores, isEmpty, reason: 'nws and the weather card are Ready\'s too; fire was changed since');
      expect(p.keptSettings, containsAll(['live:nws', 'live:fire', 'home:weather']));
    });
  });

  group('plan', () {
    test('says what is new, what is here already and who shares it, and what changes', () async {
      await ledger.install(ready, dev);
      final p = await ledger.plan(backcountry, dev);
      final byKey = {for (final x in p.items) x.item.key: x};
      expect(byKey['library:knots']!.isNew, isTrue);
      expect(byKey['library:water']!.isNew, isFalse);
      expect(byKey['library:water']!.sharedWith, ['ready']);
      expect(byKey['live:nws']!.isNew, isFalse);
      expect(p.changes.map((c) => c.key), ['live:fire']);
    });

    test('a source switched off by default is left out unless chosen', () async {
      final a = _activity('x', [_lib('a'), {'kind': 'live_source', 'id': 'avalanche', 'default_on': false}]);
      final p = await ledger.plan(a, dev);
      expect(p.items.map((x) => x.item.key), ['library:a']);
      final chosen = await ledger.plan(a, dev, leftOut: const {});
      expect(chosen.items.map((x) => x.item.key), ['library:a', 'live:avalanche']);
    });
  });

  test('an update releases what the newer recipe dropped and adds what it gained', () async {
    await ledger.install(ready, dev);
    final v2 = _activity('ready', [_lib('army'), _lib('canning'), _region, _live('nws'), _nb('starter.water_rotation')], settings: [_homeWeather], revision: 2);
    await ledger.install(v2, dev);
    expect(dev.added, contains('library:canning'));
    expect(dev.dropped, ['library:water']);
    expect(ledger.activities['ready']!.revision, 2);
  });

  test('the ledger is kept as JSON and read back the same', () async {
    dev.settings['home:weather'] = false;
    await ledger.install(ready, dev);
    await ledger.install(backcountry, dev);
    final again = Ledger.fromJson(jsonDecode(jsonEncode(ledger.toJson())));
    expect(jsonEncode(again.toJson()), jsonEncode(ledger.toJson()));
    await again.remove('ready', dev);
    await again.remove('backcountry', dev);
    expect(dev.settings['home:weather'], false);
    expect(again.items, isEmpty);
  });
}
