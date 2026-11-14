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
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' show MarkdownBody;
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
    final e = await r.placeIn(book, 'Trailhead', body: '[the trail guide](https://example.com/guide)');
    await r.pump(tester, PlaceView(deps: r.deps, book: book, entryId: e.id));
    final notes = tester.widget<MarkdownBody>(find.byKey(const ValueKey('place-notes')));
    notes.onTapLink!('the trail guide', 'https://example.com/guide', '');
    notes.onTapLink!('mail', 'mailto:a@example.com', '');
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

  testWidgets('18. An ordinary entry with a place offers Show on map, from its place line and its menu', (tester) async {
    final r = _Rig();
    await r.nb.start();
    final journal = r.nb.journal!;
    final e = await r.placeIn(journal, 'Fuel stop');
    await r.pump(tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => openNotebookEntry(c, r.deps, journal, e), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(EntryEditor), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('place-show-on-map')));
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
