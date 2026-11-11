// Notebook field sync (design only): what a person sees when a sync brings two fields with the same label ("Phone" and
// "Phone (2)") in the entry form and the field editor, and a notebook with more than 12 fields in the editor (all fields shown;
// Add field off with the store's existing cap text; PROPOSED, drawn by a render-only copy of the editor). 390 wide, light, dark and
// Tactical. The notebook is made on a fake store; nothing here is product logic.
// flutter test test_shots/field_sync_renders_test.dart --update-goldens  (pictures in test_shots/field_sync/)

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/entry_editor.dart';
import 'package:cache/screens/notebooks/notebook_editor.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/notebook_fake.dart';
import 'field_sync/editor_proposed.dart';
import 'shot_kit.dart';

const _out = 'field_sync';

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

LogField _t(String label) => LogField(label: label, type: FieldType.text);

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
    final t = theme.name;
    testWidgets('two fields with one label $t', (tester) async {
      final store = FakeNotebookBackend();
      final nb = fakeNotebook(store);
      await tester.runAsync(nb.start);
      final book = (await tester.runAsync(() => nb.saveNotebook(
        template: 'blank',
        def: NotebookDef(name: 'Contacts', fields: [_t('Name'), _t('Phone'), _t('Phone (2)'), _t('Email')]),
      )))!;
      phone(tester, size: const Size(390, 844));
      await tester.pumpWidget(shotApp(
        EntryEditor(notebook: nb, book: book, places: PlaceChoices.none, now: () => DateTime(2026, 11, 10, 10, 0)),
        theme: theme,
      ));
      await _settle(tester);
      await snap(tester, _out, '1-entry-form-$t');
      await tester.pumpWidget(shotApp(NotebookEditor(notebook: nb, existing: book), theme: theme));
      await _settle(tester);
      await snap(tester, _out, '2-field-editor-$t');
      await tester.pumpWidget(shotApp(const SizedBox(), theme: theme));
      nb.dispose();
    });

    testWidgets('more than 12 fields $t', (tester) async {
      final store = FakeNotebookBackend();
      final nb = fakeNotebook(store);
      await tester.runAsync(nb.start);
      final labels = ['Name', 'Phone', 'Phone (2)', 'Email', 'Street', 'City', 'Company', 'Role', 'Website', 'Birthday', 'Nickname', 'Owner', 'Source', 'Group'];
      final book = (await tester.runAsync(() => nb.saveNotebook(
        template: 'blank',
        def: NotebookDef(name: 'Contacts', fields: [for (final l in labels) _t(l)]),
      )))!;
      // Tall enough to show every row and the Add field line under them.
      phone(tester, size: const Size(390, 1500));
      await tester.pumpWidget(shotApp(ProposedNotebookEditor(notebook: nb, existing: book), theme: theme));
      await _settle(tester);
      expect(find.byKey(const ValueKey('field-cap')), findsOneWidget);
      await snap(tester, _out, '3-more-than-12-$t');
      await tester.pumpWidget(shotApp(const SizedBox(), theme: theme));
      nb.dispose();
    });
  }
}
