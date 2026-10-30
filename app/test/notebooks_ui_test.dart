import 'dart:io';

import 'package:cache/notebook/notebook_map.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/templates.dart';
import 'package:cache/screens/notebooks/notebook_editor.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';

final DateTime _now = DateTime(2026, 10, 29, 16, 12);

Templates _templates() => Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync());

const PlaceChoices _places = PlaceChoices(here: _home, saved: _saved);
Future<({double lat, double lon})?> _home() async => (lat: 43.615, lon: -116.202);
Future<List<NbPlace>> _saved() async => const [NbPlace(lat: 43.6151, lon: -116.2021, label: 'Home', key: 'home')];

class _Rig {
  _Rig() : store = FakeNotebookBackend() {
    nb = fakeNotebook(store);
  }

  final FakeNotebookBackend store;
  late final NotebookState nb;
  NotebookDeps get deps => NotebookDeps(notebook: nb, places: _places, now: () => _now);

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await nb.start();
    await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: buildTheme(CacheThemeId.dark), home: home));
    await tester.pumpAndSettle();
  }

  Future<Notebook> generator({bool withEntry = true, String when = '2026-10-25T16:12:00-06:00'}) async {
    final t = _templates().starters.firstWhere((s) => s.id == 'starter.generator_test');
    final log = await nb.saveNotebook(template: t.template, def: t.def, templateRef: t.ref, map: false);
    if (withEntry) await nb.saveEntry(notebookId: log.id, occurredAt: when, values: {'f1': 20, 'f2': true, 'f3': 'Half'});
    return nb.notebook(log.id)!;
  }
}

