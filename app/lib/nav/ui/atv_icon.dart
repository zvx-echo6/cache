import 'package:flutter/material.dart';

/// A small quad (ATV) silhouette in the weight of the Material icons beside it (Drive, Walk, Bike): two big wheels, a seat over
/// the frame, a steering column and handlebars. The icon package has no ATV symbol, so it is drawn here. [size] is the icon's box
/// (the Material icons are 24 in a 24 box); [color] is its ink.
class AtvIcon extends StatelessWidget {
  const AtvIcon({super.key, this.size = 24, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: ExcludeSemantics(child: CustomPaint(painter: _AtvPainter(color))),
      );
}

class _AtvPainter extends CustomPainter {
  const _AtvPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 24 x 24 grid, scaled to the box.
    canvas.scale(size.width / 24, size.height / 24);
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    // Wheels: thick tyres around a hub that shows the ground colour through, so they read as wheels at 22 px.
    for (final c in const [Offset(5.6, 17.2), Offset(18.6, 17.2)]) {
      canvas.drawCircle(c, 3.9, line..strokeWidth = 2.6);
      canvas.drawCircle(c, 1.0, fill);
    }
    // Seat and rear fender: one rounded slab over the rear wheel, running forward into the tank.
    final body = Path()
      ..moveTo(2.6, 11.4)
      ..quadraticBezierTo(2.6, 9.6, 4.6, 9.6)
      ..lineTo(11.2, 9.6)
      ..quadraticBezierTo(12.4, 9.6, 13.0, 10.6)
      ..lineTo(14.2, 12.6)
      ..lineTo(8.0, 12.6)
      ..lineTo(8.0, 13.6)
      ..lineTo(2.6, 13.6)
      ..close();
    canvas.drawPath(body, fill);
    // Frame from the seat down to the front axle, and the steering column up to the handlebars.
    canvas.drawLine(const Offset(11.0, 12.6), const Offset(18.6, 17.2), line..strokeWidth = 1.8);
    canvas.drawLine(const Offset(14.4, 11.8), const Offset(16.8, 6.6), line..strokeWidth = 1.8);
    canvas.drawLine(const Offset(15.2, 6.2), const Offset(19.4, 6.2), line..strokeWidth = 2.0);
  }

  @override
  bool shouldRepaint(_AtvPainter old) => old.color != color;
}
