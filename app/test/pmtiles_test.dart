import 'dart:io';
import 'dart:typed_data';

import 'package:cache/maps/layers/pmtiles.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a small PMTiles v3 archive for the tests (the real files come from the project's storage).
class PmWriter {
  PmWriter({this.leaf = false, this.gzipDirectories = true, this.minZoom = 0, this.maxZoom = 14});

  final bool leaf;
  final bool gzipDirectories;
  final int minZoom;
  final int maxZoom;
  final Map<int, List<int>> tiles = {};

  void add(int z, int x, int y, List<int> bytes) => tiles[zxyToTileId(z, x, y)] = bytes;

  static List<int> _varint(int v) {
    final out = <int>[];
    while (v >= 0x80) {
      out.add((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }

  /// entries: (tileId, offset, length, runLength)
  List<int> _dir(List<(int, int, int, int)> entries) {
    final out = <int>[..._varint(entries.length)];
    var last = 0;
    for (final e in entries) {
      out.addAll(_varint(e.$1 - last));
      last = e.$1;
    }
    for (final e in entries) {
      out.addAll(_varint(e.$4));
    }
    for (final e in entries) {
      out.addAll(_varint(e.$3));
    }
    for (final e in entries) {
      out.addAll(_varint(e.$2 + 1));
    }
    return gzipDirectories ? gzip.encode(out) : out;
  }

  Uint8List build() {
    final ids = tiles.keys.toList()..sort();
    final data = <int>[];
    final entries = <(int, int, int, int)>[];
    for (final id in ids) {
      entries.add((id, data.length, tiles[id]!.length, 1));
      data.addAll(tiles[id]!);
    }
    List<int> root, leafDirs = [];
    if (leaf) {
      leafDirs = _dir(entries);
      root = _dir([(ids.first, 0, leafDirs.length, 0)]);
    } else {
      root = _dir(entries);
    }
    final h = ByteData(127);
    final magic = 'PMTiles'.codeUnits;
    for (var i = 0; i < 7; i++) {
      h.setUint8(i, magic[i]);
    }
    h.setUint8(7, 3);
    h.setUint64(8, 127, Endian.little);
    h.setUint64(16, root.length, Endian.little);
    h.setUint64(40, 127 + root.length, Endian.little);
    h.setUint64(48, leafDirs.length, Endian.little);
    h.setUint64(56, 127 + root.length + leafDirs.length, Endian.little);
    h.setUint64(64, data.length, Endian.little);
    h.setUint8(97, gzipDirectories ? 2 : 1);
    h.setUint8(98, 1);
    h.setUint8(99, 1);
    h.setUint8(100, minZoom);
    h.setUint8(101, maxZoom);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...root, ...leafDirs, ...data]);
  }
}

RangeFetcher serve(Uint8List file, [List<int>? log]) => (url, offset, length) async {
      log?.add(offset);
      return file.sublist(offset, (offset + length).clamp(0, file.length));
    };

void main() {
  test('tile ids follow the Hilbert curve order the format defines', () {
    expect(zxyToTileId(0, 0, 0), 0);
    expect(zxyToTileId(1, 0, 0), 1);
    expect(zxyToTileId(1, 0, 1), 2);
    expect(zxyToTileId(1, 1, 1), 3);
    expect(zxyToTileId(1, 1, 0), 4);
    expect(zxyToTileId(2, 0, 0), 5);
    // Every tile of a zoom has its own id, and the ids of one zoom are consecutive.
    final ids = {for (var x = 0; x < 8; x++) for (var y = 0; y < 8; y++) zxyToTileId(3, x, y)};
    expect(ids.length, 64);
    expect(ids.reduce((a, b) => a < b ? a : b), 21);
    expect(ids.reduce((a, b) => a > b ? a : b), 84);
    expect(() => zxyToTileId(2, 4, 0), throwsA(isA<PmTilesFormatException>()));
  });

  for (final leaf in [false, true]) {
    for (final compressed in [true, false]) {
      test('reads tiles from an archive (leaf directories: $leaf, compressed directories: $compressed)', () async {
        final w = PmWriter(leaf: leaf, gzipDirectories: compressed);
        w.add(0, 0, 0, [1, 2, 3]);
        w.add(5, 6, 11, [9, 9]);
        w.add(5, 6, 12, [8]);
        w.add(14, 3000, 5000, List.filled(300, 7));
        final r = PmTilesReader(Uri.parse('https://example.test/a.pmtiles'), serve(w.build()));
        final h = await r.header();
        expect(h.maxZoom, 14);
        expect(h.tileType, 1);
        expect(h.contentType, 'application/x-protobuf');
        expect((await r.tile(0, 0, 0))!.bytes, [1, 2, 3]);
        expect((await r.tile(5, 6, 11))!.bytes, [9, 9]);
        expect((await r.tile(5, 6, 12))!.bytes, [8]);
        expect((await r.tile(14, 3000, 5000))!.bytes.length, 300);
        // Tiles the archive does not have: nothing, not a neighbour's tile.
        expect(await r.tile(5, 6, 13), isNull);
        expect(await r.tile(1, 0, 0), isNull);
        expect(await r.tile(14, 3000, 5001), isNull);
      });
    }
  }

  test('a tile outside the archive\'s zoom range is not asked for; directories are read once', () async {
    final w = PmWriter(minZoom: 2, maxZoom: 6)..add(3, 1, 1, [5]);
    final log = <int>[];
    final r = PmTilesReader(Uri.parse('https://example.test/a.pmtiles'), serve(w.build(), log));
    expect(await r.tile(1, 0, 0), isNull);
    expect(await r.tile(7, 0, 0), isNull);
    expect(log, [0], reason: 'only the header');
    await r.tile(3, 1, 1);
    await r.tile(3, 1, 1);
    // header, root directory, tile, tile
    expect(log.length, 4);
  });

  test('a file that is not PMTiles, or a newer version, is refused', () async {
    final r = PmTilesReader(Uri.parse('https://example.test/x'), (u, o, l) async => List.filled(200, 0));
    expect(r.tile(0, 0, 0), throwsA(isA<PmTilesFormatException>()));
    final w = PmWriter()..add(0, 0, 0, [1]);
    final bytes = w.build()..[7] = 4;
    expect(PmTilesReader(Uri.parse('https://example.test/y'), serve(bytes)).tile(0, 0, 0), throwsA(isA<PmTilesFormatException>()));
  });
}
