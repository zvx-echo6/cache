import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/gguf_header.dart';

/// The app's resident memory and swap now, from /proc/self/status (Android and Linux): "RSS 2346 MB (anon 1200 MB, file
/// 1146 MB), swap 2163 MB"; "memory unknown" where the system does not say. iOS gives its last native reading (phys_footprint
/// and resident size). For the log, to see what the model and the index work take.
MemoryReading? _lastAppleMemory;

String memoryNow() {
  try {
    if (Platform.isIOS) return _lastAppleMemory?.diagnostics ?? 'memory not read yet';
    if (!(Platform.isAndroid || Platform.isLinux)) return 'memory unknown';
    return procStatusSummary(File('/proc/self/status').readAsStringSync());
  } catch (_) {
    return 'memory unknown';
  }
}

/// The log text for a /proc/self/status [source]: RSS with its anonymous (RssAnon) and file-backed (RssFile) parts, and swap.
String procStatusSummary(String source) {
  final c = procMemoryCounters(source);
  final rss = c['VmRSS_kb'];
  if (rss == null) return 'memory unknown';
  final anon = c['RssAnon_kb'], file = c['RssFile_kb'], swap = c['VmSwap_kb'];
  final parts = [if (anon != null) 'anon ${anon ~/ 1024} MB', if (file != null) 'file ${file ~/ 1024} MB'];
  return 'RSS ${rss ~/ 1024} MB${parts.isEmpty ? '' : ' (${parts.join(', ')})'}${swap == null ? '' : ', swap ${swap ~/ 1024} MB'}';
}

/// The memory counters of /proc/self/status or /proc/meminfo [source], in the kernel's kB, keyed by name plus "_kb"; only these
/// names are taken, and a line whose value is not a number is left out.
Map<String, int> procMemoryCounters(String source) {
  const keys = {'VmRSS', 'VmSwap', 'RssAnon', 'RssFile', 'MemAvailable', 'SwapFree'};
  final values = <String, int>{};
  for (final line in source.split('\n')) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final key = line.substring(0, colon);
    if (!keys.contains(key)) continue;
    final number = int.tryParse(line.substring(colon + 1).trim().split(RegExp(r'\s+')).first);
    if (number != null) values['${key}_kb'] = number;
  }
  return values;
}

/// Fault and CPU counters of /proc/self/stat [source]. Fields after the parenthesized command start at field 3; CPU is in
/// raw ticks.
Map<String, int> procProcessCounters(String source) {
  final end = source.lastIndexOf(')');
  if (end < 0) return {};
  final fields = source.substring(end + 1).trim().split(RegExp(r'\s+'));
  final result = <String, int>{};
  for (final field in const {10: 'minor_faults', 12: 'major_faults', 14: 'user_ticks', 15: 'system_ticks'}.entries) {
    final index = field.key - 3;
    if (index >= fields.length) continue;
    final value = int.tryParse(fields[index]);
    if (value != null) result[field.value] = value;
  }
  return result;
}

/// The device's memory as the system tells it: what is free now ([avail], what apps can still get without the system killing
/// anything), the total, and the level below which the system starts killing apps ([threshold]); [low] is the system's own
/// "memory is low".
@immutable
class MemoryReading {
  const MemoryReading({
    required this.avail,
    required this.total,
    this.threshold = 0,
    this.low = false,
    this.appScoped = false,
    this.footprint,
    this.resident,
    this.compressed,
  });

  final int avail;
  final int total;
  final int threshold;
  final bool low;

  /// iOS reports room within this app's memory limit, not system-wide free RAM.
  final bool appScoped;
  final int? footprint;
  final int? resident;
  final int? compressed;

  String get diagnostics => [
    if (footprint != null) 'footprint ${footprint! >> 20} MB',
    if (resident != null) 'RSS ${resident! >> 20} MB',
    if (compressed != null) 'compressed ${compressed! >> 20} MB',
    '${appScoped ? 'app room' : 'available'} ${avail >> 20} MB',
    'device ${total >> 20} MB',
  ].join(', ');

  /// What can be used before the system starts killing apps.
  int get room => avail - threshold;

  @override
  String toString() => appScoped ? diagnostics : 'free ${avail >> 20} MB of ${total >> 20} MB (kills below ${threshold >> 20} MB${low ? ', low' : ''})';
}

/// Android's memory channel (MainActivity: ActivityManager.MemoryInfo, and onTrimMemory).
const MethodChannel kMemoryChannel = MethodChannel('co.cache/memory');

MemoryReading? _readingOf(Object? m) {
  if (m is! Map) return null;
  final avail = m['avail'], total = m['total'];
  if (avail is! int || total is! int || total <= 0) return null;
  final t = m['threshold'];
  return MemoryReading(
    avail: avail,
    total: total,
    threshold: t is int ? t : 0,
    low: m['low'] == true,
    appScoped: m['appScoped'] == true,
    footprint: m['footprint'] is int ? m['footprint'] as int : null,
    resident: m['resident'] is int ? m['resident'] as int : null,
    compressed: m['compressed'] is int ? m['compressed'] as int : null,
  );
}

