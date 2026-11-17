// general.name read from a GGUF file's header (tiny synthetic headers, never a real model): the name, and a safe null for
// anything that is not a readable header.

import 'dart:io';

import 'package:cache/models/gguf_header.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gguf_bytes.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('gguf_name'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(List<int> bytes) {
    final f = File('${dir.path}/m${dir.listSync().length}.gguf')..writeAsBytesSync(bytes);
    return f.path;
  }

  test('reads general.name, after other pairs', () {
    final p = write(ggufBytes([kvString('general.architecture', 'llama'), kvU32('general.file_type', 2), kvString('general.name', 'SmolLM2 135M Instruct')]));
    expect(readGgufGeneralName(p), 'SmolLM2 135M Instruct');
  });

  test('no general.name is null', () {
    expect(readGgufGeneralName(write(ggufBytes([kvString('general.architecture', 'llama')]))), isNull);
  });

  test('a name that is not a string is null', () {
    expect(readGgufGeneralName(write(ggufBytes([kvU32('general.name', 7)]))), isNull);
  });

  test('garbage, truncated and missing files are null, not an error', () {
    expect(readGgufGeneralName(write(const [])), isNull);
    expect(readGgufGeneralName(write(List.filled(64, 0x41))), isNull);
    expect(readGgufGeneralName(write(ggufBytes([kvString('general.name', 'X')], magic: const [0x47, 0x47, 0x55, 0x45]))), isNull, reason: 'wrong magic');
    expect(readGgufGeneralName(write(ggufBytes([kvString('general.name', 'X')], version: 99))), isNull, reason: 'unknown version');
    final whole = ggufBytes([kvString('general.name', 'SmolLM2 135M Instruct')]);
    for (final n in [3, 8, 20, 30, whole.length - 3]) {
      expect(readGgufGeneralName(write(whole.sublist(0, n))), isNull, reason: 'cut at $n');
    }
    expect(readGgufGeneralName('${dir.path}/nope.gguf'), isNull);
  });

  test('sizes are not trusted: huge counts and lengths are null', () {
    expect(readGgufGeneralName(write(ggufBytes([kvString('general.name', 'X')], kvCount: 1 << 40))), isNull, reason: 'a huge pair count');
    expect(readGgufGeneralName(write(ggufBytes([kvString('general.name', 'X')], kvCount: 0x7fffffff))), isNull);
    // a key length of 2^62 with nothing behind it
    final hugeKey = [...ggufBytes([], kvCount: 1), 0, 0, 0, 0, 0, 0, 0, 0x40];
    expect(readGgufGeneralName(write(hugeKey)), isNull);
    // a name that claims 1 GiB but is cut
    final hugeName = [...ggufBytes([], kvCount: 1), ...ggufString('general.name'), 8, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0x41];
    expect(readGgufGeneralName(write(hugeName)), isNull);
  });
}
