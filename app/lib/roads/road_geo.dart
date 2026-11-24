import 'dart:math' as math;

/// A point on the earth, in degrees.
class LL {
  const LL(this.lat, this.lon);

  final double lat;
  final double lon;

  @override
  bool operator ==(Object other) => other is LL && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);

  @override
  String toString() => 'LL($lat, $lon)';
}

/// Decodes a Google encoded polyline (precision 5), the format of the 511 `EncodedPolyline` and `DetourPolyline` fields. Returns an
/// empty list for empty text and for text that does not decode (a polyline that is not one is dropped, the event keeps its point).
List<LL> decodePolyline(String? text) {
  if (text == null || text.isEmpty) return const [];
  final out = <LL>[];
  var i = 0, lat = 0, lon = 0;
  int? next() {
    var result = 0, shift = 0;
    while (true) {
      if (i >= text.length) return null;
      final b = text.codeUnitAt(i++) - 63;
      if (b < 0 || b > 63) return null;
      result |= (b & 0x1f) << shift;
      shift += 5;
      if (b < 0x20) break;
      if (shift > 35) return null;
    }
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (i < text.length) {
    final dlat = next();
    final dlon = next();
    if (dlat == null || dlon == null) return const [];
    lat += dlat;
    lon += dlon;
    final p = LL(lat / 1e5, lon / 1e5);
    if (p.lat.abs() > 90 || p.lon.abs() > 180) return const [];
    out.add(p);
  }
  return out;
}

const double _earthM = 6371008.8;

double _rad(double d) => d * math.pi / 180;

/// Metres between two points (haversine).
double distanceM(LL a, LL b) {
  final dLat = _rad(b.lat - a.lat), dLon = _rad(b.lon - a.lon);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthM * math.asin(math.min(1, math.sqrt(h)));
}

/// Length of a line, in metres.
double lengthM(List<LL> line) {
  var s = 0.0;
  for (var i = 1; i < line.length; i++) {
    s += distanceM(line[i - 1], line[i]);
  }
  return s;
}

/// Metres from [p] to the segment [a]-[b], in a flat projection around [p] (exact enough for the tens of metres the road rules use).
double pointToSegmentM(LL p, LL a, LL b) {
  final k = math.cos(_rad(p.lat));
  double x(LL q) => _rad(q.lon - p.lon) * k * _earthM;
  double y(LL q) => _rad(q.lat - p.lat) * _earthM;
  final ax = x(a), ay = y(a), bx = x(b), by = y(b);
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  final t = len2 == 0 ? 0.0 : ((-ax) * dx + (-ay) * dy) / len2;
  final c = t.clamp(0.0, 1.0);
  final px = ax + c * dx, py = ay + c * dy;
  return math.sqrt(px * px + py * py);
}

/// Metres from [p] to a line (a point is a line of one point).
double pointToLineM(LL p, List<LL> line) {
  if (line.isEmpty) return double.infinity;
  if (line.length == 1) return distanceM(p, line.first);
  var best = double.infinity;
  for (var i = 1; i < line.length; i++) {
    final d = pointToSegmentM(p, line[i - 1], line[i]);
    if (d < best) best = d;
  }
  return best;
}

/// Points along [line] every [stepM] metres, the ends included (one point for a point).
List<LL> sampleLine(List<LL> line, double stepM) {
  if (line.length <= 1) return line;
  final out = <LL>[line.first];
  var carry = 0.0;
  for (var i = 1; i < line.length; i++) {
    final a = line[i - 1], b = line[i];
    final seg = distanceM(a, b);
    var at = stepM - carry;
    while (at < seg) {
      final t = at / seg;
      out.add(LL(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t));
      at += stepM;
    }
    carry = seg - (at - stepM);
    if (carry >= stepM) carry = 0;
  }
  out.add(line.last);
  return out;
}

/// The part of [a] (0 to 1) that lies within [bufferM] of [b]: how much of [a] is covered by a strip of that half-width around [b].
/// Measured at points every [stepM] metres along [a].
double coverage(List<LL> a, List<LL> b, {required double bufferM, double stepM = 10}) {
  if (a.isEmpty || b.isEmpty) return 0;
  final pts = sampleLine(a, stepM);
  var inside = 0;
  for (final p in pts) {
    if (pointToLineM(p, b) <= bufferM) inside++;
  }
  return inside / pts.length;
}

/// The middle of a line, along its length.
LL middleOf(List<LL> line) {
  if (line.length == 1) return line.first;
  final half = lengthM(line) / 2;
  var run = 0.0;
  for (var i = 1; i < line.length; i++) {
    final seg = distanceM(line[i - 1], line[i]);
    if (run + seg >= half && seg > 0) {
      final t = (half - run) / seg;
      return LL(line[i - 1].lat + (line[i].lat - line[i - 1].lat) * t, line[i - 1].lon + (line[i].lon - line[i - 1].lon) * t);
    }
    run += seg;
  }
  return line.last;
}
