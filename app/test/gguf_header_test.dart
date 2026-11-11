import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/models/gguf_header.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes a GGUF header by hand.
class _Gguf {
  final _b = BytesBuilder();
  void u32(int v) => _b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u64(int v) => _b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void f32(double v) => _b.add((ByteData(4)..setFloat32(0, v, Endian.little)).buffer.asUint8List());
  void str(String s) {
    final e = utf8.encode(s);
    u64(e.length);
    _b.add(e);
  }

  void bytes(List<int> v) => _b.add(v);
  Uint8List build() => _b.toBytes();
}

/// A model header: [meta] writes the metadata (count first), [tensors] are (name, type, dims).
Uint8List _file(List<void Function(_Gguf)> meta, List<(String, int, List<int>)> tensors) {
  final g = _Gguf()
    ..bytes(utf8.encode('GGUF'))
    ..u32(3)
    ..u64(tensors.length)
    ..u64(meta.length);
  for (final m in meta) {
    m(g);
  }
  for (final t in tensors) {
    g
      ..str(t.$1)
      ..u32(t.$3.length);
    for (final d in t.$3) {
      g.u64(d);
    }
    g
      ..u32(t.$2)
      ..u64(0);
  }
  return g.build();
}

void Function(_Gguf) _kvInt(String k, int v) => (g) => g
  ..str(k)
  ..u32(4)
  ..u32(v);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('gguf-header'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the reader reads metadata of several types, arrays (small kept, long skipped) and the tensor list', () {
    final bigStrings = List.generate(5000, (i) => 'tok$i');
    final file = _file([
      (g) => g
        ..str('general.architecture')
        ..u32(8)
        ..str('toy'),
      _kvInt('toy.block_count', 4),
      (g) => g
        ..str('toy.u8')
        ..u32(0)
        ..bytes([7]),
      (g) => g
        ..str('toy.rope')
        ..u32(6)
        ..f32(0.5),
      (g) => g
        ..str('toy.flag')
        ..u32(7)
        ..bytes([1]),
      (g) => g
        ..str('toy.big')
        ..u32(10)
        ..u64(1 << 33),
      (g) => g
        ..str('toy.pattern')
        ..u32(9)
        ..u32(7)
        ..u64(3)
        ..bytes([1, 0, 1]),
      (g) => g
        ..str('toy.names')
        ..u32(9)
        ..u32(8)
        ..u64(2)
        ..str('ab')
        ..str('c'),
      (g) {
        g
          ..str('tokenizer.tokens')
          ..u32(9)
          ..u32(8)
          ..u64(bigStrings.length);
        for (final s in bigStrings) {
          g.str(s);
        }
      },
      (g) {
        g
          ..str('tokenizer.scores')
          ..u32(9)
          ..u32(6)
          ..u64(6000)
          ..bytes(List.filled(24000, 0));
      },
      _kvInt('toy.after', 99),
    ], [
      ('token_embd.weight', 8, [64, 100]),
      ('blk.0.attn_q.weight', 12, [256, 8]),
      ('output_norm.weight', 0, [64]),
    ]);
    final path = '${dir.path}/toy.gguf';
    File(path).writeAsBytesSync(file);

    // a small chunk: the reader refills many times, including after the skipped arrays
    final h = readGgufHeader(path, chunk: 64)!;
    expect(h.version, 3);
    expect(h.metadata['general.architecture'], 'toy');
    expect(h.intOf('toy.block_count'), 4);
    expect(h.metadata['toy.u8'], 7);
    expect(h.metadata['toy.rope'], 0.5);
    expect(h.metadata['toy.flag'], true);
    expect(h.metadata['toy.big'], 1 << 33);
    expect(h.metadata['toy.pattern'], [true, false, true]);
    expect(h.metadata['toy.names'], ['ab', 'c']);
    expect((h.metadata['tokenizer.tokens'] as GgufBigArray).length, 5000);
    expect((h.metadata['tokenizer.scores'] as GgufBigArray).length, 6000);
    expect(h.intOf('toy.after'), 99, reason: 'reading continues right after the skipped arrays');
    expect(h.tensors.map((t) => t.name), ['token_embd.weight', 'blk.0.attn_q.weight', 'output_norm.weight']);
    expect(h.tensors[0].dims, [64, 100]);
    expect(h.tensors[0].rowBytes, 2 * 34);
    expect(h.tensors[0].bytes, 2 * 34 * 100);
    expect(h.tensors[1].bytes, 144 * 8, reason: 'Q4_K: 256 elements in 144 bytes');
    expect(h.tensors[2].bytes, 64 * 4);
  });

  test('a file that is not a version 3 GGUF, or that ends inside the header, gives null', () {
    File('${dir.path}/a.gguf').writeAsBytesSync(utf8.encode('not a model at all'));
    expect(readGgufHeader('${dir.path}/a.gguf'), isNull);
    final v2 = _file([], []);
    v2[4] = 2;
    File('${dir.path}/v2.gguf').writeAsBytesSync(v2);
    expect(readGgufHeader('${dir.path}/v2.gguf'), isNull);
    final cut = _file([_kvInt('toy.x', 1)], [('t', 0, [4])]);
    File('${dir.path}/cut.gguf').writeAsBytesSync(cut.sublist(0, cut.length - 5));
    expect(readGgufHeader('${dir.path}/cut.gguf'), isNull);
    expect(readGgufHeader('${dir.path}/missing.gguf'), isNull);
    final unknownType = _file([], [('t', 99, [4])]);
    File('${dir.path}/u.gguf').writeAsBytesSync(unknownType);
    expect(readGgufHeader('${dir.path}/u.gguf'), isNull, reason: 'a type whose size is not known is not guessed');
  });
}
