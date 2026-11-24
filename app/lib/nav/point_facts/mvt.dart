import 'dart:convert' show utf8;
import 'dart:typed_data';

/// One polygon feature of a Mapbox Vector Tile: its attributes and its rings, in tile units (0 to [MvtLayer.extent], y down).
class MvtPolygon {
  MvtPolygon(this.properties, this.rings);

  final Map<String, Object> properties;

  /// Every ring of the feature, outer rings and holes alike, as x, y pairs.
  final List<List<(int, int)>> rings;

  /// Whether (x, y) is inside the polygon: a point inside an odd number of its rings (even-odd rule), so a ring that is a hole
  /// takes the area back out, whichever way the ring runs.
  bool contains(double x, double y) {
    var inside = false;
    for (final ring in rings) {
      if (_ringContains(ring, x, y)) inside = !inside;
    }
    return inside;
  }
}

bool _ringContains(List<(int, int)> ring, double x, double y) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final (xi, yi) = ring[i];
    final (xj, yj) = ring[j];
    if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

class MvtLayer {
  MvtLayer(this.name, this.extent, this.polygons);

  final String name;
  final int extent;
  final List<MvtPolygon> polygons;
}

/// Reads the polygon features of a Mapbox Vector Tile (the protobuf of the vector tile specification, version 2). Lines and points are
/// skipped: the caller asks only what area a point is in. Throws [FormatException] for bytes that are not a tile.
List<MvtLayer> readMvtPolygons(Uint8List bytes) {
  final out = <MvtLayer>[];
  final r = _Reader(bytes, 0, bytes.length);
  while (!r.done) {
    final tag = r.varint();
    final field = tag ~/ 8, wire = tag % 8;
    if (field == 3 && wire == 2) {
      final len = r.varint();
      out.add(_readLayer(Uint8List.sublistView(bytes, r.pos, r.pos + len)));
      r.pos += len;
    } else {
      r.skip(wire);
    }
  }
  return out;
}

MvtLayer _readLayer(Uint8List b) {
  final r = _Reader(b, 0, b.length);
  var name = '';
  var extent = 4096;
  final keys = <String>[];
  final values = <Object>[];
  final features = <Uint8List>[];
  while (!r.done) {
    final tag = r.varint();
    final field = tag ~/ 8, wire = tag % 8;
    if (wire == 2) {
      final len = r.varint();
      final slice = Uint8List.sublistView(b, r.pos, r.pos + len);
      r.pos += len;
      switch (field) {
        case 1:
          name = _utf8(slice);
        case 2:
          features.add(slice);
        case 3:
          keys.add(_utf8(slice));
        case 4:
          values.add(_readValue(slice));
      }
    } else if (field == 5 && wire == 0) {
      extent = r.varint();
    } else {
      r.skip(wire);
    }
  }
  final polygons = <MvtPolygon>[];
  for (final f in features) {
    final p = _readFeature(f, keys, values);
    if (p != null) polygons.add(p);
  }
  return MvtLayer(name, extent, polygons);
}

String _utf8(Uint8List b) => utf8.decode(b, allowMalformed: true);

Object _readValue(Uint8List b) {
  final r = _Reader(b, 0, b.length);
  Object v = '';
  while (!r.done) {
    final tag = r.varint();
    final field = tag ~/ 8, wire = tag % 8;
    switch (field) {
      case 1 when wire == 2:
        final len = r.varint();
        v = _utf8(Uint8List.sublistView(b, r.pos, r.pos + len));
        r.pos += len;
      case 2 when wire == 5:
        v = ByteData.sublistView(b, r.pos, r.pos + 4).getFloat32(0, Endian.little);
        r.pos += 4;
      case 3 when wire == 1:
        v = ByteData.sublistView(b, r.pos, r.pos + 8).getFloat64(0, Endian.little);
        r.pos += 8;
      case 4 || 5 when wire == 0:
        v = r.varint();
      case 6 when wire == 0:
        final n = r.varint();
        v = n.isEven ? n ~/ 2 : -((n + 1) ~/ 2);
      case 7 when wire == 0:
        v = r.varint() != 0;
      default:
        r.skip(wire);
    }
  }
  return v;
}

MvtPolygon? _readFeature(Uint8List b, List<String> keys, List<Object> values) {
  final r = _Reader(b, 0, b.length);
  var type = 0;
  List<int> tags = const [];
  List<int> geometry = const [];
  while (!r.done) {
    final tag = r.varint();
    final field = tag ~/ 8, wire = tag % 8;
    if (field == 2 && wire == 2) {
      tags = r.packed();
    } else if (field == 3 && wire == 0) {
      type = r.varint();
    } else if (field == 4 && wire == 2) {
      geometry = r.packed();
    } else {
      r.skip(wire);
    }
  }
  if (type != 3) return null;
  final props = <String, Object>{};
  for (var i = 0; i + 1 < tags.length; i += 2) {
    if (tags[i] < keys.length && tags[i + 1] < values.length) props[keys[tags[i]]] = values[tags[i + 1]];
  }
  return MvtPolygon(props, _rings(geometry));
}

/// The command stream of a polygon geometry: MoveTo (1) starts a ring, LineTo (2) adds corners, ClosePath (7) ends it.
List<List<(int, int)>> _rings(List<int> g) {
  final rings = <List<(int, int)>>[];
  List<(int, int)>? ring;
  var x = 0, y = 0;
  var i = 0;
  int zig(int n) => n.isEven ? n ~/ 2 : -((n + 1) ~/ 2);
  while (i < g.length) {
    final cmd = g[i] % 8, count = g[i] ~/ 8;
    i++;
    if (cmd == 7) {
      if (ring != null && ring.length >= 3) rings.add(ring);
      ring = null;
      continue;
    }
    for (var k = 0; k < count && i + 1 < g.length; k++) {
      x += zig(g[i]);
      y += zig(g[i + 1]);
      i += 2;
      if (cmd == 1) {
        if (ring != null && ring.length >= 3) rings.add(ring);
        ring = [];
      }
      ring?.add((x, y));
    }
  }
  if (ring != null && ring.length >= 3) rings.add(ring);
  return rings;
}

class _Reader {
  _Reader(this.b, this.pos, this.end);

  final Uint8List b;
  int pos;
  final int end;

  bool get done => pos >= end;

  /// A base-128 varint. Built by multiplying, not shifting, so it is right in a browser (where shifts are 32-bit) too.
  int varint() {
    var result = 0;
    var mul = 1;
    while (true) {
      if (pos >= end) throw const FormatException('Vector tile ends in the middle of a number');
      final byte = b[pos++];
      result += (byte & 0x7F) * mul;
      if (byte < 0x80) return result;
      mul *= 128;
      if (mul > 1 << 60) throw const FormatException('Vector tile number too long');
    }
  }

  List<int> packed() {
    final len = varint();
    final stop = pos + len;
    if (stop > end) throw const FormatException('Vector tile field runs past its end');
    final out = <int>[];
    while (pos < stop) {
      out.add(varint());
    }
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        pos += 8;
      case 2:
        pos += varint();
      case 5:
        pos += 4;
      default:
        throw FormatException('Vector tile has an unknown field type $wire');
    }
    if (pos > end) throw const FormatException('Vector tile field runs past its end');
  }
}
