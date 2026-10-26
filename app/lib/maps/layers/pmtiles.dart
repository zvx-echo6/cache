import 'dart:io';
import 'dart:typed_data';

/// Reads tiles out of a PMTiles v3 archive (https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md)
/// with byte-range requests, so a planet-sized file on a plain web host serves single tiles. Used by the Dart
/// stand-in for the layer engine; the Rust engine has its own reader.

/// Fetches [length] bytes of [url] starting at [offset].
typedef RangeFetcher = Future<List<int>> Function(Uri url, int offset, int length);

Future<List<int>> httpRangeFetcher(Uri url, int offset, int length) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(url);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + length - 1}');
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final res = await req.close();
    if (res.statusCode == 404) {
      await res.drain<void>();
      throw PmTilesMissing(url);
    }
    if (res.statusCode != 206 && res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    final bytes = <int>[];
    await for (final c in res) {
      bytes.addAll(c);
    }
    // A host that ignores Range sends the whole file from byte 0.
    if (res.statusCode == 200 && bytes.length > length) return bytes.sublist(offset, offset + length);
    return bytes;
  } finally {
    client.close(force: true);
  }
}

/// The archive is not at its address (yet).
class PmTilesMissing implements Exception {
  PmTilesMissing(this.url);
  final Uri url;
  @override
  String toString() => 'No PMTiles file at $url';
}

class PmTilesFormatException implements Exception {
  PmTilesFormatException(this.message);
  final String message;
  @override
  String toString() => 'PMTiles: $message';
}

enum PmCompression { unknown, none, gzip, brotli, zstd }

class PmHeader {
  PmHeader({
    required this.rootOffset,
    required this.rootLength,
    required this.leafOffset,
    required this.tileDataOffset,
    required this.internalCompression,
    required this.tileCompression,
    required this.tileType,
    required this.minZoom,
    required this.maxZoom,
  });

  final int rootOffset;
  final int rootLength;
  final int leafOffset;
  final int tileDataOffset;
  final PmCompression internalCompression;
  final PmCompression tileCompression;

  /// 1 vector (mvt), 2 png, 3 jpeg, 4 webp, 5 avif.
  final int tileType;
  final int minZoom;
  final int maxZoom;

  String get contentType => switch (tileType) {
        1 => 'application/x-protobuf',
        2 => 'image/png',
        3 => 'image/jpeg',
        4 => 'image/webp',
        5 => 'image/avif',
        _ => 'application/octet-stream',
      };

  static const int size = 127;

  factory PmHeader.parse(List<int> bytes) {
    if (bytes.length < size || String.fromCharCodes(bytes.sublist(0, 7)) != 'PMTiles') {
      throw PmTilesFormatException('not a PMTiles file');
    }
    if (bytes[7] != 3) throw PmTilesFormatException('version ${bytes[7]} is not supported');
    final d = ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, size)));
    int u64(int at) => d.getUint64(at, Endian.little);
    PmCompression c(int v) => v >= 0 && v < PmCompression.values.length ? PmCompression.values[v] : PmCompression.unknown;
    return PmHeader(
      rootOffset: u64(8),
      rootLength: u64(16),
      leafOffset: u64(40),
      tileDataOffset: u64(56),
      internalCompression: c(bytes[97]),
      tileCompression: c(bytes[98]),
      tileType: bytes[99],
      minZoom: bytes[100],
      maxZoom: bytes[101],
    );
  }
}

class _Entry {
  _Entry(this.tileId, this.offset, this.length, this.runLength);
  final int tileId;
  final int offset;
  final int length;
  final int runLength;
}

/// A tile as stored in the archive (still compressed as [PmHeader.tileCompression] says).
class PmTile {
  PmTile(this.bytes, this.header);
  final List<int> bytes;
  final PmHeader header;
}

