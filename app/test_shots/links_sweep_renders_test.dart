// Links sweep (quick ones), four screens in the light theme at 390 wide: a Book page's Subject fact, the Add PDF result cards, an
// ordinary notebook entry with a place, and the Sharing items page. Built from the branch tests' own fixtures.
// flutter test test_shots/links_sweep_renders_test.dart --update-goldens  (pictures in test_shots/links_sweep/)
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/add_pdf/add_pdf_pages.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/sharing/share_items.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/add_pdf/add_pdf_world.dart';
import '../test/browse/fakes.dart';
import '../test/library/fake_shelves.dart';
import '../test/library/library_fixtures.dart';
import '../test/support/notebook_fake.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

final DateTime _now = DateTime(2026, 11, 14, 16, 12);
const PlaceChoices _places = PlaceChoices(here: _here, saved: _saved);
Future<({double lat, double lon})?> _here() async => (lat: 42.56, lon: -114.46);
Future<List<NbPlace>> _saved() async => const [];

class _NbRig {
  _NbRig() : store = FakeNotebookBackend() {
    nb = fakeNotebook(store);
  }

  final FakeNotebookBackend store;
  late final NotebookState nb;
  final List<(double, String)> shown = [];
  final List<String> urls = [];
  NotebookConnections? conn;

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
    phone(tester, size: const Size(390, 844), ratio: 2);
    await nb.start();
    await tester.pumpWidget(shotApp(home));
    await tester.pumpAndSettle();
  }

  Future<Notebook> savedPlaces() async {
    await nb.start();
    return nb.ensureSavedPlaces();
  }

  Future<NbEntry> placeIn(Notebook book, String name, {String? body}) =>
      nb.saveEntry(notebookId: book.id, occurredAt: '2026-11-14T10:00:00-07:00', title: name, body: body, place: const NbPlace(lat: 42.5607, lon: -114.4623));
}

/// Sharing on a fake engine in a temp folder, with Library (ZIMs and libraries), Models and Notebooks (one private).
class _ShRig {
  _ShRig(this.dir) {
    for (final d in ['zims', 'libraries', 'models', 'notebook-share']) {
      Directory('${dir.path}/$d').createSync(recursive: true);
    }
  }

  final Directory dir;
  final sync = FakeSync();
  final configs = <Map<String, Object?>>[];

  /// The private notebook's "Include in sync and sharing".
  bool privateIncluded = false;
  final privateSet = <bool>[];

  late final List<DataKind> kinds = [
    DataKind(
      id: 'library',
      label: 'Library',
      icon: Icons.menu_book_outlined,
      shared: () => {'library': Directory('${dir.path}/zims'), 'libraries': Directory('${dir.path}/libraries')},
      items: () => const [
        ShareItem(share: 'library', path: 'wikimed.zim', name: 'Medical encyclopedia', bytes: 1400 << 20),
        ShareItem(share: 'library', path: 'canning.zim', name: 'Home canning', bytes: 29 << 20),
        ShareItem(share: 'libraries', path: 'field-manuals', name: 'Field manuals', bytes: 7700 << 20),
      ],
      remoteItem: libraryRemoteItem,
    ),
    DataKind(
      id: 'models',
      label: 'Models',
      icon: Icons.memory,
      shared: () => {'models': Directory('${dir.path}/models')},
      items: () => const [ShareItem(share: 'models', path: 'gemma.gguf', name: 'Gemma 4 E2B', bytes: 3200 << 20)],
      remoteItem: modelRemoteItem,
    ),
    DataKind(
      id: 'notebooks',
      label: 'Notebooks',
      icon: Icons.book_outlined,
      shared: () => {'notebooks': Directory('${dir.path}/notebook-share')},
      items: () => [
        const ShareItem(share: 'notebooks', path: 'Journal', name: 'Journal'),
        ShareItem(share: 'notebooks', path: 'Health log', name: 'Health log', private: true, on: privateIncluded),
      ],
      remoteItem: notebookRemoteItem,
      setPrivate: (it, on) async {
        privateSet.add(on);
        privateIncluded = on;
      },
    ),
  ];

  DataKind kind(String id) => kinds.firstWhere((k) => k.id == id);