/// The device's memory now: Android from the system (ActivityManager), Linux from /proc/meminfo (MemAvailable); null where it
/// cannot be read (then nothing waits for memory).
Future<MemoryReading?> readMemory() async {
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      final reading = _readingOf(await kMemoryChannel.invokeMethod<Object?>('read'));
      if (Platform.isIOS) _lastAppleMemory = reading;
      return reading;
    }
    if (Platform.isLinux) {
      int? kb(List<String> lines, String key) {
        for (final l in lines) {
          final m = RegExp('^$key:\\s+(\\d+)\\s+kB').firstMatch(l);
          if (m != null) return int.parse(m.group(1)!);
        }
        return null;
      }

      // read at once (a small file): no wait on file I/O
      final lines = File('/proc/meminfo').readAsLinesSync();
      final avail = kb(lines, 'MemAvailable'), total = kb(lines, 'MemTotal');
      if (avail == null || total == null) return null;
      return MemoryReading(avail: avail * 1024, total: total * 1024);
    }
  } catch (_) {}
  return null;
}

/// A fresh sample for diagnostic logs. A slow native probe never holds up indexing.
Future<String> memorySnapshot() async {
  try {
    final reading = await readMemory().timeout(const Duration(seconds: 2));
    if (reading != null && reading.appScoped) return reading.diagnostics;
  } catch (_) {}
  return memoryNow();
}

/// What a chat model of [fileBytes] takes in memory while it answers, by measurement on a phone (a 3.6 GB file: 2.2 GB once
/// loaded, 3.4 GB while answering): about two thirds of the file, plus its working memory. Size only: for a model that is not on
/// the device (nothing to read), and for the recommendation and fit lists, which stay on this estimate.
int modelMemoryNeedBySize(int fileBytes) => (fileBytes * 0.65).round() + (1 << 30);

/// The compute buffer (llama.cpp's scratch for one batch of 512 tokens) and the other allocations a context makes. A first
/// estimate, to be calibrated from the Pixel memmap logs ("compute buffer size" beside the memmap report).
const int kComputeAllowance = 256 << 20;

/// What the app itself needs on top while a model answers (the answer, the UI, the index work). The old one gigabyte of
/// [modelMemoryNeedBySize] also covered the KV cache and the compute buffer; those are counted separately now.
const int kAnswerHeadroom = 384 << 20;

/// llama.cpp's n_ubatch for the chat context (cache_llama.cpp sets n_batch 512; n_ubatch keeps its default of 512 and is capped
/// by n_batch).
const int kChatUbatch = 512;

/// The tensor-aware memory a model needs while it answers, in bytes, by part.
@immutable
class MemoryNeed {
  const MemoryNeed({required this.core, required this.outputEmbd, required this.lookup, required this.kv, required this.compute, required this.headroom, required this.fromHeader, int? total})
    : _total = total;

  /// Every tensor read in full each token: attention, FFN, per-layer projections, norms.
  final int core;

  /// token_embd when it is also the output head (read in full every token), and output.weight.
  final int outputEmbd;

  /// The lookup-only tables (per_layer_token_embd; token_embd when a separate output.weight exists): only the rows of the
  /// tokens in the context (n_ctx at most) count, the rest stays on flash.
  final int lookup;
  final int kv;
  final int compute;
  final int headroom;

  /// True when this came from the file's header; false for the size-based fallback (then only the total is known).
  final bool fromHeader;
  final int? _total;

  int get total => _total ?? core + outputEmbd + lookup + kv + compute + headroom;

  /// The load log line.
  String get logLine => fromHeader
      ? 'Memory need: ${total >> 20} MB (core ${core >> 20} MB, output/embd ${outputEmbd >> 20} MB, lookup ${lookup >> 20} MB, '
            'kv ${kv >> 20} MB, compute ${compute >> 20} MB, headroom ${headroom >> 20} MB) from header'
      : 'Memory need: ${total >> 20} MB (size-based: 0.65 x file + 1024 MB) fallback';
}

/// The memory a chat model needs while it answers with a context of [nCtx] tokens, from its GGUF [h]:
///   core + output/embd: every tensor but the lookup-only ones, in full (resident while answering);
///   lookup: for each lookup-only tensor (per_layer_token_embd; token_embd only when an output.weight exists, as otherwise it is
///           the tied output head, read in full every token), one row per token of the context: row bytes x min(nCtx, rows);
///   kv: the KV cache in q8_0 for the layers that own KV (see [_kvBytes]);
///   compute + headroom: [kComputeAllowance] and [kAnswerHeadroom].
MemoryNeed memoryNeedFromHeader(GgufHeader h, {required int nCtx}) {
  final hasOutput = h.tensor('output.weight') != null;
  var core = 0, outputEmbd = 0, lookup = 0;
  for (final t in h.tensors) {
    final isPle = t.name.startsWith('per_layer_token_embd');
    final isTok = t.name.startsWith('token_embd');
    if (isPle || (isTok && hasOutput)) {
      lookup += t.rowBytes * (nCtx < t.rows ? nCtx : t.rows);
    } else if (isTok || t.name.startsWith('output.weight')) {
      outputEmbd += t.bytes;
    } else {
      core += t.bytes;
    }
  }
  return MemoryNeed(
    core: core,
    outputEmbd: outputEmbd,
    lookup: lookup,
    kv: _kvBytes(h, nCtx),
    compute: kComputeAllowance,
    headroom: kAnswerHeadroom,
    fromHeader: true,
  );
}

