// The real maps behind the guide's Maps pictures (tools/guide/README.md, "The map pictures").
//
// A test cannot draw the map: MapLibre is a platform view. So the guide test works in two passes. With GUIDE_MAPS=export it writes
// what each map picture shows as a "scene": the app's own style, the camera the screen asked for, the route, pins and position
// the screen put on the map, and the images it added (test_shots/guide/scenes/<scene>.json). tools/guide/maps/render.mjs draws
// each scene with MapLibre GL JS (test_shots/guide_maps/<theme>/<scene>.png) and notes the scene's SHA-256 beside the pictures
// (scenes.lock.json). Run again without the variable, the test shows each picture where the map is, and fails on a scene whose
// picture is missing or was rendered from another scene. A scene says nothing about how it is rendered, so another renderer (the
// phone's own, on an emulator) can read the same files. The place form's small map is drawn the same way (GuideFormMap).

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cache/nav/overview/overview_camera.dart';
import 'package:cache/nav/overview/route_overview.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../test/navigation_camera_test.dart' show CameraController, NoSurface;

/// The screen the map pictures stand for: a 3x phone, whatever scale the test draws at. The renderer draws the images the screen
/// adds to its map at this many pixels per point, as that phone's map does (IMAGE_PIXEL_RATIO in tools/guide/maps/render.mjs), so
/// the screen is told to draw its pin images for that phone (MapsScreen.imagePixelRatio), and the place form's pin is drawn for it.
const double kGuidePhoneScale = 3;

/// Where a camera update of the map package keeps its numbers, read from the package's own encoding of a known update (so this file
/// does not depend on their order).
final List<dynamic> _fitProbe = _fitUpdate(0, 1);
final List<dynamic> _zoomProbe = CameraUpdate.newLatLngZoom(const LatLng(0, 0), 7).toJson() as List<dynamic>;

List<dynamic> _fitUpdate(double low, double high) =>
    CameraUpdate.newLatLngBounds(LatLngBounds(southwest: LatLng(low, low), northeast: LatLng(high, high)), left: 11, top: 12, right: 13, bottom: 14).toJson() as List<dynamic>;

double _mx(double lon) => (lon + 180) / 360;
double _my(double lat) {
  final l = lat.clamp(-85.0511287798, 85.0511287798) * math.pi / 180;
  return (1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2;
}

/// The camera of a map picture: its centre, zoom and bearing (the app never tilts the map). MapLibre draws the world 512 points wide
/// at zoom 0, on the phone and in the renderer.
class GuideCamera {
  const GuideCamera({required this.lat, required this.lon, required this.zoom, this.bearing = 0});

  final double lat;
  final double lon;
  final double zoom;

  /// Degrees the map is turned clockwise (0: north up).
  final double bearing;

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon, 'zoom': zoom, 'bearing': bearing};

  /// This camera after the camera update [u] (CameraUpdate.toJson, as the test's controller records it) on a map of [size].
  GuideCamera after(List<dynamic> u, Size size) {
    List<double> pair(Object? v) => [for (final n in v as List) (n as num).toDouble()];
    final kind = u.first as String;
    if (kind == 'newCameraPosition') {
      final p = (u[1] as Map).cast<String, dynamic>();
      final t = pair(p['target']);
      return GuideCamera(lat: t[0], lon: t[1], zoom: (p['zoom'] as num).toDouble(), bearing: (p['bearing'] as num).toDouble());
    }
    if (kind == 'newLatLng') {
      final t = pair(u[1]);
      return GuideCamera(lat: t[0], lon: t[1], zoom: zoom, bearing: bearing);
    }
    if (kind == 'newLatLngZoom') {
      final t = pair(u[1]);
      return GuideCamera(lat: t[0], lon: t[1], zoom: (u[_zoomProbe.indexOf(7.0)] as num).toDouble(), bearing: bearing);
    }
    if (kind == 'newLatLngBounds') {
      // The box fitted inside the map less its padding, north up: the same web-mercator fit MapLibre makes (OverviewCamera.fit;
      // its cap of zoom 16 is far above any route the guide shows).
      final a = pair((u[1] as List)[0]), b = pair((u[1] as List)[1]);
      double pad(double probe) => (u[_fitProbe.indexOf(probe)] as num).toDouble();
      final fit = OverviewCamera.fit(
        south: math.min(a[0], b[0]),
        west: math.min(a[1], b[1]),
        north: math.max(a[0], b[0]),
        east: math.max(a[1], b[1]),
        size: size,
        padding: EdgeInsets.fromLTRB(pad(11), pad(12), pad(13), pad(14)),
      );
      return GuideCamera(lat: fit.lat, lon: fit.lon, zoom: fit.zoom);
    }
    if (kind == 'bearingTo') {
      return GuideCamera(lat: lat, lon: lon, zoom: zoom, bearing: (u[1] as num).toDouble());
    }
    throw StateError('The guide map kit does not know the camera move "$kind"');
  }

  /// Where ([lat], [lon]) falls on a map of [size] seen by this camera, in points from its top left.
  Offset project(double lat, double lon, Size size) {
    final scale = 512 * math.pow(2, zoom).toDouble();
    final dx = (_mx(lon) - _mx(this.lon)) * scale, dy = (_my(lat) - _my(this.lat)) * scale;
    final b = bearing * math.pi / 180;
    // The map is turned clockwise by the bearing, so what is on it turns the other way on the screen.
    return Offset(size.width / 2 + dx * math.cos(b) + dy * math.sin(b), size.height / 2 - dx * math.sin(b) + dy * math.cos(b));
  }
}

