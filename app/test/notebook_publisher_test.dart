import 'dart:convert';
import 'dart:io';

import 'package:cache/actions/action_registry.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_publisher.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/notebook_text.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';
import 'support/parity_fixtures.dart';

const Map<String, dynamic> _logShape = {'sort': 'recent', 'quick_add': true};

Future<Notebook> _log(NotebookState nb, String name, List<Map<String, dynamic>> fields, {bool private = false, String? due}) async =>
    nb.saveNotebook(template: 'log', def: NotebookDef.fromJson({'name': name, 'due_every': due, 'fields': fields}, shape: _logShape), private: private);

Future<void> _entry(NotebookState nb, Notebook n, String when, Map<String, dynamic> values) =>
    nb.saveEntry(notebookId: n.id, occurredAt: when, values: values);

void main() {
  final now = DateTime(2026, 10, 29, 16, 12);

  test('Log notebooks made in the store give the captures\' definitions byte for byte (nb-067, notebook_actions.py)', () async {
    final nb = fakeNotebook(FakeNotebookBackend());
    await nb.start();
    final pellets = await _log(nb, 'Pellet bags', [
      {'label': 'Bags', 'type': 'number'},
      {'label': 'Brand', 'type': 'text'},
    ]);
    final hay = await _log(nb, 'Hay bales', [
      {'label': 'Bales', 'type': 'number'},
      {'label': 'Cutting', 'type': 'choice', 'choices': ['First', 'Second', 'Third']},
      {'label': 'Field', 'type': 'text'},
    ]);
    final eggs = await _log(nb, 'Chicken eggs', [
      {'label': 'Eggs', 'type': 'number'},
      {'label': 'Flock', 'type': 'text'},
    ]);
    // Used in this order, so the most recently used (Chicken eggs) is listed first.
    await _entry(nb, pellets, '2025-12-01T08:13:00-07:00', {'f1': 20, 'f2': 'Hot Ash'});
    await _entry(nb, hay, '2026-01-01T13:33:00-07:00', {'f1': 140, 'f2': 'Second', 'f3': 'river pasture'});
    await _entry(nb, eggs, '2026-01-01T17:22:00-07:00', {'f1': 7, 'f2': 'pullets'});

    // The generator's input is the harness's input for these logs.
    final fixture = [for (final l in (parityJson('notebook-logs-nb-067.json') as Map)['logs'] as List) l];
    expect(jsonEncode([for (final l in nb.logs) generatorInput(l)]), jsonEncode(fixture));

    final reg = ActionRegistry();
    NotebookPublisher(registry: reg, notebook: nb, now: () => now).start();
    final notebookPart = jsonEncode(reg.definitions);
    // act-definitions-nb-067.json is the app's actions followed by the Notebook's, as the harness's script made them.
    expect(parityText('act-definitions-nb-067.json').endsWith(',${notebookPart.substring(1)}\n'), isTrue, reason: notebookPart);
    expect(reg.rejected, isEmpty);
  });

  group('what is published', () {
    late NotebookState nb;
    late ActionRegistry reg;
    late FakeNotebookBackend store;

    setUp(() async {
      store = FakeNotebookBackend();
      nb = fakeNotebook(store);
      await nb.start();
      reg = ActionRegistry();
      NotebookPublisher(registry: reg, notebook: nb, now: () => now).start();
    });

    List<String> ids() => [for (final d in reg.definitions) d['id'] as String];

    test('the journal alone until a log exists; private logs are published (never locked); at most 8, most recently used first', () async {
      expect(ids(), ['notebook.add_journal_entry']);
      // A notes or places notebook publishes nothing of its own.
      await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Family plan', fields: [], sort: NotebookSort.recent));
      expect(ids(), ['notebook.add_journal_entry']);
      final meds = await _log(nb, 'Medication doses', [{'label': 'Dose', 'type': 'number', 'unit': 'mg'}], private: true);
      expect(ids(), ['notebook.add_journal_entry', 'notebook.log_medication_doses']);
      for (var i = 1; i <= 8; i++) {
        await _log(nb, 'Log $i', [{'label': 'Count', 'type': 'number'}]);
      }
      expect(ids().length, 9);
      expect(ids()[1], 'notebook.log_log_8');
      expect(ids(), isNot(contains('notebook.log_medication_doses')), reason: 'the least recently used is the ninth');
      await _entry(nb, meds, '2026-10-29T08:00:00-06:00', {'f1': 200});
      expect(ids()[1], 'notebook.log_medication_doses');
      expect(reg.definitions[1]['description'], "Add an entry to the user's Medication doses log. Last: 2026-10-29 08:00, Dose 200 mg.");
    });

    test('a tap writes the entry by field id, with When from date and time, and answers with the log\'s labels', () async {
      final g = await _log(nb, 'Generator test', [
        {'label': 'Run time', 'type': 'number', 'unit': 'min'},
        {'label': 'Under load', 'type': 'yes_no'},
        {'label': 'Fuel level', 'type': 'choice', 'choices': ['Full', 'Half', 'Low']},
        {'label': 'Gauge', 'type': 'photo'},
      ]);
      final def = reg.definition('notebook.log_generator_test')!;
      expect((def.json['fields'] as Map).keys, ['run_time_min', 'under_load', 'fuel_level', 'place', 'date', 'time', 'notes']);
      final r = await reg.run('notebook.log_generator_test', {'run_time_min': 20.0, 'under_load': true, 'fuel_level': 'Full', 'date': '2026-10-25', 'time': '16:12', 'notes': 'Oil fine'});
      expect(r['ok'], isTrue, reason: '$r');
      expect(r['result'], {'saved': true, 'log': 'Generator test', 'when': '2026-10-25T16:12', 'values': {'Run time': '20 min', 'Under load': 'Yes', 'Fuel level': 'Full'}});
      final e = (await nb.entries(g.id)).single;
      expect(e.values, {'f1': 20, 'f2': true, 'f3': 'Full'});
      expect(e.body, 'Oil fine');
      expect(wallClock(e.occurredAt), DateTime(2026, 10, 25, 16, 12));
      // The card names the log's own labels and units; no date means Now.
      final lines = reg.cardLines('notebook.log_generator_test', {'run_time_min': 15, 'under_load': false}, const [])!;
      expect([for (final l in lines) '${l.key}: ${l.value}'], ['Run time: 15 min', 'Under load: No', 'When: Now · Thu 29 Oct, 4:12 PM']);
    });

    test('a log deleted after its actions were published fails plainly and leaves the list', () async {
      final w = await _log(nb, 'Water rotation', [{'label': 'Containers', 'type': 'number', 'unit': 'jugs'}]);
      final handlerBefore = reg.definition('notebook.log_water_rotation');
      expect(handlerBefore, isNotNull);
      await nb.deleteNotebook(w.id);
      expect(ids(), ['notebook.add_journal_entry']);
      final r = await reg.run('notebook.log_water_rotation', {'containers_jugs': 6});
      expect(r['ok'], isFalse);
    });

    test('add_journal_entry writes to the Journal; with the Journal deleted it makes one again', () async {
      final r = await reg.run('notebook.add_journal_entry', {'text': 'Water cache restocked at the shed.', 'title': 'Water', 'place': {'lat': 43.6, 'lon': -116.2, 'name': 'Home'}});
      expect(r['result'], {'saved': true, 'title': 'Water'});
      final j = nb.journal!;
      final e = (await nb.entries(j.id)).single;
      expect((e.title, e.body, e.place?.label), ('Water', 'Water cache restocked at the shed.', 'Home'));
      await nb.deleteNotebook(j.id);
      expect(nb.journal, isNull);
      await reg.run('notebook.add_journal_entry', {'text': 'Again'});
      expect(nb.journal?.name, 'Journal');
      expect(reg.run('notebook.add_journal_entry', {'text': '  '}), completion(containsPair('ok', false)));
    });
  });

  test('the starter logs asset is the spec\'s file, unchanged', () {
    expect(File('assets/notebook/starters.json').readAsStringSync(), parityText('notebook-starters-input.json'));
  });

  test('due again, last done and checklists in words', () {
    final now = DateTime(2026, 10, 29, 16, 12);
    expect(agoText(DateTime(2026, 10, 25, 9), now), '4 days ago');
    expect(agoText(DateTime(2026, 10, 28, 23), now), 'yesterday');
    expect(agoText(DateTime(2026, 5, 20), now), '5 months ago');
    expect(dueDate(DateTime(2026, 1, 31), 'month'), DateTime(2026, 2, 28));
    expect(dueDate(DateTime(2026, 10, 25), '3 months'), DateTime(2027, 1, 25));
    expect(dueDate(DateTime(2026, 10, 25), '2 weeks'), DateTime(2026, 11, 8));
    expect(everyText('6 months'), 'every 6 months');
    Notebook log(String occurred, String? due) => Notebook(
          id: 'x',
          template: 'log',
          def: NotebookDef(name: 'Generator test', fields: const [LogField(fid: 'f1', label: 'Run time', type: FieldType.number, unit: 'min')], dueEvery: due, quickAdd: true),
          lastEntry: NbEntry(id: 'e', notebookId: 'x', occurredAt: occurred, values: const {'f1': 20}),
        );
    expect(dueAgainText(log('2026-10-25T16:12:00-06:00', 'month'), now), 'Due again in 4 weeks (every month)');
    expect(dueCue(log('2026-09-24T16:12:00-06:00', 'month'), now)?.text, 'Overdue by 5 days');
    expect(dueCue(log('2026-09-24T16:12:00-06:00', null), now), isNull);
    expect(lastDoneText(log('2026-10-25T16:12:00-06:00', null), now), 'Last done 4 days ago · 20 min');
    final (text, items) = splitChecklist('Blood type O+.\n\n- [x] 30-day supply\n- [ ] Spare glasses');
    expect(text, 'Blood type O+.');
    expect([for (final i in items) (i.text, i.done)], [('30-day supply', true), ('Spare glasses', false)]);
    expect(joinChecklist(text, items), 'Blood type O+.\n\n- [x] 30-day supply\n- [ ] Spare glasses');
    expect(joinChecklist('', const []), '');
  });
}