  SharingState make() => SharingState(
    policy: testPolicy(wifi: true),
    supportDir: () async => dir,
    kinds: kinds,
    opener: (c) async {
      configs.add(c);
      return sync;
    },
  );

  List<Map<String, Object?>> calls(String m) => sync.argsOf[m] ?? const [];
}

Future<_ShRig> _shRig() async => _ShRig(await Directory.systemTemp.createTemp('sharing-items'));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadShotFonts);
  const folder = 'links_sweep';

  testWidgets('a. Book page: the Subject fact', (tester) async {
    phone(tester, size: const Size(390, 844), ratio: 2);
    Directory? tmp;
    FakeSources? sources;
    LibrariesState? libs;
    CdsShelfSource? shelves;
    BrowseState? browse;
    addTearDown(() {
      shelves?.dispose();
      browse?.dispose();
      libs?.dispose();
      sources?.dispose();
      indexSchedulerShared = null;
    });
    await tester.runAsync(() async {
      tmp = Directory.systemTemp.createTempSync('links-shot');
      writeBookLibrary(Directory('${tmp!.path}/libraries'), 'field', const [
        ('aid', 'Wilderness first aid', '210', null),
        ('surgery', 'Emergency war surgery', '210', null),
        ('bees', 'Keeping bees in cold climates', '350', null),
      ], pdfs: {'aid'});
      sources = FakeSources(Directory('${tmp!.path}/zims')..createSync(recursive: true));
      libs = await librariesAt(Directory('${tmp!.path}/libraries'), sources!);
      shelves = CdsShelfSource(libs!, calls: FakeShelvesCalls(), bookshelvesDir: () async => Directory('${tmp!.path}/bookshelves'), deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
      await shelves!.whenRead();
      browse = BrowseState(sources: sources!, libraries: libs!, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
    });
    await tester.pumpWidget(shotApp(LibraryPanes(
      root: (_) => LibraryRootPage(deps: testDeps(browse: browse!, shelves: shelves!)),
      prefs: PanePrefs(dirOverride: tmp!),
    )));
    await tester.pumpAndSettle();
    for (final k in ['library-bookshelves', 'shelf-200', 'shelf-210', 'book-surgery']) {
      final f = find.byKey(ValueKey(k));
      await tester.ensureVisible(f.first);
      await tester.tap(f.first);
      await _settle(tester);
    }
    await tester.pumpAndSettle();
    await snap(tester, folder, 'a-book-subject');
    addTearDown(() {
      try {
        tmp?.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  testWidgets('b. Add PDF result cards: Filed in, Same file as', (tester) async {
    phone(tester, size: const Size(390, 844), ratio: 2);
    AddPdfWorld? w;
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    addTearDown(() => w!.dispose());
    w!.done(w!.filed);
    w!.done(w!.spare);
    await tester.pumpWidget(shotApp(AddPdfProgressPage(state: w!.state, deps: w!.deps, scheduler: w!.scheduler)));
    await _settle(tester);
    await snap(tester, folder, 'b-add-pdf-result');
  });

  testWidgets('c. Notebook entry with a place: Show on map', (tester) async {
    final r = _NbRig();
    await r.nb.start();
    final journal = r.nb.journal!;
    final e = await r.placeIn(journal, 'Fuel stop');
    await r.pump(tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => openNotebookEntry(c, r.deps, journal, e), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await snap(tester, folder, 'c-entry-place');
  });

  testWidgets('d. Sharing items: a notebook row opens the notebook, the switch toggles', (tester) async {
    phone(tester, size: const Size(390, 844), ratio: 2);
    final r = (await tester.runAsync(_shRig))!;
    final s = r.make();
    await tester.runAsync(s.setUp);
    await tester.runAsync(() => s.setShared(r.kind('notebooks'), true));
    await tester.pumpWidget(shotApp(SharingKindPage(sharing: s, kind: r.kind('notebooks'), onOpenItem: (context, kind, item) => item.path == 'Journal' ? () {} : null)));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    await snap(tester, folder, 'd-sharing-items');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      s.dispose();
      await r.dir.delete(recursive: true);
    });
  });
}
