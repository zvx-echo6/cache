import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// The fixed, north-up camera of the whole-route picture: the route's box fitted inside [size] less [padding], as MapLibre draws
/// it (web mercator, the world 512 logical pixels wide at zoom 0). The picture is rendered with this camera, and the position
/// dot is placed on it with [project], so the two always agree.
class OverviewCamera {
  const OverviewCamera({required this.lat, required this.lon, required this.zoom, required this.size});

  final double lat;
  final double lon;
  final double zoom;
  final Size size;

  /// The most zoomed in a whole-route picture gets (a very short route).
  static const double maxZoom = 16;

  static double _mx(double lon) => (lon + 180) / 360;
  static double _my(double lat) {
    final l = lat.clamp(-85.0511287798, 85.0511287798) * math.pi / 180;
    return (1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2;
  }

  static double _lat(double my) => math.atan(_sinh(math.pi * (1 - 2 * my))) * 180 / math.pi;
  static double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

  /// Fits the box [south], [west], [north], [east].
  factory OverviewCamera.fit({required double south, required double west, required double north, required double east, required Size size, EdgeInsets padding = const EdgeInsets.all(16)}) {
    final x0 = _mx(west), x1 = _mx(east), y0 = _my(north), y1 = _my(south);
    final w = math.max(1.0, size.width - padding.horizontal), h = math.max(1.0, size.height - padding.vertical);
    final dx = math.max(x1 - x0, 1e-9), dy = math.max(y1 - y0, 1e-9);
    final zoom = math.min(maxZoom, math.log(math.min(w / (dx * 512), h / (dy * 512))) / math.ln2);
    final scale = 512 * math.pow(2, zoom).toDouble();
    // The box's middle goes to the middle of the padded area, so the camera's centre moves by the padding's imbalance.
    final cx = (x0 + x1) / 2 - (padding.left - padding.right) / 2 / scale;
    final cy = (y0 + y1) / 2 - (padding.top - padding.bottom) / 2 / scale;
    return OverviewCamera(lat: _lat(cy), lon: cx * 360 - 180, zoom: zoom, size: size);
  }

  double get _scale => 512 * math.pow(2, zoom).toDouble();

  /// Where ([lat], [lon]) falls on the picture, in logical pixels from its top left.
  Offset project(double lat, double lon) =>
      Offset(size.width / 2 + (_mx(lon) - _mx(this.lat)) * _scale, size.height / 2 + (_my(lat) - _my(this.lat)) * _scale);

  /// Metres per logical pixel at the picture's centre.
  double get metresPerPixel => 2 * math.pi * 6378137 * math.cos(lat * math.pi / 180) / _scale;

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon, 'zoom': zoom, 'width': size.width.round(), 'height': size.height.round()};

  @override
  bool operator ==(Object other) => other is OverviewCamera && other.lat == lat && other.lon == lon && other.zoom == zoom && other.size == size;

  @override
  int get hashCode => Object.hash(lat, lon, zoom, size);
}

/// How far the position must move on a picture (logical pixels) before the dot is drawn again.
const double kOverviewRedrawPixels = 2.0;

/// How much the heading must turn (degrees) before the dot is drawn again.
const double kOverviewRedrawHeadingDeg = 10.0;

/// The dot on a picture is drawn at most this often (about twice a second).
const Duration kOverviewMinInterval = Duration(milliseconds: 500);

/// The distance rule for the position dot on the whole-route picture: it is drawn again when the position has moved about
/// [kOverviewRedrawPixels] at the picture's scale or the heading turned [kOverviewRedrawHeadingDeg], and never more often than
/// [kOverviewMinInterval]. A slow walk on a whole-route picture then moves the dot every several seconds, highway driving about
/// once a second.
class RedrawGate {
  RedrawGate({this.pixels = kOverviewRedrawPixels, this.headingDeg = kOverviewRedrawHeadingDeg, this.minInterval = kOverviewMinInterval});

  final double pixels;
  final double headingDeg;
  final Duration minInterval;

  Offset? _drawnAt;
  double? _drawnHeading;
  DateTime? _drawnTime;

  Offset? get drawnAt => _drawnAt;
  double? get drawnHeading => _drawnHeading;

  /// True when a dot at [at] with [heading] differs enough from the one drawn.
  bool differs(Offset at, double? heading) {
    final d = _drawnAt;
    if (d == null) return true;
    if ((at - d).distance >= pixels) return true;
    final h0 = _drawnHeading;
    if ((h0 == null) != (heading == null)) return true;
    if (h0 != null && heading != null) {
      final turn = ((heading - h0 + 540) % 360 - 180).abs();
      if (turn >= headingDeg) return true;
    }
    return false;
  }

  /// What to do with a new position: null (nothing, it has not moved enough), [Duration.zero] (draw now), or how long to wait
  /// before drawing (the last draw was too recent; draw the newest position then).
  Duration? decide(Offset at, double? heading, DateTime now) {
    if (!differs(at, heading)) return null;
    final last = _drawnTime;
    if (last == null) return Duration.zero;
    final since = now.difference(last);
    return since >= minInterval ? Duration.zero : minInterval - since;
  }

  /// The dot was drawn at [at] with [heading] at [now].
  void drawn(Offset at, double? heading, DateTime now) {
    _drawnAt = at;
    _drawnHeading = heading;
    _drawnTime = now;
  }

  /// A new picture (another route, size or theme): the next position is drawn at once.
  void reset() {
    _drawnAt = null;
    _drawnHeading = null;
    _drawnTime = null;
  }
}
