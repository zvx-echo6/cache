import 'dart:io';

import 'package:cache/maps/ui/layer_sheet.dart' show importRepeatersIntoNotebook;
import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/notebook_map.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/place_style.dart' show markerColor;
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/templates.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/sharing/share_items.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';

/// Repeater lists as notebooks: the template, the rows, the update from a file, "Show on map", the map look, Sharing and sync.
/// The merge, the migration and what Ask sees are the core's, tested in Rust (cache_search/tests/nbrepeaters_ffi.rs).

final DateTime _now = DateTime(2026, 11, 14, 10, 0);
const PlaceChoices _places = PlaceChoices(here: _home, saved: _saved);
Future<({double lat, double lon})?> _home() async => (lat: 42.5357, lon: -113.7928);
Future<List<NbPlace>> _saved() async => const [];

Templates _templates() => Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync());

Future<(FakeNotebookBackend, NotebookState, Notebook)> _repeaters() async {
  final store = FakeNotebookBackend();
  final nb = fakeNotebook(store);
  await nb.start();
  final t = _templates().byId('repeaters')!;
  final book = await nb.saveNotebook(template: t.template, def: t.def, map: t.map);
  Future<void> add(String call, String freq, String town, double lat, {bool? onAir}) => nb.saveEntry(
        notebookId: book.id,
        occurredAt: '2026-11-14T09:00:00-07:00',
        title: call,
        values: {'f1': freq, 'f5': town, 'f6': ?onAir},
        place: NbPlace(lat: lat, lon: -113.8),
      );
  await add('W0TST1', '146.940 MHz', 'Burley', 42.54, onAir: true);
  await add('W0TST2', '449.500 MHz', 'Rupert', 42.62);
  return (store, nb, nb.notebook(book.id)!);
}

NotebookDeps _deps(NotebookState nb, {void Function(NbEntry, Notebook)? onShowEntry}) =>
    NotebookDeps(notebook: nb, places: _places, now: () => _now, onShowEntry: onShowEntry);