/// The map controller the screen is given: it records the camera moves and the GeoJSON the screen sets (CameraController), and also
/// the images the screen adds and each new style it sets. A new style starts with no images and no data, as on the map.
class GuideMapController extends CameraController {
  final Map<String, Uint8List> images = {};

  /// The last style the screen set; null while the map still has the style it was built with.
  String? style;

  /// How many times the screen has set a style.
  int styleSets = 0;

  @override
  Future<void> addImage(String name, Uint8List bytes, [bool sdf = false]) async {
    images[name] = bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #setStyle) {
      style = invocation.positionalArguments.first as String;
      styleSets++;
      sources.clear();
      images.clear();
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

/// The map's place on the screen in a test: the picture of the scene being shown, or the map's land colour while there is none.
class GuideMapSurface extends NoSurface {
  GuideMapSurface(this.picture, this.land);

  final ValueListenable<ui.Image?> picture;
  final Color land;

  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) =>
      ValueListenableBuilder<ui.Image?>(
        valueListenable: picture,
        builder: (context, image, _) => SizedBox.expand(
          child: image == null ? ColoredBox(color: land) : RawImage(image: image, fit: BoxFit.fill),
        ),
      );
}

/// The small map of the place form in a test (the app's PlaceMap is a platform view too): the picture of its scene, or the empty
/// space the form had before while there is none.
class GuideFormMap extends StatelessWidget {
  const GuideFormMap(this.picture, {super.key});

  final ValueListenable<ui.Image?> picture;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ui.Image?>(
        valueListenable: picture,
        builder: (context, image, _) => image == null ? const SizedBox.shrink() : RawImage(image: image, fit: BoxFit.fill),
      );
}

bool _symbols = false;

/// Material Symbols from the package's own font file (a test loads no font by itself): the icons of notebooks and places, on the
/// ring's wedges and in the pins on the map. Loading is real work: call it inside tester.runAsync.
Future<void> loadSymbolFont() async {
  if (_symbols) return;
  final cfg = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map;
  final pkg = (cfg['packages'] as List).cast<Map>().firstWhere((p) => p['name'] == 'material_symbols_icons');
  final root = Directory.current.uri.resolve('.dart_tool/').resolve('${pkg['rootUri']}/');
  final bytes = File.fromUri(root.resolve('lib/fonts/MaterialSymbolsOutlined.ttf')).readAsBytesSync();
  final loader = FontLoader('packages/material_symbols_icons/MaterialSymbolsOutlined')..addFont(Future.value(Uint8List.fromList(bytes).buffer.asByteData()));
  await loader.load();
  _symbols = true;
}

/// The whole-route picture in the corner while guiding (on a phone, MapLibre's offscreen snapshot): the screen asks for it with the
/// style and camera it wants, which become the scene [scene]; it is given that scene's picture when there is one.
class GuideSnapshotter implements RouteSnapshotter {
  GuideSnapshotter(this._maps);

