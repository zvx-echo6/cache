import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One tensor of a GGUF file as its header lists it (no data): name, dimensions (ne[0] first, as stored) and ggml type.
class GgufTensor {
  const GgufTensor(this.name, this.dims, this.type);

  final String name;
  final List<int> dims;

  /// The ggml type number (0 F32, 1 F16, 2 Q4_0, 8 Q8_0, 12 Q4_K, 14 Q6_K ...).
  final int type;

  int get elements => dims.fold(1, (a, b) => a * b);

  /// Bytes of one row (ne[0] elements); rows are the unit a lookup (GET_ROWS) reads.
  int get rowBytes {
    final t = ggmlTypeSize(type);
    return (dims.first ~/ t.block) * t.bytes;
  }

  /// Bytes of the whole tensor in the file.
  int get bytes => dims.length <= 1 ? rowBytes : rowBytes * (elements ~/ dims.first);

  /// Rows: all dimensions after ne[0] (for the embedding tables, the vocabulary).
  int get rows => elements ~/ dims.first;
}

/// A metadata array too long to keep (the tokenizer's tokens, scores): only its length.
class GgufBigArray {
  const GgufBigArray(this.length);
  final int length;
}

/// The header of a GGUF file: version, metadata and the tensor list.
class GgufHeader {
  const GgufHeader(this.version, this.metadata, this.tensors);

  final int version;
  final Map<String, Object?> metadata;
  final List<GgufTensor> tensors;

  int? intOf(String key) {
    final v = metadata[key];
    return v is int ? v : null;
  }

  /// The tensor named [name], or null.
  GgufTensor? tensor(String name) {
    for (final t in tensors) {
      if (t.name == name) return t;
    }
    return null;
  }
}

/// (elements per block, bytes per block) of a ggml type; throws [FormatException] for a type this reader does not know (its size
/// would be a guess).
({int block, int bytes}) ggmlTypeSize(int type) {
  const sizes = <int, (int, int)>{
    0: (1, 4), // F32
    1: (1, 2), // F16
    2: (32, 18), // Q4_0
    3: (32, 20), // Q4_1
    6: (32, 22), // Q5_0
    7: (32, 24), // Q5_1
    8: (32, 34), // Q8_0
    9: (32, 36), // Q8_1
    10: (256, 84), // Q2_K
    11: (256, 110), // Q3_K
    12: (256, 144), // Q4_K
    13: (256, 176), // Q5_K
    14: (256, 210), // Q6_K
    15: (256, 292), // Q8_K
    16: (256, 66), // IQ2_XXS
    17: (256, 74), // IQ2_XS
    18: (256, 98), // IQ3_XXS
    19: (256, 50), // IQ1_S
    20: (32, 18), // IQ4_NL
    21: (256, 110), // IQ3_S
    22: (256, 82), // IQ2_S
    23: (256, 136), // IQ4_XS
    24: (1, 1), // I8
    25: (1, 2), // I16
    26: (1, 4), // I32
    27: (1, 8), // I64
    28: (1, 8), // F64
    29: (256, 56), // IQ1_M
    30: (1, 2), // BF16
    34: (256, 54), // TQ1_0
    35: (256, 66), // TQ2_0
    39: (32, 17), // MXFP4
  };
  final s = sizes[type];
  if (s == null) throw FormatException('unknown ggml type $type');
  return (block: s.$1, bytes: s.$2);
}

/// Reads the header of the GGUF file at [path] (magic, version 3, metadata, tensor infos) and nothing after it: the file is read
/// in [chunk]-byte pieces, so a 3.4 GB model costs its ~16 MB header. Metadata arrays longer than 4096 entries are skipped (kept as
/// [GgufBigArray]). Returns null when the file is not a readable GGUF version 3 (the caller falls back).
GgufHeader? readGgufHeader(String path, {int chunk = 1 << 20}) {
  RandomAccessFile? f;
  try {
    f = File(path).openSync();
    return _GgufReader(f, chunk).header();
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  } on RangeError {
    return null;
  } finally {
    f?.closeSync();
  }
}

class _GgufReader {
  _GgufReader(this._f, this._chunk) : _buf = Uint8List(0);

