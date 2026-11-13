// Renders for review: the notebook editor of 1.1, whose fields are shown read only (the field editor is gone: a notebook keeps the
// fields it was made with). An existing log, 390 wide, in Light and Dark.
// flutter test test_shots/notebook_fields_readonly_renders_test.dart --update-goldens  (pictures in test_shots/notebook-fields-readonly/)

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/screens/notebooks/icon_picker.dart';
import 'package:cache/screens/notebooks/notebook_editor.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/notebook_fake.dart';
import 'shot_kit.dart';

const Map<String, CacheThemeId> _themes = {'light': CacheThemeId.light, 'dark': CacheThemeId.dark};

void main() {
  setUpAll(loadShotFonts);

  for (final MapEntry(key: name, value: theme) in _themes.entries) {
    testWidgets('notebook editor, fields read only, phone-390, $name', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 3);
      final nb = fakeNotebook(FakeNotebookBackend());
      final log = await tester.runAsync(() async {
        await nb.start();
        final made = await nb.saveNotebook(
          template: 'log',
          def: const NotebookDef(
            name: 'Vehicle maintenance',
            fields: [
              LogField(label: 'Vehicle', type: FieldType.text),
              LogField(label: 'Work done', type: FieldType.choice, choices: ['Oil', 'Tires', 'Filters', 'Battery', 'Other']),
              LogField(label: 'Odometer', type: FieldType.number, unit: 'mi'),
              LogField(label: 'Place', type: FieldType.place),
            ],
            dueEvery: '6 months',
            quickAdd: true,
            sort: NotebookSort.recent,
          ),
          map: false,
        );
        return nb.notebook(made.id)!;
      });
      await tester.pumpWidget(shotApp(NotebookEditor(notebook: nb, existing: log, icons: MapIconSetup.fixed()), theme: theme));
      await tester.pumpAndSettle();
      expect(find.text('FIELDS'), findsOneWidget);
      expect(find.text('Number · mi'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-field')), findsNothing);
      await snap(tester, 'notebook-fields-readonly', '390-$name');
    });
  }
}
