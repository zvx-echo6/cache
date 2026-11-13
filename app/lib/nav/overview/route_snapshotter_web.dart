import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' as ui;

import 'package:web/web.dart' as web;

import 'overview_camera.dart';
import 'route_overview.dart';

/// A browser's whole-route picture (Cache on Linux): what the phone's native snapshotter does, with MapLibre GL JS, the library the
/// browser's live map is drawn with. A map of [RouteSnapshotter.render]'s style is made offscreen at the camera's centre, zoom and
/// size, drawn once, read back as a PNG and removed; the live map is not touched. Its tiles come from Cache Server's tile route,
/// as the live map's do. Null when MapLibre is not on the page or the picture could not be made in time.
class WebRouteSnapshotter implements RouteSnapshotter {
  const WebRouteSnapshotter({this.timeout = const Duration(seconds: 20)});

  /// The longest a picture may take (its tiles come over the network).
  final Duration timeout;

  @override
  Future<OverviewPicture?> render({required String styleJson, required OverviewCamera camera, required double pixelRatio}) async {
    final lib = globalContext['maplibregl'];
    if (lib == null || !lib.isA<JSObject>()) return null;
    final clock = Stopwatch()..start();
    final w = camera.size.width.round(), h = camera.size.height.round();
    if (w <= 0 || h <= 0) return null;
    final box = web.document.createElement('div') as web.HTMLDivElement;
    // Laid out (MapLibre needs a size) but out of sight and out of the way of the page.
    box.style.cssText = 'position:fixed;left:-${w + 1000}px;top:0;width:${w}px;height:${h}px;pointer-events:none';
    web.document.body?.append(box);
    JSObject? map;
    try {
      final style = (globalContext['JSON'] as JSObject).callMethod<JSAny>('parse'.toJS, styleJson.toJS);
      final options = JSObject()
        ..['container'] = box
        ..['style'] = style
        ..['center'] = [camera.lon.toJS, camera.lat.toJS].toJS
        ..['zoom'] = camera.zoom.toJS
        ..['pixelRatio'] = pixelRatio.toJS
        ..['interactive'] = false.toJS
        ..['attributionControl'] = false.toJS
        ..['fadeDuration'] = 0.toJS
        ..['preserveDrawingBuffer'] = true.toJS;
      final ctor = (lib as JSObject)['Map'];
      if (ctor == null) return null;
      map = (ctor as JSFunction).callAsConstructor<JSObject>(options);
      final drawn = Completer<void>();
      map.callMethod<JSAny?>('once'.toJS, 'idle'.toJS, ((JSAny? _) {
        if (!drawn.isCompleted) drawn.complete();
      }).toJS);
      await drawn.future.timeout(timeout);
      final canvas = map.callMethod<web.HTMLCanvasElement>('getCanvas'.toJS);
      final url = canvas.toDataURL('image/png');
      final codec = await ui.instantiateImageCodec(base64Decode(url.substring(url.indexOf(',') + 1)));
      final frame = await codec.getNextFrame();
      return OverviewPicture(image: frame.image, camera: camera, pixelRatio: pixelRatio, renderMs: clock.elapsedMilliseconds.toDouble());
    } catch (_) {
      return null;
    } finally {
      try {
        map?.callMethod<JSAny?>('remove'.toJS);
      } catch (_) {}
      box.remove();
    }
  }
}

/// The whole-route picture's maker here: a browser's.
RouteSnapshotter platformRouteSnapshotter() => const WebRouteSnapshotter();
