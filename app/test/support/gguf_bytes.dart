// Tiny synthetic GGUF headers for tests: magic, version, counts and metadata pairs (no tensors, no data).

import 'dart:convert';
import 'dart:typed_data';

List<int> _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
List<int> _u64(int v) => (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();
List<int> ggufString(String s) {
  final b = utf8.encode(s);
  return [..._u64(b.length), ...b];
}

/// A string pair (type 8).
List<int> kvString(String key, String value) => [...ggufString(key), ..._u32(8), ...ggufString(value)];

/// A u32 pair (type 4).
List<int> kvU32(String key, int value) => [...ggufString(key), ..._u32(4), ..._u32(value)];

/// A header with [pairs] already encoded; [kvCount] says how many the header claims (the pairs' count when null).
List<int> ggufBytes(List<List<int>> pairs, {int version = 3, int? kvCount, int tensorCount = 0, List<int> magic = const [0x47, 0x47, 0x55, 0x46]}) => [
      ...magic,
      ..._u32(version),
      ..._u64(tensorCount),
      ..._u64(kvCount ?? pairs.length),
      for (final p in pairs) ...p,
    ];
