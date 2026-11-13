import 'dart:io';

import 'package:cache/maps/ui/ring_menu.dart';
import 'package:cache/maps/user_layers.dart';
import 'package:cache/notebook/markdown_text.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/icon_picker.dart' show MapIconSetup;
import 'package:cache/screens/notebooks/notebook_editor.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/search/notebook_search_providers.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/alert_watch.dart';
import 'package:cache/weather/catalogue.dart';
import 'package:cache/weather/connector.dart';
import 'package:cache/weather/live_view.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:cache/weather/places.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:cache/settings/app_settings.dart';
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
        directions: directions,
      );
  bool hereShown = true;

  /// What the Directions button of a place asks (null: no button).
  bool Function(NbPlace place, String name)? directions;
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
    testWidgets('lists only the person\'s own places, each with its marker; tapping the marker hides and shows it', (tester) async {
      final r = _Rig();
      final book = await r.saved();
      await r.place(book, 'Home', 42.5607, -114.4623, color: 'green');
      await r.place(book, 'Rally point 1', 42.5630, -114.4610, color: 'purple');
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: book.id));
      expect(find.text('Places'), findsOneWidget);
      // Where I am and the downloaded regions are Weather and alerts' watched areas now, not rows here
      expect(find.text('Where I am'), findsNothing);
      expect(find.byKey(const ValueKey('marker-here')), findsNothing);
      expect(find.text('Idaho'), findsNothing);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Rally point 1'), findsOneWidget);
      expect(find.textContaining('weather off'), findsNWidgets(2), reason: 'both places are not watched yet');
      expect(find.byIcon(Icons.location_off_outlined), findsNothing);
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

    testWidgets('Directions on a place opens them, and while a route is being followed says to finish or end it first', (tester) async {
      final r = _Rig();
      var guiding = false;
      final opened = <String>[];
      r.directions = (p, name) {
        if (guiding) return false;
        opened.add(name);
        return true;
      };
      final book = await r.saved();
      await r.place(book, 'Rally point 1', 42.5630, -114.4610);
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: book.id));
      await tester.tap(find.text('Rally point 1'));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('place-directions'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();
      expect(opened, ['Rally point 1']);
      expect(find.text('Finish or end the route first'), findsNothing);
      guiding = true;
      await tester.tap(button);
      await tester.pump();
      expect(opened, ['Rally point 1'], reason: 'nothing is opened over a route being followed');
      expect(find.text('Finish or end the route first'), findsOneWidget);
    });

    testWidgets('Add place: no colour of its own, weather on with its gear, a custom alert rule, then Save', (tester) async {
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
      expect(find.bySemanticsLabel('Orange'), findsOneWidget);
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
      expect(saved['props'], {'on_map': true}, reason: 'a new place stores no colour unless one is picked');
      expect(saved['place'], {'lat': 42.5944, 'lon': -114.4003, 'key': 'shoshone-falls-lot'});
      expect(r.watched, contains('place:shoshone-falls-lot'));
      expect(r.changed, 1);
      final rule = r.alerts.ruleFor('place:shoshone-falls-lot');
      expect(rule.mode, PlaceAlertMode.custom);
      expect(rule.kinds, {'alerts', 'fire', 'earthquakes'});
      expect(find.text('Shoshone Falls Lot'), findsOneWidget);
    });

    Future<Notebook> colourBook(_Rig r, {String? color}) async {
      await r.nb.start();
      return r.nb.saveNotebook(template: 'places', def: NotebookDef(name: 'Trail log', fields: const [], sort: NotebookSort.distance, color: color));
    }

    Future<Map<String, Object?>> addNamed(WidgetTester tester, _Rig r, Notebook book, {String? pick}) async {
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: book.id));
      await tester.tap(find.byKey(const ValueKey('add-place')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('place-name')), 'Spring');
      await tester.pumpAndSettle();
      if (pick != null) {
        await tester.ensureVisible(find.byKey(ValueKey('swatch-$pick')));
        await tester.tap(find.byKey(ValueKey('swatch-$pick')));
        await tester.pumpAndSettle();
      }
      await tester.dragUntilVisible(find.byKey(const ValueKey('place-save')), find.byType(ListView), const Offset(0, -300));
      await tester.tap(find.byKey(const ValueKey('place-save')));
      await tester.pumpAndSettle();
      return (r.store.entries.firstWhere((e) => e['title'] == 'Spring')['props'] as Map).cast<String, Object?>();
    }

    testWidgets('a new place in a coloured notebook stores no colour and shows the notebook colour', (tester) async {
      final r = _Rig();
      final book = await colourBook(r, color: 'blue');
      final props = await addNamed(tester, r, book);
      expect(props.containsKey('color'), isFalse);
      final marker = tester.widget<PlaceMarker>(find.byType(PlaceMarker).first);
      expect(marker.color.id, 'blue');
    });

    testWidgets('a new place in a notebook with no colour stores no colour and shows the default', (tester) async {
      final r = _Rig();
      final book = await colourBook(r);
      final props = await addNamed(tester, r, book);
      expect(props.containsKey('color'), isFalse);
      expect(tester.widget<PlaceMarker>(find.byType(PlaceMarker).first).color.id, markerColor(null).id);
    });

    testWidgets('a colour the person picks is stored', (tester) async {
      final r = _Rig();
      final book = await colourBook(r, color: 'blue');
      final props = await addNamed(tester, r, book, pick: 'purple');
      expect(props['color'], 'purple');
    });

    testWidgets("a picked color equal to the notebook's is not stored, so the place keeps following the notebook", (tester) async {
      final r = _Rig();
      final book = await colourBook(r, color: 'blue');
      final props = await addNamed(tester, r, book, pick: 'blue');
      expect(props.containsKey('color'), isFalse);
    });

    group('changing the notebook color', () {
      Future<(_Rig, Notebook)> world({int own = 2, int plain = 1}) async {
        final r = _Rig();
        final book = await colourBook(r, color: 'blue');
        for (var i = 0; i < own; i++) {
          await r.place(book, 'Own $i', 42.5 + i / 100, -114.4, color: 'green');
        }
        for (var i = 0; i < plain; i++) {
          await r.place(book, 'Plain $i', 42.6 + i / 100, -114.4);
        }
        return (r, book);
      }

      Future<void> editColour(WidgetTester tester, _Rig r, Notebook book, String pick) async {
        await r.pump(tester, NotebookEditor(notebook: r.nb, existing: book, icons: MapIconSetup.fixed()));
        await tester.ensureVisible(find.byKey(ValueKey('nb-color-$pick')));
        await tester.tap(find.byKey(ValueKey('nb-color-$pick')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('notebook-save')));
        await tester.pumpAndSettle();
      }

      Map<String, Object?> propsOf(_Rig r, String title) => (r.store.entries.firstWhere((e) => e['title'] == title)['props'] as Map).cast<String, Object?>();

      testWidgets('asks with the new color, the count and the notebook; Change all clears their colors and writes none', (tester) async {
        final (r, book) = await world();
        await editColour(tester, r, book, 'purple');
        expect(find.text('Change all its places to Purple?'), findsOneWidget);
        expect(find.bySemanticsLabel('Purple'), findsOneWidget, reason: 'the name is the swatch label');
        expect(find.text('2 places in Trail log have their own color.'), findsOneWidget);
        expect(find.text('Keep their colors'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('colour-ask-change')));
        await tester.pumpAndSettle();
        expect(propsOf(r, 'Own 0').containsKey('color'), isFalse);
        expect(propsOf(r, 'Own 1').containsKey('color'), isFalse);
        expect(propsOf(r, 'Own 0')['on_map'], isTrue, reason: 'the rest of the place is kept');
        expect(r.nb.notebooks.firstWhere((n) => n.id == book.id).def.color, 'purple');
      });

      testWidgets('Keep their colors changes only the notebook', (tester) async {
        final (r, book) = await world();
        await editColour(tester, r, book, 'purple');
        await tester.tap(find.byKey(const ValueKey('colour-ask-keep')));
        await tester.pumpAndSettle();
        expect(propsOf(r, 'Own 0')['color'], 'green');
        expect(propsOf(r, 'Own 1')['color'], 'green');
        expect(r.nb.notebooks.firstWhere((n) => n.id == book.id).def.color, 'purple');
      });

      testWidgets('one place: singular wording', (tester) async {
        final (r, book) = await world(own: 1);
        await editColour(tester, r, book, 'purple');
        expect(find.text('1 place in Trail log has its own color.'), findsOneWidget);
      });

      testWidgets('no place with its own color: no dialog, the notebook changes', (tester) async {
        final (r, book) = await world(own: 0, plain: 2);
        await editColour(tester, r, book, 'purple');
        expect(find.byType(AlertDialog), findsNothing);
        expect(r.nb.notebooks.firstWhere((n) => n.id == book.id).def.color, 'purple');
      });
    });

    testWidgets('the hide toggle on the map stores no colour', (tester) async {
      final r = _Rig();
      final book = await colourBook(r);
      final e = await r.place(book, 'Spring', 42.55, -114.45);
      await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: book.id));
      await tester.tap(find.byKey(ValueKey('marker-${e.id}')));
      await tester.pumpAndSettle();
      final props = (r.store.entries.firstWhere((x) => x['id'] == e.id)['props'] as Map).cast<String, Object?>();
      expect(props.containsKey('color'), isFalse);
      expect(props['on_map'], isFalse);
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
    test('seven colours, no red, each with a spoken name; a colour with no name is the first', () {
      expect(kMarkerColors.length, 7);
      expect(kMarkerColors.map((c) => c.id), isNot(contains('red')));
      for (final c in kMarkerColors) {
        expect(c.spoken, isNotEmpty);
        expect(c.color.r > 0.8 && c.color.g < 0.3 && c.color.b < 0.3, isFalse, reason: '${c.id} is not red');
      }
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

    test('a Custom place overrides "Pop up for"; Same follows it; Off silences the place', () async {
      final dir = Directory.systemTemp.createTempSync('cache-popup-');
      final settings = AppSettings(settingsDirOverride: dir);
      await settings.init();
      settings.setPopUpFor(PopUpFor.serious);
      final custom = place('place:custom'), same = place('place:same'), off = place('place:off');
      final views = {
        custom: [view(custom, src('nws', 'alerts'), [item('adv-1')])],
        same: [view(same, src('nws', 'alerts'), [item('adv-2')])],
        off: [view(off, src('nws', 'alerts'), [item('adv-3')])],
      };
      final rules = {
        'place:custom': const PlaceAlertRule(mode: PlaceAlertMode.custom, kinds: {'alerts'}),
        'place:off': const PlaceAlertRule(mode: PlaceAlertMode.off),
      };
      final picked = pickNewAlerts(views, const {}, rules: (id) => rules[id] ?? PlaceAlertRule.same);
      final noon = DateTime(2026, 10, 30, 12);
      final shown = {for (final a in picked) a.item.address: WeatherState.deliveryOf(a, settings, noon)};
      // an advisory (not serious) under "Serious only": the Custom place pops it up, the one that follows the setting does not
      expect(shown, {'adv-1': AlertDelivery.normal, 'adv-2': AlertDelivery.none});
      settings.setPopUpFor(PopUpFor.none);
      expect(WeatherState.deliveryOf(picked.firstWhere((a) => a.custom), settings, noon), AlertDelivery.normal);
      settings.setPopUpFor(PopUpFor.all);
      expect(WeatherState.deliveryOf(picked.firstWhere((a) => !a.custom), settings, noon), AlertDelivery.normal);
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
    test('the centre: the first ring opens the coordinate card, the notebook ring goes back', () {
      expect(ringCentre(notebooks: false, page: 0), RingCentre.coordinates);
      expect(ringCentre(notebooks: true, page: 2), RingCentre.previousPage);
      expect(ringCentre(notebooks: true, page: 0), RingCentre.firstRing);
    });

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

  test('a repeater tapped on the map is selected with its details; each repeater list is a notebook source', () async {
    final u = UserLayersState((call, [arg]) async => switch (call) {
          'list' => {
              'layers': const [],
              'repeater_lists': [
                {'id': 'l2', 'kind': 'repeaters', 'name': 'Magic Valley', 'visible': true, 'repeaters': 3},
                {'id': 'l3', 'kind': 'repeaters', 'name': 'Hidden list', 'visible': false, 'repeaters': 1},
              ],
            },
          'get' when arg == 'l2' => {
              'id': 'l2',
              'name': 'Magic Valley',
              'repeaters': [
                {'item': 1, 'address': 'repeater:l2/1', 'name': 'K7ABC', 'town': 'Twin Falls', 'lat': 42.56, 'lon': -114.46, 'frequency': '146.940 MHz', 'offset': '-0.600 MHz', 'tone': '100.0 Hz', 'mode': 'FM', 'list': 'Magic Valley', 'details_link': 'https://example.org/r/1'},
                {'item': 2, 'address': 'repeater:l2/2', 'name': 'W7XYZ', 'town': 'Burley', 'lat': 42.54, 'lon': -113.79, 'frequency': '449.500 MHz', 'offset': '-5.000 MHz', 'tone': 'none', 'list': 'Magic Valley'},
                {'item': 3, 'address': 'repeater:l2/3', 'name': 'NOPOS', 'town': null, 'lat': null, 'lon': null, 'frequency': '147.000 MHz', 'list': 'Magic Valley'},
              ],
            },
          'get' when arg == 'l3' => {
              'id': 'l3',
              'name': 'Hidden list',
              'repeaters': [
                {'item': 1, 'address': 'repeater:l3/1', 'name': 'K7OFF', 'lat': 43.0, 'lon': -114.0, 'frequency': '145.230 MHz', 'list': 'Hidden list'},
              ],
            },
          _ => const <String, dynamic>{},
        });
    await u.reload();
    final g = await u.mapGeoJson();
    final props = [for (final f in g['features'] as List) (f as Map)['properties'] as Map];
    expect([for (final p in props) (p['list'], p['item'])], [('l2', 1), ('l2', 2)], reason: 'shown lists only, located repeaters only');
    // the map's hit-test reads the tapped feature's properties and selects that repeater
    final ref = repeaterRef(props.first)!;
    expect(u.selectRepeater(ref.$1, ref.$2)?.name, 'K7ABC');
    final r = u.selectedRepeater.value!;
    expect((r.frequency, r.offset, r.tone, r.mode, r.town, r.listName, r.detailsLink),
        ('146.940 MHz', '-0.600 MHz', '100.0 Hz', 'FM', 'Twin Falls', 'Magic Valley', 'https://example.org/r/1'));
    expect(u.selectRepeater('l2', 99), isNull, reason: 'a feature that is not a drawn repeater changes nothing');
    expect(u.selectedRepeater.value?.name, 'K7ABC');
    u.clearRepeater();
    expect(u.selectedRepeater.value, isNull);
    expect(repeaterRef({'layer': 'y1', 'name': 'Walk'}), isNull);
    // every list, shown or hidden, is a notebook source with its rows; nearest first from a position
    final sources = await u.repeaterNotebookSources();
    expect([for (final s in sources) (s.title, s.rows.length)], [('Repeaters: Magic Valley', 3), ('Repeaters: Hidden list', 1)]);
    final near = sources.first.nearest(42.54, -113.80);
    expect([for (final n in near) n.repeater.name], ['W7XYZ', 'K7ABC', 'NOPOS']);
    expect(near.last.metres, isNull);
    expect(near.first.metres!, lessThan(1000));
  });

  test('Home search: notebooks and their entries under Notebooks, places under Places', () async {
    final r = _Rig();
    final places = await r.saved();
    await r.place(places, 'Rally point 1', 42.5630, -114.4610);
    final j = r.nb.journal!;
    await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T10:00:00-06:00', title: 'Rally drill', body: 'Practised the route.');
    final opened = <String>[];
    final books = NotebooksSearchProvider(notebook: r.nb, openNotebook: (n) => opened.add(n.name), openEntry: (n, e) => opened.add(e.title!), now: () => _now);
    final spots = NotebookPlacesSearchProvider(notebook: r.nb, open: (n, e) => opened.add(e.title!), here: () => (lat: 42.56, lon: -114.46), distance: (m) => '${m.round()} m');
    final b = await books.search('rally');
    expect(b.map((x) => (x.title, x.module)), [('Rally drill', 'Notebooks')]);
    expect(b.single.detail, 'Journal · Tue 27 Oct');
    final p = await spots.search('rally');
    expect(p.map((x) => (x.title, x.module)), [('Rally point 1', 'Places')]);
    expect(p.single.detail, startsWith('Places · '));
    p.single.open();
    expect(opened, ['Rally point 1']);
    expect((await books.search('jour')).map((x) => x.title), contains('Journal'));
  });
}
