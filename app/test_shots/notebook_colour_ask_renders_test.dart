// RENDER ONLY, for the owner's wording approval: the question Cache will ask when a notebook's color is changed and some of its
// places hold their own colors. The behavior is not built; this draws the dialog and nothing more. 390 wide, in Light, Dark,
// Tactical and Parchment.
// flutter test test_shots/notebook_colour_ask_renders_test.dart --update-goldens  (pictures in test_shots/notebook-colour-ask/)

import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

const Map<String, CacheThemeId> _themes = {
  'light': CacheThemeId.light,
  'dark': CacheThemeId.dark,
  'tactical': CacheThemeId.tactical,
  'parchment': CacheThemeId.parchment,
};

/// The notebook page behind the question, so the dialog is seen where it will appear.
class _Behind extends StatelessWidget {
  const _Behind({required this.colorName, required this.places, required this.notebook});

  final String colorName, notebook;
  final int places;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit notebook')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Name', style: TextStyle(fontSize: 16, color: k.text)),
        Text(notebook, style: TextStyle(fontSize: 14, color: k.secondary)),
        const SizedBox(height: 16),
        Text('Pin color', style: TextStyle(fontSize: 16, color: k.text)),
        Text(colorName, style: TextStyle(fontSize: 14, color: k.secondary)),
      ]),
    );
  }
}

void main() {
  setUpAll(loadShotFonts);

  for (final MapEntry(key: name, value: theme) in _themes.entries) {
    testWidgets('notebook color ask, phone-390, $name', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 3);
      await tester.pumpWidget(shotApp(const _Behind(colorName: 'Blue', places: 3, notebook: 'Trail log'), theme: theme));
      await tester.pump();
      final ctx = tester.element(find.byType(Scaffold));
      showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          title: const Text('Change all its places to Blue?'),
          content: const Text('3 places in Trail log have their own color.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep their colors')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Change all')),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await snap(tester, 'notebook-colour-ask', '390-$name');
    });
  }
}
