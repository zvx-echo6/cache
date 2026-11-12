import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The vehicle's arrow: the main map's position marker once a heading is known. It is the car's arrow
/// (CarOverlayPainter.arrowBitmap and drawArrow in android/app/src/main/kotlin/com/happylittlellc/cache/car/CarOverlayPainter.kt),
/// so the phone's map and the car's show the same shape. A notched arrowhead [width] wide and [height] from its tip to its two
/// tails, outline included, at density 1 (points); the position is the point [ahead] behind the tip, on the middle line, which is
/// the middle of the picture and what the map turns it about. Filled with the theme's position colour, outlined with its position
/// ring. The numbers below are the Kotlin file's, and a test (test/vehicle_arrow_test.dart) reads that file and fails if they part.
class VehicleArrow {
  static const double width = 30;
  static const double height = 34;
  static const double ahead = 19;
  static const double outline = 3;

  /// How deep the notch at the back is cut, from the tails towards the tip.
  static const double notch = 8.5;

  /// Empty pixels around the arrow in its picture.
  static const int bitmapPad = 2;

  /// How far the arrow reaches from the position sideways, and downwards when it points up.
  static const double side = width / 2;
  static const double below = height - ahead;

  /// How far any of it reaches from the position, in points, whichever way it is turned: the farthest of its tip and its tails.
  static final double reach = math.max(ahead, math.sqrt(side * side + below * below));

  /// The arrowhead pointing up, its position at [c], at density [d]. The outline is drawn on the shape's edge, so the shape's own
  /// corners sit half an outline inside the sizes above.
  static ui.Path path(ui.Offset c, double d) {
    const o = outline / 2;
    final tipY = c.dy - (ahead - o) * d;
    final tailY = c.dy + (below - o) * d;
    final wing = (side - o) * d;
    return ui.Path()
      ..moveTo(c.dx, tipY)
      ..lineTo(c.dx + wing, tailY)
      ..lineTo(c.dx, tailY - notch * d)
      ..lineTo(c.dx - wing, tailY)
      ..close();
  }

  /// Draws the arrow pointing up at [c]. Turn the canvas about [c] first for a heading.
  static void paint(ui.Canvas canvas, ui.Offset c, ui.Color fill, ui.Color ring, double d) {
    final p = path(c, d);
    canvas.drawPath(p, ui.Paint()..color = fill);
    canvas.drawPath(
        p,
        ui.Paint()
          ..color = ring
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = outline * d
          ..strokeCap = ui.StrokeCap.round
          ..strokeJoin = ui.StrokeJoin.round);
  }

  /// Draws the arrow turned [headingDeg] degrees clockwise from up, about [c].
  static void paintTurned(ui.Canvas canvas, ui.Offset c, double headingDeg, ui.Color fill, ui.Color ring, double d) {
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(headingDeg * math.pi / 180);
    canvas.translate(-c.dx, -c.dy);
    paint(canvas, c, fill, ring, d);
    canvas.restore();
  }

  /// The size of the arrow's picture in pixels at density [d].
  static ({int w, int h}) pictureSize(double d) => (w: (width * d).ceil() + 2 * bitmapPad, h: (2 * ahead * d).ceil() + 2 * bitmapPad);

  /// The arrow as a PNG (a map symbol image), unrotated, its position the picture's middle; [d] is the map's pixels per point
  /// (1 in a browser, the screen's own on a phone).
  static Future<Uint8List> png(ui.Color fill, ui.Color ring, double d) async {
    final size = pictureSize(d);
    final rec = ui.PictureRecorder();
    paint(ui.Canvas(rec), ui.Offset(size.w / 2, size.h / 2), fill, ring, d);
    final img = await rec.endRecording().toImage(size.w, size.h);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }
}
