import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../../layout/modal_watch.dart';
import '../web/map_pointer.dart';

/// Tells the map's HTML element (browser only) to let pointer events through while a sheet, dialog or menu is open over it.
class MapPointerGate extends StatefulWidget {
  const MapPointerGate({super.key, required this.child, this.setter = setMapPointerIgnored, this.web = kIsWeb});

  final Widget child;

  /// Does the work on the element; tests swap it.
  final void Function(bool ignore) setter;

  /// A browser. Tests set it.
  final bool web;

  @override
  State<MapPointerGate> createState() => _MapPointerGateState();
}

class _MapPointerGateState extends State<MapPointerGate> {
  @override
  Widget build(BuildContext context) => widget.child;
}
