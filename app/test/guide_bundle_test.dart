// The guide library in the assets is the version the app installs: its cache-library.json says kGuideVersion, so a phone
// with an older copy gets this one, and one with this one keeps it.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/sources/libraries_state.dart' show kGuideLibraryId, kGuideVersion;
import 'package:flutter_test/flutter_test.dart';

/// The named member of an uncompressed tar, or null.
Uint8List? _member(Uint8List tar, String name) {
  var at = 0;
  while (at + 512 <= tar.length) {
    final header = tar.sublist(at, at + 512);
    if (header.every((b) => b == 0)) return null;
    String field(int from, int len) => ascii.decode(header.sublist(from, from + len).takeWhile((b) => b != 0).toList()).trim();
    final path = field(0, 100);
    final size = int.parse(field(124, 12).isEmpty ? '0' : field(124, 12), radix: 8);
    final start = at + 512;
    if (path == name || path == './$name') return tar.sublist(start, start + size);
    at = start + ((size + 511) ~/ 512) * 512;
  }
  return null;
}

void main() {
  test('the bundled guide library is kGuideVersion', () {
    final tar = Uint8List.fromList(gzip.decode(File('assets/guide/cache-guide.cache-library').readAsBytesSync()));
    final settings = _member(tar, 'cache-library.json');
    expect(settings, isNotNull, reason: 'cache-library.json at the root of the bundled guide');
    final j = jsonDecode(utf8.decode(settings!)) as Map<String, dynamic>;
    expect(j['library_id'], kGuideLibraryId);
    expect(j['version'], kGuideVersion);
  });
}
