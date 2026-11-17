import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/web_search_setup.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/video/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _Online implements ConnectionProbe {
  @override
  Future<ConnectionKind> current() async => ConnectionKind.wifi;

  @override
  Stream<ConnectionKind> get changes => const Stream.empty();
}

WebSearchSetup _setup(MemoryTokenStore secrets, AppSettings s) =>
    WebSearchSetup(settings: s, secrets: secrets, setWeb: (p, k, o) async {}, probe: _Online());

void main() {
  test('this tab\'s position, in the shape setLocation sends, or null with none', () async {
    final s = SourcesState(coreExtras: const {});
    addTearDown(s.dispose);
    expect(s.requestLocation, isNull);
    await s.setLocation(43.6, -116.2, accuracyM: 12.5, at: DateTime.utc(2026, 11, 17, 16));
    final l = s.requestLocation!;
    expect(l.keys.toSet(), {'lat', 'lon', 'accuracyM', 'fixedAt'});
    expect(l['lat'], 43.6);
    expect(l['lon'], -116.2);
    expect(l['accuracyM'], 12.5);
    expect(l['fixedAt'], isA<String>());
    await s.setLocation(null, null);
    expect(s.requestLocation, isNull);
  });

  test('web search for a request: provider, reference, online when on; null when off; never a raw key', () async {
    final settings = AppSettings();
    final secrets = MemoryTokenStore();
    final w = _setup(secrets, settings);
    await w.init();
    expect(w.requestWeb, isNull, reason: 'no key, off');
    await secrets.write(WebSearchSetup.keyName, 'keystore://search.kagi.key');
    await w.keepKey('keystore://search.kagi.key');
    settings.setWebSearchOn(true);
    await w.setEnabled(true);
    final r = w.requestWeb!;
    expect(r.keys.toSet(), {'provider', 'reference', 'online'});
    expect(r['provider'], 'kagi');
    expect(r['reference'], 'keystore://search.kagi.key');
    expect(r['online'], true);
    await w.setEnabled(false);
    expect(w.requestWeb, isNull);
  });

  test('a raw key is never sent as the reference', () async {
    final settings = AppSettings();
    final secrets = MemoryTokenStore();
    final w = _setup(secrets, settings);
    await w.init();
    await w.keepKey('raw-secret-key');
    await w.setEnabled(true);
    expect(w.requestWeb, isNull);
  });
}
