import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../../layout/modal_watch.dart';
import '../web/map_pointer.dart';

/// Tells the map's HTML element (browser only) to let pointer events through while a sheet, dialog or menu is open over it.
class MapPointerGate extends StatefulWidget {
  const MapPointerGate({super.key, required this.child, this.setter = setMapPointerIgnored, this.web = kIsWeb, this.extraBlock = false});

  final Widget child;

  /// Does the work on the element; tests swap it.
  final void Function(bool ignore) setter;

  /// A browser. Tests set it.
  final bool web;

  /// True: the map ignores pointer events even with no sheet, dialog or menu open (the ring menu, drawn over the map, is open).
  final bool extraBlock;

  @override
  State<MapPointerGate> createState() => _MapPointerGateState();
}

class _MapPointerGateState extends State<MapPointerGate> {
  @override
  void initState() {
    super.initState();
    if (widget.web) {
      modalWatch.addListener(_sync);
      _sync();
    }
  }

  @override
  void didUpdateWidget(MapPointerGate old) {
    super.didUpdateWidget(old);
    if (widget.web && old.extraBlock != widget.extraBlock) _sync();
  }

  @override
  void dispose() {
    if (widget.web) modalWatch.removeListener(_sync);
    super.dispose();
  }

  void _sync() => widget.setter(modalWatch.isOpen || widget.extraBlock);

  @override
  Widget build(BuildContext context) => widget.child;
}