/// Position of a tile along the Hilbert curve, counted from the first tile of zoom 0.
int zxyToTileId(int z, int x, int y) {
  if (z > 26) throw PmTilesFormatException('zoom $z is too deep');
  var acc = 0;
  for (var t = 0; t < z; t++) {
    acc += (1 << t) * (1 << t);
  }
  final n = 1 << z;
  if (x < 0 || y < 0 || x >= n || y >= n) throw PmTilesFormatException('tile $z/$x/$y is outside the world');
  var xx = x, yy = y, d = 0;
  for (var s = n ~/ 2; s > 0; s ~/= 2) {
    final rx = (xx & s) > 0 ? 1 : 0;
    final ry = (yy & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    // Rotate the quadrant.
    if (ry == 0) {
      if (rx == 1) {
        xx = s - 1 - xx;
        yy = s - 1 - yy;
      }
      final t = xx;
      xx = yy;
      yy = t;
    }
  }
  return acc + d;
}

class PmTilesReader {
  PmTilesReader(this.url, [RangeFetcher? fetcher]) : _fetch = fetcher ?? httpRangeFetcher;

  final Uri url;
  final RangeFetcher _fetch;
  PmHeader? _header;
  final Map<int, List<_Entry>> _dirs = {};

  Future<PmHeader> header() async => _header ??= PmHeader.parse(await _fetch(url, 0, PmHeader.size));

  List<int> _decompress(List<int> data, PmCompression c) {
    switch (c) {
      case PmCompression.none:
      case PmCompression.unknown:
        return data;
      case PmCompression.gzip:
        return gzip.decode(data);
      case PmCompression.brotli:
      case PmCompression.zstd:
        throw PmTilesFormatException('${c.name} compression is not supported here');
    }
  }

  Future<List<_Entry>> _directory(PmHeader h, int offset, int length) async {
    final cached = _dirs[offset];
    if (cached != null) return cached;
    final raw = _decompress(await _fetch(url, offset, length), h.internalCompression);
    final entries = _parseDirectory(raw);
    if (_dirs.length > 64) _dirs.remove(_dirs.keys.first);
    return _dirs[offset] = entries;
  }

  static List<_Entry> _parseDirectory(List<int> data) {
    var pos = 0;
    int varint() {
      var result = 0, shift = 0;
      while (true) {
        final b = data[pos++];
        result |= (b & 0x7f) << shift;
        if (b < 0x80) return result;
        shift += 7;
      }
    }

    final n = varint();
    final ids = List<int>.filled(n, 0);
    var last = 0;
    for (var i = 0; i < n; i++) {
      last += varint();
      ids[i] = last;
    }
    final runs = [for (var i = 0; i < n; i++) varint()];
    final lengths = [for (var i = 0; i < n; i++) varint()];
    final offsets = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final v = varint();
      offsets[i] = (v == 0 && i > 0) ? offsets[i - 1] + lengths[i - 1] : v - 1;
    }
    return [for (var i = 0; i < n; i++) _Entry(ids[i], offsets[i], lengths[i], runs[i])];
  }

  /// The tile at z/x/y, or null when the archive has none there (or the zoom is outside its range).
  Future<PmTile?> tile(int z, int x, int y) async {
    final h = await header();
    if (z < h.minZoom || z > h.maxZoom) return null;
    final id = zxyToTileId(z, x, y);
    var offset = h.rootOffset, length = h.rootLength;
    for (var depth = 0; depth < 4; depth++) {
      final dir = await _directory(h, offset, length);
      // The last entry whose id is not after the one wanted.
      var lo = 0, hi = dir.length - 1, found = -1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        if (dir[mid].tileId <= id) {
          found = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      if (found < 0) return null;
      final e = dir[found];
      if (e.runLength > 0) {
        if (id >= e.tileId + e.runLength) return null;
        return PmTile(await _fetch(url, h.tileDataOffset + e.offset, e.length), h);
      }
      // A pointer to a leaf directory.
      offset = h.leafOffset + e.offset;
      length = e.length;
    }
    throw PmTilesFormatException('directories nest too deep');
  }
}
