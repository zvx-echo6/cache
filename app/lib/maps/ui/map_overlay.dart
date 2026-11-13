import 'package:flutter/widgets.dart';
import 'package:pointer_interceptor_platform_interface/pointer_interceptor_platform_interface.dart';

/// Something drawn over the map: the search bar, a place card or the way to go, the map buttons, the chips, the ring menu.
///
/// In a browser the map is a web element under the page, and a click on a widget over it also reaches the map: the map's own tap
/// then cleared the place that the click had just chosen, so no place card ever showed in Cache on Linux. Here the click stops at
/// the widget. Only in a browser: elsewhere the platform interface's default gives [child] back as it is (no native code; the web
/// implementation, pointer_interceptor_web, is a web-only plugin).
class MapOverlay extends StatelessWidget {
  const MapOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => PointerInterceptorPlatform.instance.buildWidget(child: child);
}