void main() {
  test('the Repeaters template: seven fixed fields, the radio tower, purple, nearest first, on the map', () {
    final t = _templates().byId('repeaters')!;
    expect(t.def.visible.map((f) => (f.label, f.type)), [
      ('Frequency', FieldType.text),
      ('Offset', FieldType.text),
      ('Tone', FieldType.text),
      ('Mode', FieldType.text),
      ('Town', FieldType.text),
      ('On air', FieldType.yesNo),
      ('Details link', FieldType.text),
    ]);
    expect((t.def.icon, t.def.color, t.def.sort, t.map, t.count(2)), ('radio_tower', 'purple', NotebookSort.distance, true, '2 repeaters'));
  });

  test('a repeater notebook is a notebook: on the map with the radio tower in its colour, in Sharing and sync > Notebooks', () async {
    final (_, nb, book) = await _repeaters();
    expect(book.isRepeaters, isTrue);
    expect(book.isPlaces, isFalse);
    expect(defaultNotebookIcon(book), kRepeaterIcon);
    final e = (await nb.entries(book.id)).first;
    final look = PinLook.of(e, book);
    expect((look.icon.id, look.tint), (kRepeaterIcon, markerColor('purple').color));
    expect((await nb.pins()).length, 2, reason: 'both have places, so both are pins');
    expect([for (final i in notebookItems(nb)) i.name], contains(book.name));
    expect(notebookItems(nb).firstWhere((i) => i.name == book.name).private, isFalse);
  });

  test('every entry is asked for, not the core\'s first 1000', () async {
    final store = FakeNotebookBackend();
    final nb = fakeNotebook(store);
    await nb.start();
    final book = await nb.saveNotebook(template: 'repeaters', def: _templates().byId('repeaters')!.def);
    for (var i = 0; i < 1200; i++) {
      store.entries.add({
        'id': 'e$i', 'notebook_id': book.id, 'occurred_at': '2026-11-14T09:00:00-07:00', 'title': 'R$i', 'values': {}, 'photos': [], 'files': [],
        'draft': false, 'private': false, 'created': i, 'updated': i, 'rev': 1,
      });
    }
    expect((await nb.entries(book.id)).length, 1200);
  });

  testWidgets('the list shows frequency and town, the callsign under it and the nearest first; Update from a file is in the menu', (tester) async {
    final (store, nb, book) = await _repeaters();
    store.sourceRows = [
      {'key': 'k', 'entry_id': (await nb.entries(book.id)).firstWhere((e) => e.title == 'W0TST2').id, 'state': 'gone'},
    ];
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: NotebookScreen(deps: _deps(nb), notebookId: book.id)));
    await tester.pumpAndSettle();
    expect(find.text('146.940 MHz · Burley'), findsOneWidget);
    expect(find.text('W0TST1'), findsOneWidget);
    expect(find.text('449.500 MHz · Rupert'), findsOneWidget);
    expect(find.text('Not in the latest file'), findsOneWidget, reason: 'only the row the latest file lacks');
    final top = tester.getTopLeft(find.text('146.940 MHz · Burley')).dy, next = tester.getTopLeft(find.text('449.500 MHz · Rupert')).dy;
    expect(top < next, isTrue, reason: 'nearest first');
    await tester.tap(find.byKey(const ValueKey('notebook-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Update from a file'), findsOneWidget);
    expect(find.text('Edit notebook'), findsOneWidget, reason: 'the notebook can be renamed like any other');
  });

  testWidgets('a repeater opens its page, which edits it and has Show on map', (tester) async {
    final (_, nb, book) = await _repeaters();
    NbEntry? shown;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: NotebookScreen(deps: _deps(nb, onShowEntry: (e, _) => shown = e), notebookId: book.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('repeater-row-${(await nb.entries(book.id)).firstWhere((e) => e.title == 'W0TST1').id}')));
    await tester.pumpAndSettle();
    expect(find.text('Frequency'), findsWidgets);
    // edit the town; it is saved to the entry, keeping its place and its other values
    await tester.enterText(find.widgetWithText(TextField, 'Burley'), 'Burley (south)');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('editor-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-show-on-map')));
    await tester.pumpAndSettle();
    expect(shown?.title, 'W0TST1');
    final saved = (await nb.entries(book.id)).firstWhere((e) => e.title == 'W0TST1');
    expect((saved.values['f5'], saved.values['f1'], saved.place?.lat), ('Burley (south)', '146.940 MHz', 42.54));
  });

  testWidgets('saving an entry in the editor keeps its own icon, colour and map switch', (tester) async {
    final (_, nb, book) = await _repeaters();
    final e = (await nb.entries(book.id)).first;
    await nb.saveEntry(id: e.id, notebookId: book.id, occurredAt: e.occurredAt, title: e.title, values: e.values, place: e.place, props: {'icon': 'repeater', 'color': 'red'});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: NotebookScreen(deps: _deps(nb), notebookId: book.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('repeater-row-${e.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('editor-text')), 'a note');
    await tester.pump(const Duration(seconds: 1));
    final after = (await nb.entries(book.id)).firstWhere((x) => x.id == e.id);
    expect((after.body, after.icon, after.color), ('a note', 'repeater', 'red'));
  });

  group('Update from a file says what happened', () {
    Future<(ScaffoldMessengerState, GlobalKey<ScaffoldMessengerState>)> bar(WidgetTester tester) async {
      final key = GlobalKey<ScaffoldMessengerState>();
      await tester.pumpWidget(MaterialApp(scaffoldMessengerKey: key, theme: buildTheme(CacheThemeId.light), home: const Scaffold(body: SizedBox())));
      return (key.currentState!, key);
    }

    Future<RepeaterUpdate> use(Future<RepeaterUpdate> Function(List<String>) f) => f(['/x/repeaters.kml', '/x/repeaters.csv']);

    testWidgets('a first file: "Added 214 repeaters", with Show', (tester) async {
      final store = FakeNotebookBackend()..repeatersAnswer = {'notebook': {'id': 'nb1'}, 'added': 214, 'without_position': 3, 'repeaters': 214};
      final nb = fakeNotebook(store);
      await nb.start();
      final (m, _) = await bar(tester);
      String? shownId;
      final id = await importRepeatersIntoNotebook(m, nb, onShow: (i) => shownId = i, pick: use);
      await tester.pump();
      expect(id, 'nb1');
      expect(find.textContaining('Added 214 repeaters to Notebooks.'), findsOneWidget);
      expect(find.textContaining('3 have no position'), findsOneWidget);
      tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
      expect(shownId, 'nb1');
      expect(store.repeatersCalls.single['paths'], ['/x/repeaters.kml', '/x/repeaters.csv']);
      expect(store.repeatersCalls.single.containsKey('notebook_id'), isFalse);
    });

    testWidgets('an update: what changed, what stayed, and "Add them back" for what the person deleted', (tester) async {
      final store = FakeNotebookBackend()
        ..repeatersAnswer = {
          'notebook': {'id': 'nb1'}, 'added': 1, 'updated': 4, 'unchanged': 200, 'kept_edits': 2, 'not_in_file': 5,
          'deleted': [{'key': 'a', 'title': 'KX0DEL'}],
        }
        ..repeatersAddBack = 1;
      final nb = fakeNotebook(store);
      await nb.start();
      final (m, _) = await bar(tester);
      await importRepeatersIntoNotebook(m, nb, notebookId: 'nb1', now: () => _now, pick: use);
      await tester.pump();
      expect(store.repeatersCalls.single['notebook_id'], 'nb1');
      expect(find.textContaining('1 added, 4 changed, your edits kept on 2, 5 not in the latest file'), findsOneWidget);
      expect(find.textContaining('1 repeater you deleted is still in the file and stays deleted'), findsOneWidget);
      expect(find.text('Add them back'), findsOneWidget);
      tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
      await tester.pump();
      expect(store.calls, contains('repeaters_add_back'));
    });

    testWidgets('a file that changes nothing says so; a file with no repeaters says so', (tester) async {
      final store = FakeNotebookBackend()..repeatersAnswer = {'notebook': {'id': 'nb1'}, 'unchanged': 218};
      final nb = fakeNotebook(store);
      await nb.start();
      final (m, _) = await bar(tester);
      await importRepeatersIntoNotebook(m, nb, notebookId: 'nb1', pick: use);
      await tester.pump();
      expect(find.textContaining('Nothing changed'), findsOneWidget);
      store.failNext = 'bad_json';
      final id = await importRepeatersIntoNotebook(m, nb, notebookId: 'nb1', pick: use);
      await tester.pump();
      expect(id, isNull);
      expect(find.text('Choose another file'), findsOneWidget);
    });
  });
}