  static const String scene = 'guidance-inset';

  final GuideMaps _maps;
  String? _style;
  OverviewCamera? _camera;
  double _ratio = 1;

  @override
  Future<OverviewPicture?> render({required String styleJson, required OverviewCamera camera, required double pixelRatio}) async {
    _style = styleJson;
    _camera = camera;
    _ratio = pixelRatio;
    final image = _maps._pictures[scene];
    // The screen owns the picture it is given and disposes of it, so it gets its own handle.
    return image == null ? null : OverviewPicture(image: image.clone(), camera: camera, pixelRatio: pixelRatio, renderMs: 0);
  }

  /// Writes the scene of the picture the screen asked for, and checks the picture it was given (see [GuideMaps.show]).
  void write() {
    final style = _style, camera = _camera;
    if (style == null || camera == null) fail('The Maps screen did not ask for the whole-route picture');
    // The route and its ends are written into this style by the screen, so the scene has no data of its own.
    _maps.writeScene(scene, style: style, camera: GuideCamera(lat: camera.lat, lon: camera.lon, zoom: camera.zoom), size: camera.size, ratio: _ratio);
    _maps._check(scene);
  }
}

/// The map pictures of one guide run: the scenes written, the pictures rendered from them, and what the map area shows now.
class GuideMaps {
  GuideMaps({this.theme = 'light'});

  /// Where the scenes for the renderer are written. A drawing run writes its own into the folder "drawn" inside it, so the two can
  /// be told apart when a picture turns out to be of another scene.
  static const String scenesDir = 'test_shots/guide/scenes';
  static const String picturesDir = 'test_shots/guide_maps';

  /// How the pictures are made (said when one is missing).
  static const String command = 'gh workflow run renders.yml --ref <branch> -f guide=true';

  /// True while the scenes are being written for the renderer (GUIDE_MAPS=export): a map picture that is not there yet is left as
  /// the land colour instead of failing the test.
  static bool get exporting => Platform.environment['GUIDE_MAPS'] == 'export';

  /// The app theme the pictures are of (the folder under [picturesDir]).
  final String theme;

  final GuideMapController controller = GuideMapController();

  /// The style the Maps screen built its map with (the same call the screen makes; the test sets it once the map is there).
  String? firstStyle;

  /// The style the map has now: the last one the screen set, else the one it was built with.
  String get style => controller.style ?? firstStyle!;

  /// What the map area shows: a scene's picture, or null for the land colour.
  final ValueNotifier<ui.Image?> picture = ValueNotifier<ui.Image?>(null);

  late final GuideSnapshotter inset = GuideSnapshotter(this);

  final Map<String, ui.Image> _pictures = {};
  Map<String, dynamic> _lock = const {};
  final Map<String, String> _written = {};
  static String get _writeDir => exporting ? scenesDir : '$scenesDir/drawn';
  GuideCamera? _camera;
  int _camerasSeen = 0;

  /// Before the first test of a run: the list of the run's scenes starts empty (each test with map pictures adds its own).
  static void startRun() {
    final f = File('$_writeDir/index.json');
    if (f.existsSync()) f.deleteSync();
  }

