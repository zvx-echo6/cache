// Renders for review: a repeater list as a notebook (1.1.0). The list (frequency and town, the callsign under it, nearest first,
// "Not in the latest file" on a row the last file no longer lists), a repeater's page (edit, photos, notes, Show on map in its menu),
// the update summary, and the notebook's row in Sharing and sync > Notebooks. 390 wide, Light and Dark.
// flutter test test_shots/repeaters_notebook_renders_test.dart --update-goldens  (pictures in test_shots/repeaters-notebook/)

import 'dart:io';

import 'package:cache/maps/ui/layer_sheet.dart' show importRepeatersIntoNotebook;
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/templates.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/sharing/share_items.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/notebook_fake.dart';
import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'repeaters-notebook';
const Map<String, CacheThemeId> _themes = {'light': CacheThemeId.light, 'dark': CacheThemeId.dark};
final DateTime _now = DateTime(2026, 11, 14, 10, 0);
const PlaceChoices _places = PlaceChoices(here: _home, saved: _saved);
Future<({double lat, double lon})?> _home() async => (lat: 42.5357, lon: -113.7928);
Future<List<NbPlace>> _saved() async => const [];

const _rows = <(String, String, String, String, String, String, double, double, bool?)>[
  ('KX0DEM1', '146.940 MHz', '-600 kHz', '151.4 Hz to transmit and receive', 'FM', 'Burley', 42.54, -113.79, true),
  ('KX0DEM2', '449.500 MHz', '-5 MHz', '100.0 Hz to transmit', 'FM', 'Rupert', 42.62, -113.68, true),
  ('KX0DEM3', '147.360 MHz', '+600 kHz', '100.0 Hz to transmit and receive', 'FM', 'Heyburn', 42.56, -113.76, true),
  ('KX0DEM4', '146.900 MHz', '-600 kHz', '88.5 Hz to transmit', 'FM', 'Albion', 42.41, -113.58, true),
  ('KX0DEM5', '444.200 MHz', '+5 MHz', 'DCS 023', 'DMR', 'Twin Falls', 42.56, -114.46, null),
  ('KX0DEM6', '927.1625 MHz', '-25 MHz', '151.4 Hz to transmit', 'FM', 'Declo', 42.52, -113.37, false),
];

Future<(FakeNotebookBackend, NotebookState, Notebook)> _build() async {
  final store = FakeNotebookBackend();
  final nb = fakeNotebook(store);
  await nb.start();
  final t = Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync()).byId('repeaters')!;
  final book = await nb.saveNotebook(template: t.template, def: t.def, map: t.map, private: false);
  for (final r in _rows) {
    await nb.saveEntry(
      notebookId: book.id,
      occurredAt: '2026-11-14T09:00:00-07:00',
      title: r.$1,
      body: r.$1 == 'KX0DEM1' ? 'Strong here. Checked on the net, Thursday.' : null,
      values: {'f1': r.$2, 'f2': r.$3, 'f3': r.$4, 'f4': r.$5, 'f5': r.$6, 'f6': ?r.$9},
      place: NbPlace(lat: r.$7, lon: r.$8),
    );
  }
  await nb.saveEntry(notebookId: book.id, occurredAt: '2026-11-14T09:30:00-07:00', title: 'KX0MINE', values: {'f1': '146.520 MHz', 'f5': 'My camp'}, place: const NbPlace(lat: 42.50, lon: -113.80));
  return (store, nb, nb.notebook(book.id)!);
}

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUpAll(loadShotFonts);

  for (final MapEntry(key: name, value: theme) in _themes.entries) {
    testWidgets('repeaters as a notebook: list, page, menu, update summary, phone-390, $name', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 3);
      final (store, nb, book) = (await tester.runAsync(_build))!;
      final entries = (await tester.runAsync(() => nb.entries(book.id)))!;
      store.sourceRows = [
        {'key': 'k', 'entry_id': entries.firstWhere((e) => e.title == 'KX0DEM5').id, 'state': 'gone'},
      ];
      final deps = NotebookDeps(notebook: nb, places: _places, now: () => _now, onShowEntry: (_, _) {});
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(shotApp(Navigator(key: nav, onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => NotebookScreen(deps: deps, notebookId: book.id))), theme: theme));
      await _settle(tester);
      expect(find.text('146.940 MHz · Burley'), findsOneWidget);
      await snap(tester, _out, '1-list-390-$name');

      // the notebook's menu
      await tester.tap(find.byKey(const ValueKey('notebook-menu')));
      await _settle(tester, 6);
      await snap(tester, _out, '2-list-menu-390-$name');
      await tester.tapAt(const Offset(20, 400));
      await _settle(tester, 6);

      // the update summary (the core's answer to a newer file)
      store.repeatersAnswer = {
        'notebook': {'id': book.id}, 'added': 2, 'updated': 3, 'unchanged': 1, 'kept_edits': 1, 'not_in_file': 1,
        'deleted': [{'key': 'x', 'title': 'KX0GONE'}],
      };
      final messenger = tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first);
      await tester.runAsync(() => importRepeatersIntoNotebook(messenger, nb, notebookId: book.id, now: () => _now, pick: (use) => use(['/x/repeaters.kml'])));
      await _settle(tester, 6);
      await snap(tester, _out, '3-update-summary-390-$name');
      messenger.hideCurrentSnackBar();
      await _settle(tester, 6);

      // a repeater's page
      await tester.tap(find.byKey(ValueKey('repeater-row-${entries.firstWhere((e) => e.title == 'KX0DEM1').id}')));
      await _settle(tester);
      await snap(tester, _out, '4-entry-390-$name');
      await tester.tap(find.byKey(const ValueKey('editor-menu')));
      await _settle(tester, 6);
      await snap(tester, _out, '5-entry-menu-390-$name');
    });

    testWidgets('repeaters as a notebook: Sharing and sync > Notebooks, phone-390, $name', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 3);
      final r = await SettingsRig.create(tester);
      final (_, nb, book) = (await tester.runAsync(_build))!;
      await tester.runAsync(() async {
        await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Family plan', fields: [], sort: NotebookSort.recent), map: false);
      });
      Directory dir(String n) => Directory('${r.dir.path}/share-$n')..createSync(recursive: true);
      final kinds = [
        DataKind(
          id: 'notebooks',
          label: 'Notebooks',
          icon: Icons.book_outlined,
          shared: () => {'notebooks': dir('notebooks')},
          items: () => notebookItems(nb),
          remoteItem: notebookRemoteItem,
        ),
      ];
      final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: kinds, deviceName: 'Test phone', opener: (_) async => FakeSync());
      await tester.runAsync(() async {
        await sharing.setUp();
        await sharing.setShared(kinds.first, true);
        await sharing.refreshItems();
      });
      r.hub = SettingsHub(sharing: sharing, settings: r.settings, policy: r.policy, webSearch: r.webSearch, storage: r.storage, weather: r.weather, openUrl: (u) async {});
      await tester.pumpWidget(shotApp(SettingsScreen(deps: r.deps), theme: theme));
      await _settle(tester);
      final row = find.byKey(const ValueKey('settings-sharing'));
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await _settle(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('share-notebooks')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('share-notebooks')));
      await _settle(tester);
      expect(find.text(book.name), findsWidgets);
      await snap(tester, _out, '6-sharing-notebooks-390-$name');
      await tester.pumpWidget(const SizedBox());
      sharing.dispose();
      await r.dispose(tester);
    });
  }
}
