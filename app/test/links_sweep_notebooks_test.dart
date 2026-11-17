// "Everything that points to something links to it", the Notebooks and Places ones: one test per link. Each taps the words
// and expects the page (or the call) they name. The Library ones are in links_sweep_test.dart.

import 'dart:io';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/notebook/sync/sync_engine.dart';
import 'package:cache/notebook/templates.dart';
import 'package:cache/screens/notebooks/connections_screen.dart';
import 'package:cache/screens/notebooks/entry_editor.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';

final DateTime _now = DateTime(2026, 11, 14, 16, 12);
const PlaceChoices _places = PlaceChoices(here: _here, saved: _saved);
Future<({double lat, double lon})?> _here() async => (lat: 42.56, lon: -114.46);
Future<List<NbPlace>> _saved() async => const [];

Templates _templates() => Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync());

/// A connections object whose news and conflicts the test sets (the sync that finds them is tested elsewhere).
class _Conn extends NotebookConnections {
  _Conn(NotebookState nb) : super(notebook: nb, dir: () async => Directory.systemTemp);

  List<({String app, String target, List<String> titles, Set<String> books, List<String> ids})> news = [];
  List<SyncConflict> found = [];

  @override
  List<({String app, String target, List<String> titles, Set<String> books, List<String> ids})> takeImported() {
    final out = [...news];
    news = [];
    return out;
  }

  @override
  List<SyncConflict> conflicts(String id) => id == 'share' ? found : const [];

  /// Like a sync that has just ended: the screen is told, a moment after it opens.
  @override
  Future<void> syncAll() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    notifyListeners();
  }
}

class _Rig {
  _Rig() : store = FakeNotebookBackend() {
    nb = fakeNotebook(store);
  }

  final FakeNotebookBackend store;
  late final NotebookState nb;
  final List<(double, String)> shown = [];
  final List<String> urls = [];
  _Conn? conn;

  PlaceNotebookDeps get pd => PlaceNotebookDeps(
        watched: (_) => false,
        setWatched: (_, _) {},
        alerts: PlaceAlerts.memory(),
        map: (context, pin, onPick, look) => const SizedBox.expand(),
        showOnMap: (p, name) => shown.add((p.lat, name)),
        openUrl: (u) async => urls.add(u),
      );

  NotebookDeps get deps => NotebookDeps(notebook: nb, places: _places, placesDeps: pd, connections: conn, now: () => _now);

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await nb.start();
    await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: buildTheme(CacheThemeId.dark), home: home));
    await tester.pumpAndSettle();
  }

  Future<Notebook> savedPlaces() async {
    await nb.start();
    return nb.ensureSavedPlaces();
  }

  Future<NbEntry> placeIn(Notebook book, String name, {String? body}) =>
      nb.saveEntry(notebookId: book.id, occurredAt: '2026-11-14T10:00:00-07:00', title: name, body: body, place: const NbPlace(lat: 42.5607, lon: -114.4623));
}

