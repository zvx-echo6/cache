import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// How long the mouse is held on the map, without moving, to open the ring menu.
const _holdFor = Duration(milliseconds: 500);

/// The browser map has no press-and-hold: the maplibre_gl web plugin maps its long click to a double click (maplibre_gl_web
/// maplibre_web_gl_platform.dart, `_map.on('dblclick', _onMapLongClick)`). This opens the ring menu on a right-click (contextmenu,
/// which also stops the browser's own menu) and on a left mouse hold of 500 ms that does not move. [onRing] gets the position in the
/// page and in the map's own box. Returns a function that stops listening.
void Function() listenMapMouse(void Function(double clientX, double clientY, double localX, double localY) onRing) {
  Timer? hold;
  double downX = 0, downY = 0;
  JSFunction? swallow;

  web.Element? mapOf(web.Event e) {
    final t = e.target;
    return t.isA<web.Element>() ? (t as web.Element).closest('.maplibregl-map') : null;
  }

  void fire(web.Element map, double x, double y) {
    final r = map.getBoundingClientRect();
    onRing(x, y, x - r.left, y - r.top);
  }

  void stopHold() {
    hold?.cancel();
    hold = null;
  }

  void dropSwallow() {
    final s = swallow;
    if (s != null) web.document.removeEventListener('click', s, true.toJS);
    swallow = null;
  }

  // The click that ends a hold must not reach the map as a tap.
  void swallowNextClick() {
    dropSwallow();
    swallow = ((web.Event e) {
      e.stopPropagation();
      dropSwallow();
    }).toJS;
    web.document.addEventListener('click', swallow, true.toJS);
    Timer(const Duration(seconds: 1), dropSwallow);
  }

  final context = ((web.MouseEvent e) {
    final map = mapOf(e);
    if (map == null) return;
    e.preventDefault();
    stopHold();
    fire(map, e.clientX.toDouble(), e.clientY.toDouble());
  }).toJS;
  final down = ((web.PointerEvent e) {
    stopHold();
    if (e.pointerType != 'mouse' || e.button != 0) return;
    final map = mapOf(e);
    if (map == null) return;
    downX = e.clientX.toDouble();
    downY = e.clientY.toDouble();
    hold = Timer(_holdFor, () {
      hold = null;
      swallowNextClick();
      fire(map, downX, downY);
    });
  }).toJS;
  final move = ((web.PointerEvent e) {
    if (hold != null && ((e.clientX - downX).abs() > 6 || (e.clientY - downY).abs() > 6)) stopHold();
  }).toJS;
  final end = ((web.Event e) => stopHold()).toJS;

  const capture = true;
  web.document.addEventListener('contextmenu', context, capture.toJS);
  web.document.addEventListener('pointerdown', down, capture.toJS);
  web.document.addEventListener('pointermove', move, capture.toJS);
  web.document.addEventListener('pointerup', end, capture.toJS);
  web.document.addEventListener('pointercancel', end, capture.toJS);
  web.document.addEventListener('wheel', end, capture.toJS);
  return () {
    stopHold();
    dropSwallow();
    web.document.removeEventListener('contextmenu', context, capture.toJS);
    web.document.removeEventListener('pointerdown', down, capture.toJS);
    web.document.removeEventListener('pointermove', move, capture.toJS);
    web.document.removeEventListener('pointerup', end, capture.toJS);
    web.document.removeEventListener('pointercancel', end, capture.toJS);
    web.document.removeEventListener('wheel', end, capture.toJS);
  };
}
