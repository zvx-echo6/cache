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

  static final RegExp _plain = RegExp(r'[A-Za-z0-9._-]');

  /// The name the keystore keeps [key] under. Only characters the helper's name pattern allows (`[A-Za-z0-9._:-]`, 1 to 120) come
  /// out: letters, digits and `. _ -` stay, and every other character, and `:` itself, becomes `:` and four hex digits (one per
  /// UTF-16 unit), so it is reversible and cannot clash with another key. A name too long for the helper (over 120) keeps its start
  /// and a `.user` ending, with `:h` and a 64-bit hash of the whole key in between, so it stays unique and still ends as it should.
  static String encodeName(String key) {
    final b = StringBuffer();
    for (final u in key.codeUnits) {
      final c = String.fromCharCode(u);
      if (_plain.hasMatch(c)) {
        b.write(c);
      } else {
        b.write(':${u.toRadixString(16).padLeft(4, '0')}');
      }
    }
    final full = b.toString();
    if (full.isNotEmpty && full.length <= 120) return full;
    // FNV-1a, 64 bits, over the UTF-16 units (a stable, dependency-free hash; the name only has to be unique and repeatable).
    var h = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final u in key.codeUnits) {
      h = ((h ^ BigInt.from(u)) * prime) & mask;
    }
    final tail = ':h${h.toRadixString(16).padLeft(16, '0')}${key.endsWith('.user') ? '.user' : ''}';
    if (full.isEmpty) return tail;
    return '${full.substring(0, 120 - tail.length)}$tail';
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
