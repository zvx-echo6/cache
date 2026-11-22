import 'package:cache/app_state.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

void main() {
  testWidgets('Cache model and web search: with the chosen model let go from memory, the row names it, not "Choose a model"', (tester) async {
    final r = await SettingsRig.create(tester);
    r.app.resting = ModelEntry(path: '${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf', size: 16);
    await r.show(tester, SettingsScreen(deps: r.deps));
    await tester.pump();
    expect(find.text('Choose a model · web search off'), findsNothing);
    expect(find.text('${r.app.displayName(r.app.resting!)} · web search off'), findsOneWidget);
    await r.dispose(tester);
  });
}
