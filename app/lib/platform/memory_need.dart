import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../models/gguf_header.dart';
import 'memory.dart' show modelMemoryNeed;

/// llama.cpp's compute buffer for the chat context: 560 MiB reserved, the same with flash attention on or off (measured on the
/// Pixel 8; see the memory research record). It is the worst case for the output logits (262,144-token vocabulary x 512-token
/// ubatch x 4 bytes, about 512 MiB) plus the scratch for one batch.
const int kChatComputeReserve = 560 << 20;

/// What the chat context holds at 8192 tokens, per part, for the load check ([memoryNeedFromHeader]).
@immutable
class MemoryNeed {
  const MemoryNeed({required this.weights, required this.kv, required this.compute, required this.fromHeader, this.sizeTotal});

  /// The weights resident once loaded: every tensor of the file except the lazily read per-layer table.
  final int weights;

  /// The K and V cache at f16.
  final int kv;
  final int compute;

  /// True when this came from the file's header; false for the size-based fallback (then only [sizeTotal] is known).
  final bool fromHeader;
  final int? sizeTotal;

  int get total => sizeTotal ?? weights + kv + compute;

  /// The log line for a load.
  String get logLine => fromHeader
      ? 'Memory need: ${total >> 20} MB (weights ${weights >> 20} MB, kv ${kv >> 20} MB, compute ${compute >> 20} MB) from header'
      : 'Memory need: ${total >> 20} MB (size-based: 0.65 x file + 1024 MB) fallback';
}

/// What a chat model needs in memory while it answers with [nCtx] tokens of context, from its GGUF [h], with the chat model loaded
/// at lazy_mode ON (cache_llama.cpp sets LLAMA_LAZY_MODE_ON):
///
///   need = weights + kv + compute
///   weights: the bytes of every tensor in the header except those named per_layer_token_embd*. With lazy mode on, Gemma 4's
///            per-layer table (1.8 GB in the E2B files) is not resident at load; its rows are read per batch from flash.
///            token_embd and output.weight count in full (token_embd is the tied output head, read each token); so does
///            per_layer_model_proj.
///   kv:      the K and V cache at f16 (2 bytes per element; Cache sets no cache type), for the layers that own KV (block_count
///            minus attention.shared_kv_layers, the first layers). A global layer has n_ctx rounded up to 256 cells; a sliding layer
///            min(n_ctx, sliding_window + 512 ubatch) rounded up to 256. Cells cost head_count_kv x (key_length + value_length)
///            elements (the _swa lengths for sliding layers). A model with no sliding_window key counts every layer as global.
///   compute: [kChatComputeReserve], 560 MiB.
MemoryNeed memoryNeedFromHeader(GgufHeader h, {required int nCtx}) {
  var weights = 0;
  for (final t in h.tensors) {
    if (t.name.startsWith('per_layer_token_embd')) continue;
    weights += t.bytes;
  }
  return MemoryNeed(weights: weights, kv: _kvBytes(h, nCtx), compute: kChatComputeReserve, fromHeader: true);
}

int _pad256(int n) => (n + 255) ~/ 256 * 256;

int _kvBytes(GgufHeader h, int nCtx) {
  final arch = h.metadata['general.architecture'];
  if (arch is! String) return 0;
  final nLayer = h.intOf('$arch.block_count');
  if (nLayer == null) return 0;
  final shared = h.intOf('$arch.attention.shared_kv_layers') ?? 0;
  final owners = nLayer - shared;
  final nSwa = h.intOf('$arch.attention.sliding_window');
  final pattern = h.metadata['$arch.attention.sliding_window_pattern'];
  final embd = h.intOf('$arch.embedding_length') ?? 0;
  final heads = h.intOf('$arch.attention.head_count') ?? 1;
  int perLayer(String key, int il, int fallback) {
    final v = h.metadata[key];
    if (v is int) return v;
    if (v is List && il < v.length && v[il] is int) return v[il] as int;
    return fallback;
  }

  final headDim = heads > 0 ? embd ~/ heads : 0;
  final base = _pad256(nCtx);
  const ubatch = 512;
  final swaCells = nSwa == null ? base : _pad256(nSwa + ubatch < base ? nSwa + ubatch : base);
  var total = 0;
  for (var il = 0; il < owners; il++) {
    final sliding = nSwa != null && pattern is List && il < pattern.length && pattern[il] == true;
    final kv = perLayer('$arch.attention.head_count_kv', il, heads);
    final kl = h.intOf('$arch.attention.key_length') ?? headDim;
    final vl = h.intOf('$arch.attention.value_length') ?? kl;
    final k = sliding ? (h.intOf('$arch.attention.key_length_swa') ?? kl) : kl;
    final v = sliding ? (h.intOf('$arch.attention.value_length_swa') ?? vl) : vl;
    total += kv * (k + v) * (sliding ? swaCells : base) * 2;
  }
  return total;
}

/// The memory the model file at [path] needs while it answers with [nCtx] tokens, from the tensors in its header; when the header
/// cannot be read, the size-based [modelMemoryNeed] of [fallbackBytes] (or the file's length), and the result says so
/// ([MemoryNeed.fromHeader] false). Null when neither the header nor a size can be had.
Future<MemoryNeed?> memoryNeedForFile(String path, {int nCtx = 8192, int? fallbackBytes}) async {
  try {
    // The header read (about 16 MB and a long skip) runs off the UI isolate: on a phone it took 64 to 128 ms, a few dropped frames.
    final need = await memoryNeedRunner(() => _needFromHeaderFile(path, nCtx));
    if (need != null) return need;
  } catch (_) {}
  try {
    final size = fallbackBytes ?? await File(path).length();
    return MemoryNeed(weights: 0, kv: 0, compute: 0, fromHeader: false, sizeTotal: modelMemoryNeed(size));
  } catch (_) {
    return null;
  }
}

/// Runs the header read off the UI isolate ([Isolate.run]); a test hook: a test counts the calls or checks where it runs.
@visibleForTesting
Future<R> Function<R>(FutureOr<R> Function() computation) memoryNeedRunner = Isolate.run;

/// The need from the header of the file at [path], or null when it is not a readable GGUF (the caller falls back to the size).
MemoryNeed? _needFromHeaderFile(String path, int nCtx) {
  final h = readGgufHeader(path);
  return h == null ? null : memoryNeedFromHeader(h, nCtx: nCtx);
}