  final RandomAccessFile _f;
  final int _chunk;
  Uint8List _buf;
  int _bufStart = 0; // file offset of _buf[0]
  int _pos = 0; // file offset of the next byte

  static const _maxRead = 16 << 20;
  static const _fixed = <int, int>{0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8};

  /// [n] bytes at the read position, refilled from the file in chunks.
  ByteData _take(int n) {
    // One read is at most 16 MiB (the largest real string or tensor name is a few KB); a bigger length is a damaged header.
    if (n < 0 || n > _maxRead) throw const FormatException('implausible length');
    final end = _pos + n;
    if (_pos < _bufStart || end > _bufStart + _buf.length) {
      _f.setPositionSync(_pos);
      final want = n > _chunk ? n : _chunk;
      _buf = _f.readSync(want);
      _bufStart = _pos;
      if (_buf.length < n) throw const FormatException('file ends inside the header');
    }
    final view = ByteData.sublistView(_buf, _pos - _bufStart, _pos - _bufStart + n);
    _pos = end;
    return view;
  }

  int _u32() => _take(4).getUint32(0, Endian.little);
  int _u64() {
    final v = _take(8).getUint64(0, Endian.little);
    if (v < 0) throw const FormatException('length out of range');
    return v;
  }

  String _string() {
    final n = _u64();
    final b = _take(n);
    return utf8.decode(b.buffer.asUint8List(b.offsetInBytes, n), allowMalformed: true);
  }

  Object? _scalar(int type) {
    switch (type) {
      case 0:
        return _take(1).getUint8(0);
      case 1:
        return _take(1).getInt8(0);
      case 2:
        return _take(2).getUint16(0, Endian.little);
      case 3:
        return _take(2).getInt16(0, Endian.little);
      case 4:
        return _take(4).getUint32(0, Endian.little);
      case 5:
        return _take(4).getInt32(0, Endian.little);
      case 6:
        return _take(4).getFloat32(0, Endian.little);
      case 7:
        return _take(1).getUint8(0) != 0;
      case 8:
        return _string();
      case 10:
        return _take(8).getUint64(0, Endian.little);
      case 11:
        return _take(8).getInt64(0, Endian.little);
      case 12:
        return _take(8).getFloat64(0, Endian.little);
    }
    throw FormatException('unknown metadata value type $type');
  }

  Object? _value(int type) {
    if (type != 9) return _scalar(type);
    final et = _u32();
    final n = _u64();
    if (et == 9) throw const FormatException('nested metadata arrays are not supported');
    if (n > 4096) {
      // skipped, never kept
      final size = _fixed[et];
      if (size != null) {
        _skip(size * n);
      } else if (et == 8) {
        for (var i = 0; i < n; i++) {
          _skip(_u64());
        }
      } else {
        throw FormatException('unknown metadata array type $et');
      }
      return GgufBigArray(n);
    }
    return [for (var i = 0; i < n; i++) _scalar(et)];
  }

  void _skip(int n) {
    if (n < 0) throw const FormatException('bad skip');
    _pos += n;
  }

  GgufHeader header() {
    if (_u32() != 0x46554747) throw const FormatException('not a GGUF file'); // "GGUF" little endian
    final version = _u32();
    if (version != 3) throw FormatException('GGUF version $version');
    final nTensors = _u64();
    final nKv = _u64();
    if (nTensors > 1000000 || nKv > 1000000) throw const FormatException('implausible counts');
    final meta = <String, Object?>{};
    for (var i = 0; i < nKv; i++) {
      final key = _string();
      meta[key] = _value(_u32());
    }
    final tensors = <GgufTensor>[];
    for (var i = 0; i < nTensors; i++) {
      final name = _string();
      final nd = _u32();
      if (nd < 1 || nd > 8) throw const FormatException('bad dimension count');
      final dims = [for (var d = 0; d < nd; d++) _u64()];
      final type = _u32();
      _u64(); // data offset: not needed
      ggmlTypeSize(type); // an unknown type throws now, not at use
      tensors.add(GgufTensor(name, dims, type));
    }
    return GgufHeader(version, meta, tensors);
  }
}
