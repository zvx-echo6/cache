import 'package:cache_search/cache_search.dart' show CoreTransport;

import '../video/token_store.dart';

/// The browser's [TokenStore]: the keys (the web search key, data-source keys, video tokens, the app PIN) are kept on Cache for
/// Linux in its keystore (the helper's `keys.*` ops, server/helper/bin/keystore.dart), so every browser has the same ones and a
/// server restart loses nothing.
///
/// [read] never hands a secret back. For a key it answers a reference, `keystore://<name>` (empty-or-not works as before), and the
/// helper swaps the reference for the key when a core op that carries it runs (`setWeb`, a video call), so the key never reaches
/// the page. The exceptions are what the phone's own screens show or check: a sign-in user name (`*.user`) and the PIN hash
/// (`app.pin`, salted PBKDF2, which the page verifies). Any other key is not readable here.
class ServerTokenStore implements TokenStore {
  const ServerTokenStore(this._t);

  final CoreTransport _t;

  static const String refPrefix = 'keystore://';

  /// The name the keystore keeps [key] under: letters, digits and `. _ : -` stay, every other character becomes `~` and four
  /// hex digits.
  static String encodeName(String key) {
    final b = StringBuffer();
    for (final u in key.codeUnits) {
      final c = String.fromCharCode(u);
      if (RegExp(r'[A-Za-z0-9._:-]').hasMatch(c)) {
        b.write(c);
      } else {
        b.write('~${u.toRadixString(16).padLeft(4, '0')}');
      }
    }
    return b.toString();
  }

  static bool _shown(String name) => name == 'app.pin' || name.endsWith('.user');

  @override
  Future<String?> read(String key) async {
    final name = encodeName(key);
    if (_shown(key)) return await _t.call('keys.get', {'name': name}) as String?;
    final names = (await _t.call('keys.names', const {}) as List).cast<String>();
    return names.contains(name) ? '$refPrefix$name' : null;
  }

  @override
  Future<void> write(String key, String value) async {
    await _t.call('keys.set', {'name': encodeName(key), 'value': value});
  }

  @override
  Future<void> delete(String key) async {
    await _t.call('keys.delete', {'name': encodeName(key)});
  }
}
