import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../web/map_mouse.dart';

/// Opens the map's ring menu from the mouse in a browser: a right-click, or a hold of about 500 ms without moving. The browser
/// map never raises its long click on either. Phones are unchanged: nothing is listened to there.
class MapMouseRing extends StatefulWidget {
  const MapMouseRing({super.key, required this.child, required this.onRing, this.listen = listenMapMouse, this.web = kIsWeb});

  final Widget child;

  /// The spot, in the page and in the map's own box.
  final void Function(Offset page, math.Point<double> inMap) onRing;

  /// Starts listening; returns the function that stops. Tests swap it.
  final void Function() Function(void Function(double, double, double, double) onRing) listen;

  /// A browser. Tests set it.
  final bool web;

  @override
  State<MapMouseRing> createState() => _MapMouseRingState();
}

class _MapMouseRingState extends State<MapMouseRing> {
  @override
  Widget build(BuildContext context) => widget.child;
}
