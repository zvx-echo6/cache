import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/models/gguf_header.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/platform/memory_need.dart';
import 'package:flutter_test/flutter_test.dart';

GgufHeader _fixture(String name) {
  final j = jsonDecode(File('test/fixtures/gguf/$name.json').readAsStringSync()) as Map<String, dynamic>;
  return GgufHeader(3, (j['metadata'] as Map<String, dynamic>).cast<String, Object?>(), [
    for (final t in j['tensors'] as List) GgufTensor(t[0] as String, (t[2] as List).cast<int>(), t[1] as int),
  ]);
}

/// A GGUF header written by hand: one tensor and the architecture.
Uint8List _toyFile() {
  final b = BytesBuilder();
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u64(int v) => b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void str(String s) {
    u64(utf8.encode(s).length);
    b.add(utf8.encode(s));
  }

  b.add(utf8.encode('GGUF'));
  u32(3);
  u64(2); // tensors
  u64(1); // metadata
  str('general.architecture');
  u32(8);
  str('toy');
  str('token_embd.weight');
  u32(2);
  u64(64);
  u64(100);
  u32(8); // Q8_0
  u64(0);
  str('per_layer_token_embd.weight');
  u32(2);
  u64(64);
  u64(1000);
  u32(8);
  u64(0);
  return b.toBytes();
}

void main() {
  // The three real Gemma 4 E2B headers (tensor lists and the metadata the need reads). 35 layers, 15 own KV (3 global of 8192
  // cells, 12 sliding of 1024: n_swa 512 + n_ubatch 512), f16 K and V. The expected numbers were computed apart from the code.
  const expected = {
    // (weights without per_layer_token_embd, kv, total) at n_ctx 8192
    'e2b_q4km': (1485301900, 62914560, 2135419020),
    'qat_q4_0': (1406941324, 62914560, 2057058444),
    'unsloth_qat': (1283348620, 62914560, 1933465740),
  };
  for (final e in expected.entries) {
    test('${e.key}: weights without the per-layer table, f16 KV and the 560 MiB compute reserve, pinned', () {
      final n = memoryNeedFromHeader(_fixture(e.key), nCtx: 8192);
      expect((n.weights, n.kv, n.total), e.value);
      expect(n.compute, 560 << 20);
      expect(kChatComputeReserve, 560 << 20);
      expect(n.fromHeader, isTrue);
      expect(n.logLine, startsWith('Memory need: ${n.total >> 20} MB (weights ${n.weights >> 20} MB'));
    });
  }

  test('the per-layer table is left out: with it the weights would be the whole file', () {
    final h = _fixture('e2b_q4km');
    final all = h.tensors.fold<int>(0, (a, t) => a + t.bytes);
    final ple = h.tensors.where((t) => t.name.startsWith('per_layer_token_embd')).fold<int>(0, (a, t) => a + t.bytes);
    expect(ple, greaterThan(1 << 30));
    expect(memoryNeedFromHeader(h, nCtx: 8192).weights, all - ple);
    // per_layer_model_proj is not the table: it stays counted
    expect(h.tensors.any((t) => t.name == 'per_layer_model_proj.weight'), isTrue);
  });

  test('a Gemma 4 E2B Q4_K_M needs about 2.0 GiB, against 3.1 GiB by the size-based estimate', () {
    final n = memoryNeedFromHeader(_fixture('e2b_q4km'), nCtx: 8192).total;
    expect(n >> 20, 2036);
    expect(modelMemoryNeed(3427879936) >> 20, 3148);
  });

  test('a bigger context grows the KV only', () {
    final h = _fixture('e2b_q4km');
    final a = memoryNeedFromHeader(h, nCtx: 8192), b = memoryNeedFromHeader(h, nCtx: 16384);
    expect(b.weights, a.weights);
    expect(b.kv, greaterThan(a.kv));
  });

  test('a readable file gives the header need; one that is not falls back to the size-based need and says so', () async {
    final dir = Directory.systemTemp.createTempSync('memory-need');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ok = File('${dir.path}/toy.gguf')..writeAsBytesSync(_toyFile());
    final n = (await memoryNeedForFile(ok.path))!;
    expect(n.fromHeader, isTrue);
    expect(n.weights, 2 * 34 * 100, reason: 'token_embd only: the per-layer table is not counted');
    expect(n.total, n.weights + n.kv + n.compute);
    final junk = File('${dir.path}/junk.gguf')..writeAsBytesSync(List.filled(64, 0));
    final f = (await memoryNeedForFile(junk.path))!;
    expect(f.fromHeader, isFalse);
    expect(f.total, modelMemoryNeed(64));
    expect(f.logLine, endsWith('fallback'));
    expect(await memoryNeedForFile('${dir.path}/missing.gguf'), isNull);
  });
}
