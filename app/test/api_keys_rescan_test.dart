import 'package:flutter_test/flutter_test.dart';

import 'package:cache/screens/settings_screen.dart';

import 'support/settings_rig.dart';

void main() {
  testWidgets('Settings "API keys" row: a key that appears in the key store without this page saving it shows after a re-read, with no reload', (tester) async {
    final r = await SettingsRig.create(tester);
    await r.show(tester, SettingsScreen(deps: r.deps));
    expect(find.text('No keys yet'), findsOneWidget);

    // in a browser the keys live on the server: one can arrive from another tab or a linked device
    await r.secrets.write('search.kagi.key', 'KAGI-SECRET-1');
    await tester.runAsync(r.hub.apiKeys.rescan);
    await tester.pump();
    expect(find.text('No keys yet'), findsNothing);
    expect(find.text('1 key saved'), findsOneWidget);

    await r.secrets.delete('search.kagi.key');
    await tester.runAsync(r.hub.apiKeys.rescan);
    await tester.pump();
    expect(find.text('No keys yet'), findsOneWidget);
    await r.dispose(tester);
  });
}
