import 'dart:io';

import 'package:cache/maps/ui/ring_menu.dart';
import 'package:cache/maps/user_layers.dart';
import 'package:cache/notebook/markdown_text.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/alert_watch.dart';
import 'package:cache/weather/catalogue.dart';
import 'package:cache/weather/connector.dart';
import 'package:cache/weather/live_view.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:cache/weather/places.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';

final DateTime _now = DateTime(2026, 10, 29, 16, 12);
const PlaceChoices _places = PlaceChoices(here: _here, saved: _saved);
Future<({double lat, double lon})?> _here() async => (lat: 42.5600, lon: -114.4600);
Future<List<NbPlace>> _saved() async => const [];

class _Rig {
  _Rig() : store = FakeNotebookBackend() {
    nb = fakeNotebook(store);
    alerts = PlaceAlerts.memory();
  }

  final FakeNotebookBackend store;
  late final NotebookState nb;
  late final PlaceAlerts alerts;
  final Set<String> watched = {'here'};
  int changed = 0;

  PlaceNotebookDeps get pd => PlaceNotebookDeps(
        watched: watched.contains,
        setWatched: (id, on) => on ? watched.add(id) : watched.remove(id),
        alerts: alerts,
        placesChanged: () async => changed++,
        alertSetting: () => 'Serious only, from Notifications',
        alertKinds: () => const ['alerts', 'fire', 'earthquakes', 'hydrology'],
        regions: () async => const [(id: 'region:Idaho', name: 'Idaho')],
        hereOnMap: () => hereShown,
        setHereOnMap: (on) => hereShown = on,
      );
  bool hereShown = true;
  NotebookDeps get deps => NotebookDeps(notebook: nb, places: _places, placesDeps: pd, now: () => _now);

  Future<Notebook> saved() async {
    await nb.start();
    return nb.ensureSavedPlaces();
  }

  Future<NbEntry> place(Notebook book, String name, double lat, double lon, {String? color, bool onMap = true}) => nb.saveEntry(
        notebookId: book.id,
        occurredAt: '2026-10-27T10:00:00-06:00',
        title: name,
        place: NbPlace(lat: lat, lon: lon),
        props: {'color': ?color, 'on_map': onMap},
      );

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: buildTheme(CacheThemeId.dark), home: home));
    await tester.pumpAndSettle();
  }
}

