import 'package:cache/settings/key_names.dart';
import 'package:cache/settings/server_token_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The browser's store and the helper (server/helper/bin/server_settings_sync.dart) must give one key the same keystore name: both use
/// settings/key_names.dart.
void main() {
  test('the browser store\'s encodeName is the shared encodeKeyName', () {
    for (final k in [
      'search.kagi.key', 'live.key.owm', 'live.key.a~b', 'live.key.é ü', 'live.key.日本', 'video.host:8080.access', 'live.key.a:b',
      'live.key.${'x' * 200}', 'video.${'ö' * 90}.user', '',
    ]) {
      expect(ServerTokenStore.encodeName(k), encodeKeyName(k), reason: k);
    }
  });

  test('known names', () {
    expect(encodeKeyName('search.kagi.key'), 'search.kagi.key');
    expect(encodeKeyName('live.key.a~b'), 'live.key.a:007eb');
    expect(encodeKeyName('a b:c'), 'a:0020b:003ac');
  });

  test('decodeKeyName gives the name back for every name that can be decoded, and null for a hashed or foreign one', () {
    for (final k in ['search.kagi.key', 'live.key.owm', 'live.key.a~b', 'live.key.é ü', 'live.key.日本', 'live.key.a:b', 'video.host:8080.access']) {
      expect(decodeKeyName(encodeKeyName(k)), k, reason: k);
    }
    expect(decodeKeyName(encodeKeyName('live.key.${'x' * 200}')), isNull, reason: 'a name cut and hashed cannot be told');
    expect(decodeKeyName('live.key.a:zz'), isNull);
    expect(decodeKeyName('live.key.a:00'), isNull);
    expect(decodeKeyName('has space'), isNull);
    expect(decodeKeyName(''), isNull);
  });
}
