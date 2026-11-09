import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/models/gguf_header.dart';
import 'package:cache/platform/memory.dart';
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

GgufHeader _fixture(String name) {
  final j = jsonDecode(File('test/fixtures/gguf/$name.json').readAsStringSync()) as Map<String, dynamic>;
  return GgufHeader(3, (j['metadata'] as Map<String, dynamic>).cast<String, Object?>(), [
    for (final t in j['tensors'] as List) GgufTensor(t[0] as String, (t[2] as List).cast<int>(), t[1] as int),
  ]);
}

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

  test('token_embd is lookup-only only when the model has a separate output.weight; tied, it is read in full', () {
    GgufHeader toy({required bool separateOutput}) => GgufHeader(3, const {
      'general.architecture': 'toy',
      'toy.block_count': 2,
    }, [
      const GgufTensor('token_embd.weight', [64, 1000], 8), // row 2 * 34 = 68 bytes
      const GgufTensor('blk.0.attn_q.weight', [64, 64], 8), // 64 * 68 = 4352
      if (separateOutput) const GgufTensor('output.weight', [64, 1000], 8),
    ]);
    const nCtx = 256;
    final tied = memoryNeedFromHeader(toy(separateOutput: false), nCtx: nCtx);
    expect(tied.lookup, 0);
    expect(tied.outputEmbd, 68 * 1000);
    expect(tied.core, 4352);
    final split = memoryNeedFromHeader(toy(separateOutput: true), nCtx: nCtx);
    expect(split.lookup, 68 * nCtx, reason: 'one row per token of the context');
    expect(split.outputEmbd, 68 * 1000, reason: 'output.weight only');
    expect(split.core, 4352);
    expect(memoryNeedFromHeader(toy(separateOutput: true), nCtx: 5000).lookup, 68 * 1000, reason: 'never more rows than the table has');
    expect(split.kv, 0, reason: 'the toy has no attention keys: nothing to count');
    expect(split.total, split.core + split.outputEmbd + split.lookup + split.kv + kComputeAllowance + kAnswerHeadroom);
  });

  // The three real Gemma 4 E2B headers (tensor lists and the metadata the need reads, test/fixtures/gguf). 35 layers, 15 own KV
  // (3 global of 8192 cells, 12 sliding of 1024: n_swa 512 + n_ubatch 512), q8_0 K and V.
  const oldNeed = {'e2b_q4km': 3301863782, 'qat_q4_0': 3357016064, 'unsloth_qat': 2859746824}; // the size-based number of each file
  const expected = {
    // (core, output/embd, lookup, kv, total) at n_ctx 8192
    'e2b_q4km': (1155000460, 330301440, 60211200, 33423360, 2250025100),
    'qat_q4_0': (1076639884, 330301440, 60211200, 33423360, 2171664524),
    'unsloth_qat': (1056856204, 226492416, 41287680, 33423360, 2029148300),
  };
  for (final e in expected.entries) {
    test('${e.key}: the need at 8192 tokens is pinned and far below the size-based one', () {
      final n = memoryNeedFromHeader(_fixture(e.key), nCtx: 8192);
      expect((n.core, n.outputEmbd, n.lookup, n.kv, n.total), e.value);
      expect(n.compute, 256 << 20);
      expect(n.headroom, 384 << 20);
      expect(n.total, lessThan(oldNeed[e.key]! * 0.75));
      expect(modelMemoryNeedFromHeader(_fixture(e.key), nCtx: 8192), n.total);
      expect(n.logLine, startsWith('Memory need: ${n.total >> 20} MB (core ${n.core >> 20} MB, output/embd'));
      expect(n.logLine, endsWith('from header'));
    });
  }

  test('a file whose header cannot be read falls back to the size-based need, and says so', () async {
    final f = File('${dir.path}/junk.gguf')..writeAsBytesSync(List.filled(64, 0));
    final n = (await memoryNeedForFile(f.path, nCtx: 8192))!;
    expect(n.fromHeader, isFalse);
    expect(n.total, modelMemoryNeedBySize(64));
    expect(n.logLine, endsWith('fallback'));
    expect(await modelMemoryNeedForFile(f.path, fallbackBytes: 3 * (1 << 30)), modelMemoryNeedBySize(3 * (1 << 30)));
  });

  test('a readable file gives the tensor-aware need', () async {
    final file = _file([
      (g) => g
        ..str('general.architecture')
        ..u32(8)
        ..str('toy'),
    ], [('token_embd.weight', 8, [64, 100])]);
    final f = File('${dir.path}/toy.gguf')..writeAsBytesSync(file);
    final n = (await memoryNeedForFile(f.path, nCtx: 8192))!;
    expect(n.fromHeader, isTrue);
    expect(n.outputEmbd, 68 * 100);
  });
}