void main() {
  testWidgets('a fresh install shows the Journal and New notebook, nothing else', (tester) async {
    final r = _Rig();
    await r.pump(tester, NotebooksScreen(deps: r.deps, templates: _templates()));
    expect(find.text('Notebooks'), findsOneWidget);
    expect(find.text('Journal'), findsOneWidget);
    expect(find.text('Journal · 0 entries'), findsOneWidget);
    expect(find.text('New notebook'), findsOneWidget);
    expect(find.text('Log again'), findsNothing);
    expect(find.text('on map'), findsNothing, reason: 'no entry has a place yet');
  });

  testWidgets('New notebook offers the templates and the starter logs; a starter is made at once and opens its quick add', (tester) async {
    final r = _Rig();
    await r.pump(tester, NotebooksScreen(deps: r.deps, templates: _templates()));
    await tester.tap(find.text('New notebook'));
    await tester.pumpAndSettle();
    for (final t in ['Journal', 'Log', 'Notes', 'Places']) {
      expect(find.byKey(ValueKey('template-${t.toLowerCase()}')), findsOneWidget);
    }
    expect(find.textContaining('Quick add, last done, due again.'), findsOneWidget);
    expect(find.text('Starter logs'), findsOneWidget);
    await tester.tap(find.text('Starter logs'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('HOME'), 300, scrollable: find.byType(Scrollable).last);
    await tester.scrollUntilVisible(find.text('Run time · Under load · Fuel level'), 100, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Generator test'));
    await tester.pumpAndSettle();
    final log = r.nb.logs.single;
    expect((log.name, log.isLog, log.def.dueEvery, log.templateRef), ('Generator test', true, 'month', 'starters/starter.generator_test@1'));
    // the quick add sheet over the new log's screen; with no entries the fields start empty
    expect(find.byKey(const ValueKey('quick-save')), findsOneWidget);
    expect(find.text('Run time'), findsWidgets);
    expect(find.textContaining('last:'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('quick-save')));
    await tester.pumpAndSettle();
    expect(find.text('Saved to Generator test'), findsOneWidget);
    expect(r.store.entries.single['notebook_id'], log.id);
    expect(find.text('LAST DONE'), findsOneWidget);
  });

  testWidgets('quick add starts from the last entry: numbers, choices and Yes/No, with "last:" captions', (tester) async {
    final r = _Rig();
    final g = await r.generator();
    await r.pump(tester, NotebooksScreen(deps: r.deps, templates: _templates()));
    expect(find.text('Log again'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('again-${g.id}')));
    await tester.pumpAndSettle();
    expect(find.text('last: 20 min'), findsOneWidget);
    expect(find.text('last: Yes'), findsOneWidget);
    expect(find.text('last: Half'), findsOneWidget);
    expect(find.widgetWithText(TextField, '20'), findsOneWidget);
    expect(find.text('Values start from your last entry. Change nothing and tap Save.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick-save')));
    await tester.pumpAndSettle();
    final latest = r.store.entries.last;
    expect(latest['values'], {'f1': 20, 'f2': true, 'f3': 'Half'});
    // Undo takes it back out
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(r.store.entries.length, 1);
  });

  testWidgets('a log\'s screen: Last done, Due again, entries by month; overdue on the shelf in words', (tester) async {
    final r = _Rig();
    final g = await r.generator();
    await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: g.id));
    expect(find.text('LAST DONE'), findsOneWidget);
    expect(find.text('4 days ago'), findsOneWidget);
    expect(find.text('Sun 25 Oct · 20 min · Under load: Yes · Fuel level: Half'), findsOneWidget);
    expect(find.text('Due again in 4 weeks (every month)'), findsOneWidget);
    expect(find.text('OCTOBER'), findsOneWidget);
    expect(find.text('Add entry'), findsOneWidget);

    final r2 = _Rig();
    await r2.generator(when: '2026-09-24T16:12:00-06:00');
    await r2.pump(tester, NotebooksScreen(deps: r2.deps, templates: _templates()));
    expect(find.text('Log · Overdue by 5 days'), findsOneWidget);
  });

  testWidgets('Journal: empty state, the editor saves as you type, closing keeps an unfinished entry, Done finishes it', (tester) async {
    final r = _Rig();
    await r.nb.start();
    await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: r.nb.journal!.id));
    expect(find.text('Nothing here yet.'), findsOneWidget);
    await tester.tap(find.text('Write an entry'));
    await tester.pumpAndSettle();
    // only what applies: a journal has no fields, and nothing is attached or checked yet
    expect(find.text('Documents'), findsNothing);
    expect(find.text('Checklist'), findsNothing);
    expect(find.text('Place: Home'), findsOneWidget, reason: 'Here, named from the saved place 15 m away');
    await tester.enterText(find.byKey(const ValueKey('editor-text')), 'Swapped six jugs at the shed.');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(r.store.entries.single['draft'], isTrue);
    await tester.tap(find.byKey(const ValueKey('editor-close')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unfinished entry · Thu 4:12 PM'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-done')));
    await tester.pumpAndSettle();
    expect(r.store.entries.single['draft'], isFalse);
    expect(find.textContaining('Unfinished entry'), findsNothing);
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('Swapped six jugs at the shed.'), findsOneWidget);
    expect(find.text('Thu 29 Oct · Home'), findsOneWidget);
  });

  testWidgets('swipe to delete has Undo; once the time is up the entry is gone', (tester) async {
    final r = _Rig();
    await r.nb.start();
    final j = r.nb.journal!;
    await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-28T09:00:00-06:00', title: 'Rally point', body: 'Meet at the lot.');
    await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: j.id));
    await tester.drag(find.text('Rally point'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Entry deleted'), findsOneWidget);
    expect(find.text('Rally point'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Rally point'), findsOneWidget);
    expect(r.store.entries, hasLength(1));
    await tester.drag(find.text('Rally point'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(r.store.entries, isEmpty);
  });

  testWidgets('a Notes entry shows its checklist (Markdown) and documents; the row counts them', (tester) async {
    final r = _Rig();
    await r.nb.start();
    final notes = await r.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Family plan', fields: [], sort: NotebookSort.recent), map: false);
    await r.nb.saveEntry(
      notebookId: notes.id,
      occurredAt: '2026-10-27T10:00:00-06:00',
      title: 'Medical info: Dad',
      body: 'Blood type O+.\n\n- [x] 30-day supply in go-bag\n- [ ] Spare glasses',
      files: const [NbFile(id: 'd1', name: 'Prescription.pdf', mime: 'application/pdf')],
      private: true,
    );
    await r.pump(tester, NotebookScreen(deps: r.deps, notebookId: notes.id));
    expect(find.text('Medical info: Dad'), findsOneWidget);
    expect(find.text('Blood type O+.'), findsOneWidget);
    expect(find.text('Tue 27 Oct · 1 of 2 done · 1 document · Private'), findsOneWidget);
    await tester.tap(find.text('Medical info: Dad'));
    await tester.pumpAndSettle();
    // the checklist is Markdown in the text, formatted as typed (no separate checklist or formatting buttons)
    final text = tester.widget<TextField>(find.byKey(const ValueKey('editor-text'))).controller!.text;
    expect(text, 'Blood type O+.\n\n- [x] 30-day supply in go-bag\n- [ ] Spare glasses');
    expect(find.text('Checklist'), findsNothing);
    expect(find.byKey(const ValueKey('add-checklist')), findsNothing);
    expect(find.byKey(const ValueKey('markdown-help')), findsOneWidget);
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('Prescription.pdf'), findsOneWidget);
    expect(find.textContaining('Place:'), findsOneWidget);
  });

  testWidgets('the notebook editor: Create needs a name, names are unique, a field\'s type is fixed once entries exist', (tester) async {
    final r = _Rig();
    final g = await r.generator();
    final t = _templates().byId('log')!;
    await r.pump(tester, NotebookEditor(notebook: r.nb, template: t));
    expect(find.text('Due again'), findsOneWidget, reason: 'a log');
    expect(find.text('Show on map'), findsNothing, reason: 'no entries with places');
    await tester.enterText(find.byKey(const ValueKey('notebook-name')), '');
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('notebook-save'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('notebook-name')), 'generator test');
    await tester.pump();
    expect(find.text('You already have a notebook with this name.'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('notebook-save'))).onPressed, isNull);

    await r.pump(tester, NotebookEditor(notebook: r.nb, existing: g));
    await tester.tap(find.text('Run time'));
    await tester.pumpAndSettle();
    expect(find.text("Can't change once entries exist. Add a new field instead."), findsOneWidget);
    expect(find.text('Hide field'), findsOneWidget);

    final notes = _templates().byId('notes')!;
    await r.pump(tester, NotebookEditor(notebook: r.nb, template: notes));
    expect(find.text('Due again'), findsNothing, reason: 'only a log has Due again');
    await tester.tap(find.byKey(const ValueKey('notebook-save')));
    await tester.pumpAndSettle();
    expect(r.nb.notebooks.map((n) => n.name), contains('Notes'));
  });

  testWidgets('search across notebooks groups the hits by notebook', (tester) async {
    final r = _Rig();
    await r.nb.start();
    await r.nb.saveEntry(notebookId: r.nb.journal!.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Water cache restocked', body: 'Six jugs at the shed.');
    await r.pump(tester, NotebooksScreen(deps: r.deps, templates: _templates()));
    await tester.tap(find.byKey(const ValueKey('notebooks-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'jugs');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('JOURNAL'), findsOneWidget);
    expect(find.text('Water cache restocked'), findsOneWidget);
  });

  testWidgets('deleting a notebook asks once, with its entry count', (tester) async {
    final r = _Rig();
    final g = await r.generator();
    await r.pump(tester, NotebooksScreen(deps: r.deps, templates: _templates()));
    await tester.tap(find.byKey(ValueKey('notebook-${g.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notebook-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Show on map'), findsNothing, reason: 'no entries with places');
    await tester.tap(find.text('Delete notebook'));
    await tester.pumpAndSettle();
    expect(find.text("Delete Generator test and its 1 entry? This can't be undone."), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(r.nb.notebook(g.id), isNull);
    expect(r.store.entries, isEmpty);
    expect(find.text('Journal'), findsOneWidget);
  });

  test('My layers are the notebooks with places, by their own names; pins carry their entry', () async {
    final r = _Rig();
    await r.nb.start();
    final rally = await r.nb.saveNotebook(template: 'places', def: const NotebookDef(name: 'Rally points', fields: [], sort: NotebookSort.distance));
    expect(myLayers(r.nb.notebooks), isEmpty);
    await r.nb.saveEntry(notebookId: rally.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Rally point 1', place: const NbPlace(lat: 42.59, lon: -114.4, label: 'Shoshone Falls lot'));
    expect([for (final n in myLayers(r.nb.notebooks)) n.name], ['Rally points']);
    final pins = notebookPinsGeoJson(await r.nb.pins());
    expect(pins['features'], [
      {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [-114.4, 42.59]},
        'properties': {'entry': r.store.entries.last['id'], 'notebook': rally.id, 'title': 'Rally point 1'},
      },
    ]);
    await r.nb.setOnMap(r.nb.notebook(rally.id)!, false);
    expect(await r.nb.pins(), isEmpty);
    expect(myLayers(r.nb.notebooks).single.map, isFalse, reason: 'still listed, switched off');
  });
}