void main() {
  group('the Places notebook', () {
    testWidgets('lists Where I am, the regions and each place with its marker; tapping the marker hides and shows it', (tester) async {
      final r = _Rig();
      final book = await r.saved();
      await r.place(book, 'Home', 42.5607, -114.4623, color: 'green');
      await r.place(book, 'Rally point 1', 42.5630, -114.4610, color: 'purple');
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: book.id));
      expect(find.text('Places'), findsOneWidget);
      expect(find.text('Where I am'), findsOneWidget);
      expect(find.text('Follows the phone · weather on'), findsOneWidget);
      expect(find.text('Idaho'), findsOneWidget);
      expect(find.text('Downloaded region · weather off'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Rally point 1'), findsOneWidget);
      expect(find.textContaining('weather off'), findsNWidgets(3), reason: 'the region and both places are not watched yet');
      expect(find.byIcon(Icons.location_off_outlined), findsNothing);
      // Where I am: a fixed first row with its own marker toggle (no delete)
      await tester.tap(find.byKey(const ValueKey('marker-here')));
      await tester.pumpAndSettle();
      expect(r.hereShown, isFalse);
      expect(find.byIcon(Icons.location_disabled_outlined), findsOneWidget);
      final home = r.store.entries.firstWhere((e) => e['title'] == 'Home');
      await tester.tap(find.byKey(ValueKey('marker-${home['id']}')));
      await tester.pumpAndSettle();
      expect((r.store.entries.firstWhere((e) => e['title'] == 'Home')['props'] as Map)['on_map'], false);
      expect(find.byIcon(Icons.location_off_outlined), findsOneWidget, reason: 'a hidden place: outlined with a slash');
      final sem = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp('Green marker, hidden on the map')), findsOneWidget);
      sem.dispose();
      await tester.tap(find.byKey(ValueKey('marker-${home['id']}')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.location_off_outlined), findsNothing);
    });

    testWidgets('tap opens a place (notes formatted), press and hold edits it', (tester) async {
      final r = _Rig();
      final book = await r.saved();
      final e = await r.place(book, 'Rally point 1', 42.5630, -114.4610);
      await r.nb.saveEntry(id: e.id, notebookId: book.id, occurredAt: e.occurredAt, title: e.title, body: '**Meet here** if phones are down.\n\n- [x] Gate code 4471', place: e.place);
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: book.id));
      await tester.tap(find.text('Rally point 1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('place-notes')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('weather-row')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Rally point 1'));
      await tester.pumpAndSettle();
      expect(find.text('Edit place'), findsOneWidget);
      await tester.dragUntilVisible(find.byKey(const ValueKey('place-delete')), find.byType(ListView), const Offset(0, -300));
      expect(find.byKey(const ValueKey('place-delete')), findsOneWidget);
    });

    testWidgets('Add place: the colour nobody uses yet, weather on with its gear, a custom alert rule, then Save', (tester) async {
      final r = _Rig();
      final book = await r.saved();
      await r.place(book, 'Home', 42.5607, -114.4623, color: 'orange');
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: book.id));
      await tester.tap(find.byKey(const ValueKey('add-place')));
      await tester.pumpAndSettle();
      expect(find.text('Add place'), findsOneWidget);
      expect(find.byKey(const ValueKey('place-delete')), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('place-save'))).onPressed, isNull, reason: 'no name yet');
      // the pin starts at Here; a search for coordinates moves it
      await tester.enterText(find.byKey(const ValueKey('place-search')), '42.5944, -114.4003');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.textContaining('42.59440, -114.40030'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('place-name')), 'Shoshone Falls Lot');
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Yellow'), findsOneWidget);
      // weather is on for a new saved place, so its gear shows; switched off, the gear goes
      expect(find.byKey(const ValueKey('weather-gear')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('weather-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weather-gear')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('weather-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('weather-gear')));
      await tester.pumpAndSettle();
      expect(find.text('Alerts for Shoshone Falls Lot'), findsOneWidget);
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Serious only, from Notifications')), findsOneWidget);
      expect(find.text('How far out'), findsNothing, reason: 'custom details show only for Custom');
      await tester.tap(find.byKey(const ValueKey('alert-mode-custom')));
      await tester.pumpAndSettle();
      expect(find.text('How far out'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('alert-kind-earthquakes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alert-done')));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(find.byKey(const ValueKey('place-save')), find.byType(ListView), const Offset(0, -300));
      await tester.tap(find.byKey(const ValueKey('place-save')));
      await tester.pumpAndSettle();
      final saved = r.store.entries.firstWhere((e) => e['title'] == 'Shoshone Falls Lot');
      expect(saved['props'], {'color': 'yellow', 'on_map': true});
      expect(saved['place'], {'lat': 42.5944, 'lon': -114.4003, 'key': 'shoshone-falls-lot'});
      expect(r.watched, contains('place:shoshone-falls-lot'));
      expect(r.changed, 1);
      final rule = r.alerts.ruleFor('place:shoshone-falls-lot');
      expect(rule.mode, PlaceAlertMode.custom);
      expect(rule.kinds, {'alerts', 'fire', 'earthquakes'});
      expect(find.text('Shoshone Falls Lot'), findsOneWidget);
    });

    testWidgets('Delete place asks first, then the place, its weather switch and its alert rule go', (tester) async {
      final r = _Rig();
      final book = await r.saved();
      final e = await r.place(book, 'Cabin', 44.1, -115.2);
      r.watched.add('place:cabin');
      await r.alerts.set('place:cabin', const PlaceAlertRule(mode: PlaceAlertMode.off));
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: book.id));
      await tester.longPress(find.text('Cabin'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(find.byKey(const ValueKey('place-delete')), find.byType(ListView), const Offset(0, -300));
      await tester.tap(find.byKey(const ValueKey('place-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete Cabin?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(r.store.entries.any((x) => x['id'] == e.id), isTrue);
      await tester.tap(find.byKey(const ValueKey('place-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-delete-place')));
      await tester.pumpAndSettle();
      expect(r.store.entries.any((x) => x['id'] == e.id), isFalse);
      expect(r.watched.contains('place:cabin'), isFalse);
      expect(r.alerts.ruleFor('place:cabin'), PlaceAlertRule.same);
    });

    testWidgets('another Places notebook has no weather row and can be renamed or deleted', (tester) async {
      final r = _Rig();
      await r.nb.start();
      final caches = await r.nb.saveNotebook(template: 'places', def: const NotebookDef(name: 'Caches', fields: [], sort: NotebookSort.distance));
      await r.place(caches, 'Cache 1', 42.55, -114.45);
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: caches.id));
      expect(find.text('Where I am'), findsNothing);
      await tester.longPress(find.text('Cache 1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weather-row')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('place-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('places-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Delete notebook'), findsOneWidget);
      expect(find.text('Add places from a file'), findsOneWidget);
    });

    testWidgets('an empty Places notebook says what it is for', (tester) async {
      final r = _Rig();
      final book = await r.saved();
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: book.id));
      expect(find.byKey(const ValueKey('places-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-place')), findsOneWidget);
    });
  });

  group('marker colours', () {
    test('seven colours, no red, each with a spoken name; a new place gets the least used', () {
      expect(kMarkerColors.length, 7);
      expect(kMarkerColors.map((c) => c.id), isNot(contains('red')));
      for (final c in kMarkerColors) {
        expect(c.spoken, isNotEmpty);
        expect(c.color.r > 0.8 && c.color.g < 0.3 && c.color.b < 0.3, isFalse, reason: '${c.id} is not red');
      }
      NbEntry e(String? c) => NbEntry(id: 'x', notebookId: 'n', occurredAt: '2026-10-27T10:00:00-06:00', props: {'color': ?c});
      expect(defaultMarkerColor(const []).id, 'orange');
      expect(defaultMarkerColor([e('orange'), e('yellow'), e(null)]).id, 'green');
      expect(markerColor('nope').id, 'orange');
      expect(markerColor('teal').hex, '#3fbfae');
    });

    test('coordinates typed in the search are a place', () {
      expect(parseLatLon('42.5944, -114.4003'), const NbPlace(lat: 42.5944, lon: -114.4003));
      expect(parseLatLon('42.5 -114'), const NbPlace(lat: 42.5, lon: -114));
      expect(parseLatLon('Twin Falls'), isNull);
      expect(parseLatLon('95, 10'), isNull);
    });
  });

  group('Markdown as it is typed', () {
    test('the drawn text keeps every character', () {
      const text = '# Storm prep\n**Filled** 12 gal of *water*, ~~old~~ `code`\n- [x] Sandbags\n- [ ] Radios\n> Power out\n| Item | Count |\n[[Water plan]] and [site](https://x.org)\n```\nraw *not*\n```';
      final span = markdownSpan(text, const TextStyle(fontSize: 16), cacheTokens[CacheThemeId.dark]!);
      expect(span.toPlainText(), text);
    });

    test('Enter after a list item starts the next; Enter on an empty item ends the list', () {
      final c = MarkdownController(text: '- [x] Sandbags');
      c.value = const TextEditingValue(text: '- [x] Sandbags\n', selection: TextSelection.collapsed(offset: 15));
      expect(c.text, '- [x] Sandbags\n- [ ] ');
      c.value = TextEditingValue(text: '${c.text}\n', selection: TextSelection.collapsed(offset: c.text.length + 1));
      expect(c.text, '- [x] Sandbags\n');
      final n = MarkdownController(text: '1. one');
      n.value = const TextEditingValue(text: '1. one\n', selection: TextSelection.collapsed(offset: 7));
      expect(n.text, '1. one\n2. ');
    });

    test('putting the cursor in a checkbox ticks it', () {
      final c = MarkdownController(text: 'Things\n- [ ] Radios');
      c.selection = const TextSelection.collapsed(offset: 10);
      expect(c.text, 'Things\n- [x] Radios');
      c.selection = const TextSelection.collapsed(offset: 2);
      expect(c.text, 'Things\n- [x] Radios', reason: 'elsewhere nothing changes');
    });
  });

  group('per-place alerts', () {
    Connector src(String id, String category) => Connector.parse('{"id":"$id"}',
        entry: CatalogueEntry(id: id, title: id, description: '', category: category, provider: '', coverage: '', needsKey: false, keyAlias: null,
            defaultOn: false, path: '', attribution: '', license: '', docs: null, sha256: null));
    WatchPlace place(String id) => WatchPlace(id: id, kind: PlaceKind.saved, name: id, subtitle: '', lat: 1, lon: 2, key: id);
    SourceView view(WatchPlace p, Connector c, List<LiveItem> items) => SourceView(source: c, place: p, items: items);
    LiveItem item(String a, {String? distance}) => LiveItem(address: a, label: a, fields: {'Distance': ?distance});

    test('off pops up nothing; custom pops up its kinds within its distance; the default follows the alert setting', () {
      final a = place('place:a'), b = place('place:b'), c = place('place:c');
      final views = {
        a: [view(a, src('nws', 'alerts'), [item('w1')]), view(a, src('quakes', 'earthquakes'), [item('q1', distance: '4 mi')])],
        b: [view(b, src('nws', 'alerts'), [item('w2')])],
        c: [view(c, src('quakes', 'earthquakes'), [item('q2', distance: '12 mi'), item('q3', distance: '40 mi')]), view(c, src('fires', 'fire'), [item('f1')])],
      };
      final rules = {
        'place:b': const PlaceAlertRule(mode: PlaceAlertMode.off),
        'place:c': const PlaceAlertRule(mode: PlaceAlertMode.custom, miles: 25, kinds: {'earthquakes'}),
      };
      final out = pickNewAlerts(views, const {}, rules: (id) => rules[id] ?? PlaceAlertRule.same);
      expect(out.map((x) => x.item.address).toList(), ['w1', 'q2']);
    });

    test('a rule is kept in its file, and the default is not stored', () async {
      final dir = Directory.systemTemp.createTempSync('cache-place-alerts-');
      final f = File('${dir.path}/place_alerts.json');
      final s = PlaceAlerts(() async => f);
      await s.set('here', const PlaceAlertRule(mode: PlaceAlertMode.custom, miles: 10, kinds: {'fire'}));
      await s.set('place:a', PlaceAlertRule.same);
      final again = PlaceAlerts(() async => f);
      await again.load();
      expect(again.ruleFor('here'), const PlaceAlertRule(mode: PlaceAlertMode.custom, miles: 10, kinds: {'fire'}));
      expect(f.readAsStringSync(), '{"here":{"mode":"custom","miles":10,"kinds":["fire"]}}');
      expect(milesIn('3.2 km NE'), closeTo(1.99, 0.01));
      expect(milesIn('none'), isNull);
    });
  });

  group('the ring menu', () {
    test('at most six wedges; More pages the same ring', () {
      final items = [for (var i = 0; i < 12; i++) RingItem(id: 'n$i', label: 'N$i', icon: Icons.book)];
      expect(ringPage(items.take(6).toList(), 0).length, 6);
      expect(ringPages(items.take(6).toList()), 1);
      expect(ringPages(items), 3);
      expect(ringPage(items, 0).map((i) => i.id), ['n0', 'n1', 'n2', 'n3', 'n4', kRingMore]);
      expect(ringPage(items, 2).map((i) => i.id), ['n10', 'n11', kRingMore]);
    });

    testWidgets('a tap on a wedge picks it; the centre goes back', (tester) async {
      final picked = <String>[];
      var back = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: Scaffold(
          body: Center(
            child: RingMenu(
              items: const [RingItem(id: 'to', label: 'To here', icon: Icons.near_me_outlined), RingItem(id: 'save', label: 'Save', icon: Icons.book_outlined)],
              onPick: (i) => picked.add(i.id),
              centre: const Text('Near Twin Falls'),
              onCentre: () => back++,
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('ring-to')), warnIfMissed: false);
      await tester.tapAt(tester.getCenter(find.byType(RingMenu)));
      expect(picked, ['to']);
      expect(back, 1);
      expect(find.bySemanticsLabel('Save'), findsOneWidget);
    });
  });

  test('repeater lists and imported shapes come from the core\'s user-layer calls', () async {
    final calls = <String>[];
    final u = UserLayersState((call, [arg]) async {
      calls.add('$call:${arg ?? ''}');
      return switch (call) {
        'list' => {
            'layers': [
              {'id': 'y1', 'kind': 'layer', 'name': 'Rally Points', 'visible': true, 'points': 2, 'notebook_id': 'nb1'},
            ],
            'repeater_lists': [
              {'id': 'l2', 'kind': 'repeaters', 'name': 'repeaters.kml', 'visible': true, 'repeaters': 6},
            ],
          },
        'get' when arg == 'l2' => {
            'repeaters': [
              {'name': 'TEST1', 'lat': 42.5, 'lon': -113.8, 'frequency': '927.1625 MHz'},
              {'name': 'Albion', 'lat': null, 'lon': null},
            ],
          },
        'get' => {
            'features': [
              {'type': 'Feature', 'geometry': {'type': 'Point', 'coordinates': [-113.79, 42.55]}, 'properties': {'name': 'North gate'}},
              {'type': 'Feature', 'geometry': {'type': 'LineString', 'coordinates': [[-113.79, 42.55], [-113.81, 42.53]]}, 'properties': {'name': 'Walk'}},
            ],
          },
        _ => {'id': 'l3', 'repeaters': 4, 'without_position': 1},
      };
    });
    await u.reload();
    expect(u.repeaterLists.map((l) => (l.id, l.count)), [('l2', 6)]);
    final g = await u.mapGeoJson();
    final kinds = [for (final f in g['features'] as List) ((f as Map)['geometry'] as Map)['type']];
    expect(kinds, ['LineString', 'Point'], reason: 'notebook places are drawn as notebook pins, a list\'s repeaters without a position are not drawn');
    await u.importRepeaters(['/a.kml', '/a.csv']);
    expect(calls, contains('import:{"kind":"repeaters","paths":["/a.kml","/a.csv"]}'));
  });
}
