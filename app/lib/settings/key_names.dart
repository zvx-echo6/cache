final RegExp _plainNameChar = RegExp(r'[A-Za-z0-9._-]');

/// The name the server's keystore keeps an app key under (settings/server_token_store.dart for the browser, and the helper's
/// settings sync in server/helper/bin). Flutter-free, so both use this one copy.
///
/// Only characters the helper's name pattern allows (`[A-Za-z0-9._:-]`, 1 to 120) come
/// out: letters, digits and `. _ -` stay, and every other character, and `:` itself, becomes `:` and four hex digits (one per
/// UTF-16 unit), so it is reversible and cannot clash with another key. A name too long for the helper (over 120) keeps its start
/// and a `.user` ending, with `:h` and a 64-bit hash of the whole key in between, so it stays unique and still ends as it should.
String encodeKeyName(String key) {
  final b = StringBuffer();
  for (final u in key.codeUnits) {
    final c = String.fromCharCode(u);
    if (_plainNameChar.hasMatch(c)) {
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