  /// Reads the rendered pictures and the note of which scene each was rendered from. Decoding is real work, so it runs outside the
  /// test's fake clock.
  Future<void> load(WidgetTester tester) async {
    final lock = File('$picturesDir/scenes.lock.json');
    if (lock.existsSync()) _lock = (jsonDecode(lock.readAsStringSync()) as Map).cast<String, dynamic>();
    final dir = Directory('$picturesDir/$theme');
    if (!dir.existsSync()) return;
    final files = [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.png')) f,
    ];
    await tester.runAsync(() async {
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        final codec = await ui.instantiateImageCodec(f.readAsBytesSync());
        final frame = await codec.getNextFrame();
        _pictures[name.substring(0, name.length - 4)] = frame.image;
        codec.dispose();
      }
    });
  }

  /// The camera the map has: the one it was built with, then every move the screen has asked for since, in order.
  GuideCamera cameraOf(MapLibreMap map, Size size) {
    // The Maps screen always gives its map a first camera (the map package makes it optional).
    final first = map.initialCameraPosition!;
    GuideCamera cam = _camera ?? GuideCamera(lat: first.target.latitude, lon: first.target.longitude, zoom: first.zoom, bearing: first.bearing);
    for (final u in controller.cameras.skip(_camerasSeen)) {
      cam = cam.after(u as List<dynamic>, size);
    }
    _camerasSeen = controller.cameras.length;
    return _camera = cam;
  }

  /// The map was moved to [camera] by the test itself (not by the screen).
  void movedTo(GuideCamera camera) {
    _camerasSeen = controller.cameras.length;
    _camera = camera;
  }

  /// Writes the scene [scene] and returns its SHA-256: the style, the camera, the size in points and the pixel ratio, the GeoJSON
  /// [sources] the screen set and the [images] it added (PNG, base64). Keys are written in a fixed order, so the same scene is the
  /// same bytes.
  String writeScene(
    String scene, {
    required String style,
    required GuideCamera camera,
    required Size size,
    required double ratio,
    Map<String, Map<String, dynamic>> sources = const {},
    Map<String, Uint8List> images = const {},
  }) {
    final text = const JsonEncoder.withIndent(' ').convert({
      'scene': scene,
      'theme': theme,
      'width': size.width,
      'height': size.height,
      'pixelRatio': ratio,
      'camera': camera.toJson(),
      'sources': SplayTreeMap<String, dynamic>.of(sources),
      'images': {for (final e in SplayTreeMap<String, Uint8List>.of(images).entries) e.key: base64Encode(e.value)},
      'style': jsonDecode(style),
    });
    File('$_writeDir/$scene.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    return _written[scene] = sha256.convert(utf8.encode(text)).toString();
  }

  /// Writes the list of the scenes written in this run with their SHA-256 (the renderer checks each file against it): the scenes
  /// of this test are added to those the run's earlier tests listed (see [startRun]).
  void writeIndex() {
    final f = File('$_writeDir/index.json');
    final all = SplayTreeMap<String, String>();
    if (f.existsSync()) all.addAll((jsonDecode(f.readAsStringSync()) as Map).cast<String, String>());
    all.addAll(_written);
    f
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(all));
  }

  /// Puts [scene]'s picture where the map is (the land colour while exporting, when it is not rendered yet). Null: no picture.
  void show(String? scene) {
    if (scene != null) _check(scene);
    picture.value = scene == null ? null : _pictures[scene];
  }

  /// Fails the test when [scene]'s picture is missing or was rendered from another scene than the one just written.
  void _check(String scene) {
    if (exporting) return;
    final missing = _pictures[scene] == null;
    if (missing || _lock['$theme/$scene'] != _written[scene]) {
      fail('The map picture $picturesDir/$theme/$scene.png ${missing ? 'is missing' : 'was rendered from another scene than this one'}. '
          'The map pictures are rendered from the scenes this test writes; make the guide pictures with: $command');
    }
  }

  void dispose() {
    picture.dispose();
    controller.dispose();
    for (final i in _pictures.values) {
      i.dispose();
    }
    _pictures.clear();
  }
}