/// The total of [memoryNeedFromHeader].
int modelMemoryNeedFromHeader(GgufHeader h, {required int nCtx}) => memoryNeedFromHeader(h, nCtx: nCtx).total;

int _pad256(int n) => (n + 255) ~/ 256 * 256;

/// The q8_0 K and V cache llama.cpp allocates (type_k = type_v = q8_0, 34 bytes per 32 elements), per layer that owns KV
/// (block_count minus attention.shared_kv_layers, the first layers), by the cells of its kind:
///   global layer: n_ctx rounded up to 256 (llama-context.cpp:377 GGML_PAD(n_ctx, 256); n_ctx_seq = n_ctx for one sequence, :380-383;
///     size_base = kv_size, llama-kv-cache-iswa.cpp:60);
///   sliding layer: GGML_PAD(min(size_base, n_swa + n_ubatch), 256) for one sequence (llama-kv-cache-iswa.cpp:73);
/// (line numbers of the pinned llama.cpp 620d2225). Bytes per cell: head_count_kv x (key_length + value_length) elements, with the
/// _swa lengths for sliding layers. A model without a sliding window (no sliding_window key) counts every layer as global.
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
  final swaCells = nSwa == null ? base : _pad256(nSwa + kChatUbatch < base ? nSwa + kChatUbatch : base);
  var total = 0;
  for (var il = 0; il < owners; il++) {
    final sliding = nSwa != null && pattern is List && il < pattern.length && pattern[il] == true;
    final kv = perLayer('$arch.attention.head_count_kv', il, heads);
    final kl = h.intOf('$arch.attention.key_length') ?? headDim;
    final vl = h.intOf('$arch.attention.value_length') ?? kl;
    final k = sliding ? (h.intOf('$arch.attention.key_length_swa') ?? kl) : kl;
    final v = sliding ? (h.intOf('$arch.attention.value_length_swa') ?? vl) : vl;
    final elements = kv * (k + v) * (sliding ? swaCells : base);
    total += (elements * 34 + 31) ~/ 32;
  }
  return total;
}

/// The memory the model file at [path] needs while it answers with [nCtx] tokens of context, from the tensors in its header; when
/// the header cannot be read, the size-based [modelMemoryNeedBySize] of [fallbackBytes] (or the file's length), and the result says
/// so ([MemoryNeed.fromHeader] false). Null when neither the header nor a size can be had.
Future<MemoryNeed?> memoryNeedForFile(String path, {int nCtx = 8192, int? fallbackBytes}) async {
  try {
    final h = readGgufHeader(path);
    if (h != null) return memoryNeedFromHeader(h, nCtx: nCtx);
  } catch (_) {}
  try {
    final size = fallbackBytes ?? await File(path).length();
    return MemoryNeed(core: 0, outputEmbd: 0, lookup: 0, kv: 0, compute: 0, headroom: 0, fromHeader: false, total: modelMemoryNeedBySize(size));
  } catch (_) {
    return null;
  }
}

/// [memoryNeedForFile]'s total in bytes; the size-based estimate when the header cannot be read.
Future<int> modelMemoryNeedForFile(String path, {int nCtx = 8192, int? fallbackBytes}) async =>
    (await memoryNeedForFile(path, nCtx: nCtx, fallbackBytes: fallbackBytes))?.total ?? modelMemoryNeedBySize(fallbackBytes ?? 0);

/// Android's onTrimMemory levels the app acts on.
const int kTrimRunningLow = 10;
const int kTrimUiHidden = 20;

/// Android says memory is short: [level] (onTrimMemory's) and the memory then.
typedef MemoryTrim = void Function(int level, MemoryReading? reading);

/// Calls [onTrim] each time Android sends onTrimMemory (Android only; elsewhere never).
void listenMemoryTrim(MemoryTrim onTrim) {
  kMemoryChannel.setMethodCallHandler((call) async {
    if (call.method != 'trim') return null;
    final m = call.arguments;
    final level = m is Map && m['level'] is int ? m['level'] as int : 0;
    onTrim(level, _readingOf(m));
    return null;
  });
}

/// Whether the model should be let go on this onTrimMemory: Android says memory runs low while Cache is in front (older
/// Androids), or Cache went to the back and what is free is under a gigabyte above where Android starts killing apps.
bool releaseModelOn(int level, MemoryReading? r) {
  if (level >= kTrimRunningLow && level < kTrimUiHidden) return true;
  if (level >= kTrimUiHidden) return r != null && (r.low || r.room < (1 << 30));
  return false;
}
