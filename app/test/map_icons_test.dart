import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/notebook_map.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/notebook/sync/formats.dart';
import 'package:cache/notebook/sync/sync_engine.dart';
import 'package:cache/theme.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

import 'notebook_sync_test.dart' show MemFolder;
import 'support/notebook_fake.dart';
import 'support/test_layer_engine.dart';

/// One device: a notebook store, and the folder both devices share.
class _Device {
  _Device(this.folder) {
    nb = fakeNotebook(store);
  }

  final MemFolder folder;
  final FakeNotebookBackend store = FakeNotebookBackend();
  late final NotebookState nb;
  final File state = File('${Directory.systemTemp.createTempSync('cache-icons-').path}/state.json');

  Future<SyncReport> sync() => NotebookSync(notebook: nb, kind: SyncKind.share, folder: folder, stateFile: state, includePrivate: true, clock: () => DateTime(2026, 11, 10, 12, 0)).run();
}

void main() {
  group('defaults: the place, then its notebook, then the template', () {
    Notebook book(String template, {String? icon, String? color, bool quick = false}) =>
        Notebook(id: 'n1', template: template, def: NotebookDef(name: 'N', fields: const [], quickAdd: quick, icon: icon, color: color));
    NbEntry place({String? color, String? icon}) => NbEntry(id: 'e1', notebookId: 'n1', occurredAt: '2026-11-10T10:00:00-07:00', props: {'color': ?color, 'icon': ?icon});

    test('the template icons: a pin for Places, the ring icons for the others', () {
      expect(defaultNotebookIcon(book('places')), 'pin');
      expect(defaultNotebookIcon(book('journal')), 'journal');
      expect(defaultNotebookIcon(book('notes')), 'notes');
      expect(defaultNotebookIcon(book('log', quick: true)), 'log');
      expect(defaultNotebookIcon(book('other')), 'book');
      expect(kRepeaterIcon, 'radio_tower');
    });

    test('a place shows its own icon, else its notebook\'s, else the template\'s', () {
      expect(iconForPlace(place(icon: 'water'), book('places', icon: 'camp')).id, 'water');
      expect(iconForPlace(place(), book('places', icon: 'camp')).id, 'camp');
      expect(iconForPlace(place(), book('places')).id, 'pin');
      expect(iconForPlace(place(), book('notes')).id, 'notes');
      // an icon id a newer Cache added: the pin, never a crash
      expect(iconForPlace(place(icon: 'from_the_future'), book('places')).id, 'pin');
    });

    test('a pin\'s colour: the place\'s own, else the notebook\'s, else the first colour; Tactical is red', () {
      expect(PinLook.of(place(color: 'blue'), book('places', color: 'teal')).tint, markerColor('blue').color);
      expect(PinLook.of(place(), book('places', color: 'teal')).tint, markerColor('teal').color);
      expect(PinLook.of(place(), book('places')).tint, kMarkerColors.first.color);
      expect(PinLook.of(place(color: 'blue'), book('places', color: 'teal'), tactical: true).tint, cacheTokens[CacheThemeId.tactical]!.accent);
      expect(PinLook.of(place(icon: 'water'), book('places')).icon.id, 'water');
    });

    test('the definition keeps its icon and colour through JSON, and none is none', () {
      final d = NotebookDef.fromJson({'name': 'Trail places', 'icon': 'trailhead', 'color': 'teal', 'fields': <Object>[]});
      expect((d.icon, d.color), ('trailhead', 'teal'));
      expect(NotebookDef.fromJson(d.toJson()).icon, 'trailhead');
      final bare = NotebookDef.fromJson({'name': 'Journal', 'fields': <Object>[]});
      expect(bare.toJson().containsKey('icon') || bare.toJson().containsKey('color'), isFalse);
      expect(d.copyWith(clearIcon: true, clearColor: true).toJson().containsKey('icon'), isFalse);
    });
  });

  group('the icon set and its search', () {
    test('every icon has its own id, a label and a glyph', () {
      final ids = [for (final i in kMapIcons) i.id];
      expect(ids.toSet().length, ids.length);
      expect(ids.length, inInclusiveRange(100, 150));
      for (final i in [...kMapIcons, ...kTemplateIcons]) {
        expect(i.label, isNotEmpty);
        expect(i.icon.fontFamily, isNotNull);
      }
    });

    test('search reads names and synonyms, the best match first', () {
      expect(searchMapIcons('tent').first.id, 'camp');
      expect(searchMapIcons('spring').map((i) => i.id), contains('water'));
      expect(searchMapIcons('creek').map((i) => i.id), contains('water'));
      expect(searchMapIcons('campsite').map((i) => i.id), contains('camp'));
      final radio = searchMapIcons('antenna').map((i) => i.id);
      expect(radio, containsAll(['antenna', 'radio_tower']));
      expect(searchMapIcons('repeater').first.id, 'repeater');
      expect(searchMapIcons('radio tower').first.id, 'radio_tower');
      expect(searchMapIcons('  ').length, kMapIcons.length + kTemplateIcons.length);
      expect(searchMapIcons('zzzz'), isEmpty);
    });

    test('Recent keeps the last 12, newest first, each once', () {
      var r = const RecentIcons();
      for (var i = 0; i < 15; i++) {
        r = r.used('i$i');
      }
      expect(r.ids.length, 12);
      expect(r.ids.first, 'i14');
      r = r.used('i10');
      expect(r.ids.first, 'i10');
      expect(r.ids.where((x) => x == 'i10').length, 1);
    });
  });

  group('pin images', () {
    test('one name per style, icon and colour; Tactical has its own', () {
      const red = Color(0xFFFF5A4A);
      expect(pinImageId(PinStyle.icon, 'water', markerColor('teal').color), isNot(pinImageId(PinStyle.badge, 'water', markerColor('teal').color)));
      expect(pinImageId(PinStyle.icon, 'water', red, tactical: true), isNot(pinImageId(PinStyle.icon, 'water', red)));
    });

    test('each image is drawn and added once', () async {
      final added = <String>[];
      final images = PinImages((name, png) async => added.add(name), PinStyle.badge);
      final a = await images.ensure('water', mapIcon('water').icon, markerColor('teal').color);
      final b = await images.ensure('water', mapIcon('water').icon, markerColor('teal').color);
      await images.ensure('camp', mapIcon('camp').icon, markerColor('teal').color);
      expect(a, b);
      expect(added.length, 2);
      images.reset();
      await images.ensure('water', mapIcon('water').icon, markerColor('teal').color);
      expect(added.length, 3);
    });

    test('the pins carry the image name, and only for a pin that has one', () {
      final e = NbEntry(id: 'e1', notebookId: 'n1', occurredAt: '2026-11-10T10:00:00-07:00', title: 'Boise River ford', place: const NbPlace(lat: 43.6, lon: -116.1));
      final f = notebookPinsGeoJson([e], pinImages: {'e1': 'pin-icon-water-3fbfae'})['features'] as List;
      expect(((f.single as Map)['properties'] as Map)['pin'], 'pin-icon-water-3fbfae');
      final g = notebookPinsGeoJson([e])['features'] as List;
      expect(((g.single as Map)['properties'] as Map).containsKey('pin'), isFalse);
    });
  });

  group('the map style', () {
    final template = jsonDecode(File('assets/map/omt_template.json').readAsStringSync()) as Map<String, dynamic>;
    Map<String, dynamic> pinsLayer(PinStyle? style, {String id = kNotebookPins, CacheThemeId theme = CacheThemeId.dark}) {
      final s = buildMapStyle(
        palette: mapPaletteFor(theme),
        omtTemplate: template,
        layers: const <StyleLayerUse>[],
        tilesUrl: (d) => 'http://127.0.0.1:9/x',
        glyphsUrl: 'file:///fonts/{fontstack}/{range}.pbf',
        pinStyle: style,
      );
      return (s['layers'] as List).cast<Map<String, dynamic>>().firstWhere((l) => l['id'] == id);
    }

    test('with a pin style the notebook pins are a symbol layer drawing the feature\'s image; without, the old circles', () {
      expect(pinsLayer(null)['type'], 'circle');
      final icon = pinsLayer(PinStyle.icon);
      expect(icon['type'], 'symbol');
      expect(icon['layout']['icon-image'], ['get', 'pin']);
      expect(icon['layout']['icon-anchor'], 'center');
      expect(pinsLayer(PinStyle.teardrop)['layout']['icon-anchor'], 'bottom');
      expect(pinsLayer(PinStyle.badge)['layout']['icon-anchor'], 'center');
    });

    test('repeaters are radio towers in the same style, red in Tactical', () {
      expect(pinsLayer(null, id: kUserRepeaters)['type'], 'circle');
      final r = pinsLayer(PinStyle.badge, id: kUserRepeaters);
      expect(r['type'], 'symbol');
      expect(r['layout']['icon-image'], repeaterPinName(PinStyle.badge));
      expect(pinsLayer(PinStyle.badge, id: kUserRepeaters, theme: CacheThemeId.tactical)['layout']['icon-image'], repeaterPinName(PinStyle.badge, tactical: true));
      expect(repeaterPinName(PinStyle.badge), contains('radio_tower'));
    });
  });

  group('Settings > Maps > Pin style', () {
    test('Icon is the default; the choice and Recent are kept on this device', () async {
      final dir = Directory.systemTemp.createTempSync('pinstyle');
      addTearDown(() => dir.deleteSync(recursive: true));
      final engine = TestLayerEngine(published: TestLayerEngine.layersOf(File('test/fixtures/catalogue.json').readAsStringSync()));
      await engine.start();
      final a = MapsState(engine: engine, settingsDirOverride: dir);
      await a.init();
      expect(a.pinStyle, PinStyle.icon);
      final key = a.styleKey;
      a.setPinStyle(PinStyle.teardrop);
      expect(a.styleKey, isNot(key), reason: 'the map style is built again');
      a.iconUsed('water');
      a.iconUsed('camp');
      await a.flush();
      final b = MapsState(engine: engine, settingsDirOverride: dir);
      await b.init();
      expect(b.pinStyle, PinStyle.teardrop);
      expect(b.recentIcons.ids, ['camp', 'water']);
      a.dispose();
    });
  });

  group('syncing the icon, the colour and Show on map', () {
    test('Obsidian and Logseq files hold all three; an old file with none says nothing', () {
      final doc = EntryDoc(id: 'abc', notebook: 'Trail places', when: '2026-11-10T10:00:00', title: 'Boise River ford', props: {'color': 'blue', 'icon': 'river_crossing', 'on_map': false});
      final obs = renderObsidian(doc);
      expect(obs, allOf(contains('cache_color: blue'), contains('cache_icon: river_crossing'), contains('cache_on_map: false')));
      final back = parseObsidian(obs, fallbackId: 'x', fallbackNotebook: 'Trail places', fieldProps: const {})!;
      expect(back.props, {'color': 'blue', 'icon': 'river_crossing', 'on_map': false});
      final ls = renderLogseq(doc);
      final lb = parseLogseq(LsBlock(ls.split(RegExp(r'(?<=\n)'))), day: '2026-11-10', fallbackNotebook: 'Trail places', fieldProps: const {});
      expect(lb.props, {'color': 'blue', 'icon': 'river_crossing', 'on_map': false});
      // none set: "default"; none in the file: null
      final cleared = renderObsidian(EntryDoc(id: 'abc', notebook: 'N', when: '2026-11-10T10:00:00', props: {'color': 'teal'}));
      expect(cleared, allOf(contains('cache_icon: default'), contains('cache_on_map: true')));
      expect(parseObsidian(cleared, fallbackId: 'x', fallbackNotebook: 'N', fieldProps: const {})!.props, {'color': 'teal', 'on_map': true});
      final old = renderObsidian(EntryDoc(id: 'abc', notebook: 'N', when: '2026-11-10T10:00:00'));
      expect(old, isNot(contains('cache_color')));
      expect(parseObsidian(old, fallbackId: 'x', fallbackNotebook: 'N', fieldProps: const {})!.props, isNull);
      // a field that would take one of the names gets another
      expect(propName('Cache color'), 'cache_color_field');
    });

    test('a second device gets the notebook\'s icon and colour and each place\'s; a change travels back, and a cleared icon too', () async {
      final folder = MemFolder();
      final one = _Device(folder);
      await one.nb.start();
      final book = await one.nb.saveNotebook(
        template: 'places',
        def: const NotebookDef(name: 'Trail places', fields: [], sort: NotebookSort.distance, icon: 'trailhead', color: 'teal'),
      );
      final ford = await one.nb.saveEntry(
        notebookId: book.id,
        occurredAt: '2026-11-10T10:00:00-07:00',
        title: 'Boise River ford',
        place: const NbPlace(lat: 43.601, lon: -116.145),
        props: {'color': 'blue', 'icon': 'river_crossing', 'on_map': false},
      );
      final plain = await one.nb.saveEntry(notebookId: book.id, occurredAt: '2026-11-10T11:00:00-07:00', title: 'Lucky Peak trailhead', place: const NbPlace(lat: 43.53, lon: -116.06));
      await one.sync();
      final file = folder.text.entries.firstWhere((e) => e.key.endsWith('Boise River ford.md')).value;
      expect(file, allOf(contains('cache_color: blue'), contains('cache_icon: river_crossing'), contains('cache_on_map: false')));
      // a place with no app properties writes none
      expect(folder.text.entries.firstWhere((e) => e.key.endsWith('Lucky Peak trailhead.md')).value, isNot(contains('cache_icon')));
      expect(folder.text['.cache/notebooks.json'], allOf(contains('"icon": "trailhead"'), contains('"color": "teal"')));

      final two = _Device(folder);
      await two.nb.start();
      await two.sync();
      final made = two.nb.notebooks.firstWhere((n) => n.name == 'Trail places');
      expect((made.def.icon, made.def.color), ('trailhead', 'teal'));
      final got = await two.nb.entry(ford.id);
      expect(got!.props, {'color': 'blue', 'icon': 'river_crossing', 'on_map': false});
      expect((await two.nb.entry(plain.id))!.props, isEmpty);

      // two takes the icon off ("Use notebook icon") and switches the place back on the map
      await two.nb.saveEntry(
        id: ford.id,
        notebookId: made.id,
        occurredAt: got.occurredAt,
        title: got.title,
        place: got.place,
        props: {'color': 'blue', 'on_map': true},
      );
      await two.sync();
      await one.sync();
      expect((await one.nb.entry(ford.id))!.props, {'color': 'blue', 'on_map': true});

      // a file written before these travelled (none of the three): the entry keeps what it has
      final path = folder.text.keys.firstWhere((k) => k.endsWith('Boise River ford.md'));
      folder.text[path] = folder.text[path]!.split('\n').where((l) => !l.startsWith('cache_color') && !l.startsWith('cache_icon') && !l.startsWith('cache_on_map')).join('\n').replaceFirst('Boise River ford', 'Boise River ford, shallow');
      await one.sync();
      final kept = (await one.nb.entry(ford.id))!;
      expect(kept.title, 'Boise River ford, shallow');
      expect(kept.props, {'color': 'blue', 'on_map': true});
    });
  });
}
