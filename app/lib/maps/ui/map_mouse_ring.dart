import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../web/map_mouse.dart';

/// Opens the map's ring menu from the mouse in a browser: a right-click, or a hold of about 500 ms without moving. The browser
/// map never raises its long click on either. Phones are unchanged: nothing is listened to there.
/// Where the ring is drawn for a mouse spot. The ring overlay sits in the same Stack as the map, so it is placed by a point in the
/// map's own box, not by the page point (the page point is shifted by anything beside the map, such as the wide layout's side rail).
Offset mouseRingCentre(Offset page, math.Point<double> inMap) => Offset(inMap.x, inMap.y);

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
  void Function()? _stop;

  @override
  void initState() {
    super.initState();
    if (widget.web) {
      _stop = widget.listen((cx, cy, lx, ly) => widget.onRing(Offset(cx, cy), math.Point<double>(lx, ly)));
    }
  }

  @override
  void dispose() {
    _stop?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