void main() {
  testWidgets('16. A link in a place\'s notes opens in the browser (http and https only)', (tester) async {
    final r = _Rig();
    final book = await r.savedPlaces();
    final e = await r.placeIn(book, 'Trailhead', body: '[the trail guide](https://example.com/guide)\n\n[mail us](mailto:a@example.com)');
    await r.pump(tester, PlaceView(deps: r.deps, book: book, entryId: e.id));
    // the rendered links themselves are tapped
    for (final text in ['the trail guide', 'mail us']) {
      final link = find.descendant(of: find.byKey(const ValueKey('place-notes')), matching: find.text(text, findRichText: true));
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
    }
    expect(r.urls, ['https://example.com/guide']);
  });

  testWidgets('17. The place\'s small map opens Maps on that place', (tester) async {
    final r = _Rig();
    final book = await r.savedPlaces();
    final e = await r.placeIn(book, 'Trailhead');
    await r.pump(tester, PlaceView(deps: r.deps, book: book, entryId: e.id));
    await tester.tap(find.byKey(const ValueKey('place-map-open')));
    await tester.pumpAndSettle();
    expect(r.shown, [(42.5607, 'Trailhead')]);
  });

  testWidgets('18. An ordinary entry with a place: the Place line opens Maps there (so does Show on map in its menu); the button is Edit', (tester) async {
    final r = _Rig();
    await r.nb.start();
    final journal = r.nb.journal!;
    final e = await r.placeIn(journal, 'Fuel stop');
    await r.pump(tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => openNotebookEntry(c, r.deps, journal, e), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(EntryEditor), findsOneWidget);
    expect(find.byIcon(Icons.map_outlined), findsNothing, reason: 'no map icon: the whole place line is the link');
    expect(find.text('Edit'), findsOneWidget, reason: 'the place row\'s button is Edit');
    expect(find.text('Change'), findsNothing);
    await tester.tap(find.textContaining('Place: '));
    await tester.pumpAndSettle();
    expect(r.shown, [(42.5607, 'Fuel stop')]);
    await tester.tap(find.byKey(const ValueKey('editor-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-show-on-map')));
    await tester.pumpAndSettle();
    expect(r.shown, hasLength(2));
  });

  testWidgets('19. "N places added to {notebook}" has Open, which opens that notebook', (tester) async {
    final r = _Rig();
    await r.nb.start();
    r.store.importPoints = [
      {'name': 'Spring', 'lat': 42.1, 'lon': -114.1, 'notes': null},
    ];
    final opened = <String>[];
    await r.pump(tester, Scaffold(body: Builder(builder: (c) => TextButton(
      onPressed: () => importPlacesInto(c, r.nb, now: () => _now, onOpen: opened.add, pick: (use) => use('/tmp/x.kml', 'x.kml')),
      child: const Text('import'),
    ))));
    await tester.tap(find.text('import'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('1 place added to'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Open'));
    await tester.pumpAndSettle();
    expect(opened, [r.nb.notebooks.firstWhere((n) => n.name == 'Imported places').id]);
  });

  group('the message after a file was added', () {
    test('a points-only file keeps its wording', () {
      expect(placesImportMessage(places: 1, shapes: 0, notebook: 'Places'), '1 place added to Places');
      expect(placesImportMessage(places: 4, shapes: 0, notebook: 'Places'), '4 places added to Places');
    });

    test('a lines-only file says the lines became a map layer, singular and plural', () {
      expect(placesImportMessage(places: 0, shapes: 1, layer: 'Proof line'), 'Added 1 line or area as the map layer "Proof line".');
      expect(placesImportMessage(places: 0, shapes: 2, layer: 'X'), 'Added 2 lines or areas as the map layer "X".');
    });

    test('a mixed file says both, singular and plural', () {
      expect(placesImportMessage(places: 3, shapes: 2, notebook: 'Places', layer: 'X'), 'Added 3 places to Places and 2 lines or areas as the map layer "X".');
      expect(placesImportMessage(places: 1, shapes: 1, notebook: 'Places', layer: 'X'), 'Added 1 place to Places and 1 line or area as the map layer "X".');
    });
  });

  testWidgets('a lines-only file: "Added 2 lines or areas as the map layer", and no notebook is made', (tester) async {
    final r = _Rig();
    await r.nb.start();
    r.store
      ..importLines = 1
      ..importAreas = 1
      ..importLayer = 'Proof line';
    final before = r.nb.notebooks.length;
    await r.pump(tester, Scaffold(body: Builder(builder: (c) => TextButton(
      onPressed: () => importPlacesInto(c, r.nb, now: () => _now, pick: (use) => use('/tmp/x.geojson', 'x.geojson')),
      child: const Text('import'),
    ))));
    await tester.tap(find.text('import'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Added 2 lines or areas as the map layer "Proof line".'), findsOneWidget);
    expect(r.nb.notebooks.length, before);
  });

  testWidgets('20. "Added from Obsidian: {title}": Show opens that entry when one note came in', (tester) async {
    final r = _Rig();
    await r.nb.start();
    final journal = r.nb.journal!;
    final e = await r.nb.saveEntry(notebookId: journal.id, occurredAt: '2026-11-14T10:00:00-07:00', title: 'Stove');
    r.conn = _Conn(r.nb)..news = [(app: 'Obsidian', target: 't1', titles: ['Stove'], books: {journal.id}, ids: [e.id])];
    await r.pump(tester, NotebooksScreen(deps: r.deps, templates: _templates()));
    expect(find.text('Added from Obsidian: Stove.'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Show'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.byType(EntryEditor), findsOneWidget);
  });

  testWidgets('22. A "Changed in two places" card opens that entry', (tester) async {
    final r = _Rig();
    await r.nb.start();
    final journal = r.nb.journal!;
    final e = await r.nb.saveEntry(notebookId: journal.id, occurredAt: '2026-11-14T10:00:00-07:00', title: 'Water cache restocked');
    r.conn = _Conn(r.nb)..found = [SyncConflict(entryId: e.id, kind: ConflictKind.bothChanged, title: 'Water cache restocked', path: 'Water.md', cacheText: 'a', fileText: 'b')];
    await r.pump(tester, ConnectionsScreen(connections: r.conn!, folders: false, shareAvailable: true, deps: r.deps));
    expect(find.text('Changed in two places: Water cache restocked'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('conflict-open-${e.id}')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.byType(EntryEditor), findsOneWidget);
  });
}
