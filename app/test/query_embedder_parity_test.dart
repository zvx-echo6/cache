// The phone's query vectors and the places builder's stored vectors are the same vectors.
//
// packages/cache_llama/test/fixtures/bge-m3-golden.json holds, for a few texts, the vector `places_pack embed` makes and
// the int8 form it stores (made on the build host with the pinned model; places_pack/src/parity_tests.rs checks the
// builder against it). Here the phone's own PhoneQueryEmbedder (CacheEmbedder, cl_embed) embeds the same texts: each
// query vector must be the builder's vector, and score the stored form the way the core scores it (int8 times the
// scale, dotted with the query) at 1 less the int8 rounding.
//
// Needs the pinned model and the native library: CACHE_EMBED_MODELS_DIR is a folder holding bge-m3-Q8_0.gguf, and
// cache_llama.dll / libcache_llama.so must be loadable (PATH or LD_LIBRARY_PATH). Skipped without them.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cache/nav/query_embedder.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _models = Platform.environment['CACHE_EMBED_MODELS_DIR'];

List<int> _unhex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

void main() {
  test('a query embedded on the phone is the builder\'s vector of the same text', () async {
    final golden = jsonDecode(File('../packages/cache_llama/test/fixtures/bge-m3-golden.json').readAsStringSync()) as Map<String, dynamic>;
    expect(golden['model'], kQueryEmbedModelFile);
    final e = PhoneQueryEmbedder(modelsDir: () async => Directory(_models!));
    try {
      for (final item in (golden['items'] as List).cast<Map<String, dynamic>>()) {
        final text = item['text'] as String;
        final v = (await e(text))!;
        expect(v.model, golden['model'], reason: 'the id the common file records as embed_model');
        expect(v.vector, hasLength(golden['dims']));
        final built = Float32List.sublistView(Uint8List.fromList(_unhex(item['vector'] as String)));
        var same = 0.0;
        for (var i = 0; i < built.length; i++) {
          same += built[i] * v.vector[i];
        }
        expect(same, greaterThan(0.9999), reason: 'phone vs builder: $text');
        final stored = Uint8List.fromList(_unhex(item['stored'] as String));
        final scale = ByteData.sublistView(stored, 0, 4).getFloat32(0, Endian.little);
        final ints = Int8List.sublistView(stored, 4);
        var dot = 0.0, norm = 0.0;
        for (var i = 0; i < ints.length; i++) {
          dot += ints[i] * scale * v.vector[i];
          norm += v.vector[i] * v.vector[i];
        }
        expect(sqrt(norm), closeTo(1, 1e-4), reason: 'normalised, as the core expects');
        expect(dot, greaterThan(0.995), reason: 'phone query vs stored: $text');
        // ignore: avoid_print
        print('${same.toStringAsFixed(6)} ${dot.toStringAsFixed(6)}  $text');
      }
    } finally {
      await e.dispose();
    }
  }, skip: _models == null ? 'CACHE_EMBED_MODELS_DIR is not set' : false, timeout: const Timeout(Duration(minutes: 3)));
}
