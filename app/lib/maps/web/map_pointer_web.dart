import 'package:web/web.dart' as web;

/// True: the map's HTML element lets pointer events (clicks, wheel) through to what is drawn over it; false: it takes them again.
///
/// The map is an HTML element under Flutter (the maplibre_gl web plugin's platform view), and an HTML element takes every pointer
/// event in its area, so a sheet or dialog drawn over it got no clicks and the map behind got them instead. The plugin keeps its
/// element private, so this finds it by the class MapLibre GL JS puts on a map's container.
void setMapPointerIgnored(bool ignore) {
  final maps = web.document.querySelectorAll('.maplibregl-map');
  for (var i = 0; i < maps.length; i++) {
    (maps.item(i) as web.HTMLElement).style.pointerEvents = ignore ? 'none' : '';
  }
}
