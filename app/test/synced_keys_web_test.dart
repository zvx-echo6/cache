import 'package:cache/settings/web_search_setup.dart' show WebSearchSetup;
import 'package:cache/sharing/synced_settings.dart';
import 'package:cache/video/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

/// A browser's store: it hands out references, never keys.
class _References implements TokenStore {
  @override
  Future<String?> read(String key) async => 'keystore://$key';
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  testWidgets('a reference is never sent to another device as a key; a browser sends nothing; a phone sends the key', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() => r.webSearch.saveKey('k1'));
    Future<List<String?>> sent(TokenStore secrets) async =>
        [for (final k in appSyncedKeys(weather: r.weather, webSearch: r.webSearch, secrets: secrets)) await k.read()];
    expect(await tester.runAsync(() => sent(_References())), [null]);
    expect(await tester.runAsync(() => sent(const NoTokenStore())), [null]);
    expect(await tester.runAsync(() => sent(r.secrets..values[WebSearchSetup.keyName] = 'k1')), ['k1']);
    await r.dispose(tester);
  });
}
