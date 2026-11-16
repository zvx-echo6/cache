import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter/widgets.dart' show IconData;

import '../maps/maps_state.dart';
import '../maps/style/style_generator.dart' show kNotebookSource;
import '../maps/user_layers.dart';
import '../notebook/map_icons.dart';
import '../notebook/notebook_map.dart';
import '../notebook/notebook_state.dart';
import '../notebook/pin_image.dart';

/// The pins of the phone's map, for the car's map (Android Auto today; CarPlay reads the same message).
///
/// What the phone's Maps screen draws as pins, and from where (maps_screen.dart):
///  * the places of every notebook whose map switch is on (My layers), saved places included (they are the Places notebook's
///    entries): NotebookState.pins, the core's `pins`, which leaves out drafts and places switched off the map one by one. They
///    are the notebook pins layer (kNotebookPins) on kNotebookSource, each feature naming its picture in `pin` (PinLook: the place's
///    icon and colour, else its notebook's, drawn in the person's pin style by pin_image.dart);
///  * the repeaters of the repeater lists that are shown: the user repeaters layer on kUserSource, all one picture (a radio tower
///    in the pin style, repeaterPinName).
/// Not sent: the chosen place and the search results (kPinSource: the car draws the destination itself, and searches on its own
/// screen), and the lines and areas of imported files (not pins). The phone draws no names beside its pins, and nor does the car.
///
/// The car's style is the phone's style (CarBridge.style), so it already has kNotebookSource and the notebook pins layer, with the
/// layer's icon size and anchor for the pin style. All the pins go to that one source, the repeaters first (the phone draws them
/// under the notebook pins), each feature with only `pin`: the coordinates and a picture's name, nothing else of the place (no
/// title, no notebook, no entry). The pictures are PNGs made here by the phone's own [renderPinPng], at [kCarPinImageRatio]
/// pixels per point; the car tells its map so (Android: the bitmap's density; iOS: the image's scale), and the map shows them at
/// the phone's size in points.
///
/// When: as a car connects, and whenever what the phone draws changes (a place saved, moved, deleted or given another icon or
/// colour; a notebook's places changing; a map switch; a repeater list shown or hidden; the pin style; the car's map switching
/// between Tactical and not, which changes the pictures). A burst of changes is one message ([debounce]); a message that would
/// carry the same pins and no new picture is not sent (a renamed place changes nothing the car draws). Never on a position.
///
/// How many: what the phone draws, all of it, as the phone's map does (it has no limit either). A feature is about 80 bytes, so
/// a library of 2,000 places is about 160 KB, once per change, over the in-process channel; the pictures are one per icon and
/// colour in use (a few KB each), each sent once per connection.
class CarPins {
  CarPins({
    required this.read,
    required this.pinStyle,
    this.changes = const [],
    this.pinStyleChanges,
    CarPinRender? render,
    this.debounce = const Duration(milliseconds: 300),
  }) : _render = render ?? _renderPng;

  /// The pins of the phone's map, for the phone's own app: its notebooks, its repeater lists and its pin style.
  factory CarPins.of({required NotebookState notebooks, UserLayersState? userLayers, required MapsState maps}) => CarPins(
        read: ({required bool tactical}) => readMapPins(notebooks, userLayers, tactical: tactical),
        pinStyle: () => maps.pinStyle,
        changes: [notebooks, ?userLayers],
        pinStyleChanges: maps,
      );

  /// What the phone's map draws as pins now, with the colours for a Tactical map or not.
  final CarPinRead read;

  /// The person's pin style (Maps settings > Pin style).
  final PinStyle Function() pinStyle;

  /// Tell when what the pins are read from may have changed.
  final List<Listenable> changes;

  /// Tells when the pin style may have changed (it changes nothing when [pinStyle] is the same).
  final Listenable? pinStyleChanges;
  final CarPinRender _render;
  final Duration debounce;

  ValueListenable<bool>? _connected;
  Future<void> Function(String method, Object? args)? _send;
  Timer? _timer;
  bool _bound = false;

  /// Whether the car's map is Tactical (its palette, from the style the car last asked for).
  bool _tactical = false;

  /// The pin style the car was last sent pictures for.
  PinStyle? _style;

  /// The pictures sent in this connection (by name), and whether the next message tells the car to drop the ones it has.
  final Set<String> _sent = {};
  bool _reset = true;

  /// The pins last sent (the GeoJSON text).
  String? _lastGeo;

  bool _pushing = false;
  bool _again = false;

  /// Starts with the car link: [connected] is the bridge's, [send] its channel call.
  void bind({required ValueListenable<bool> connected, required Future<void> Function(String method, Object? args) send}) {
    if (_bound) return;
    _bound = true;
    _connected = connected;
    _send = send;
    connected.addListener(_onConnected);
    for (final c in changes) {
      c.addListener(_onChange);
    }
    pinStyleChanges?.addListener(_onPinStyle);
    if (connected.value) _onConnected();
  }

  void dispose() {
    _timer?.cancel();
    if (!_bound) return;
    _connected?.removeListener(_onConnected);
    for (final c in changes) {
      c.removeListener(_onChange);
    }
    pinStyleChanges?.removeListener(_onPinStyle);
  }

  bool get _on => _connected?.value ?? false;

  /// The car's map is (or is not) Tactical: its pictures are drawn again in that look.
  void setTactical(bool on) {
    if (on == _tactical) return;
    _tactical = on;
    _forget();
    if (_on) _schedule(now: true);
  }

  void _onConnected() {
    _timer?.cancel();
    _timer = null;
    // A car that connects has no pins and no pictures: all of them go.
    _forget();
    if (_on) _schedule(now: true);
  }

  void _onChange() {
    if (_on) _schedule();
  }

  void _onPinStyle() {
    if (_on && pinStyle() != _style) _schedule();
  }

  void _forget() {
    _sent.clear();
    _reset = true;
    _lastGeo = null;
  }

  void _schedule({bool now = false}) {
    _timer?.cancel();
    _timer = Timer(now ? Duration.zero : debounce, () {
      _timer = null;
      unawaited(push());
    });
  }

  /// Sends the pins when they changed. One at a time: a change that comes while one is being made is sent after it.
  Future<void> push() async {
    if (!_on) return;
    if (_pushing) {
      _again = true;
      return;
    }
    _pushing = true;
    try {
      do {
        _again = false;
        await _pushOnce();
      } while (_again && _on);
    } finally {
      _pushing = false;
    }
  }

  Future<void> _pushOnce() async {
    final style = pinStyle();
    if (style != _style) {
      _style = style;
      _forget();
    }
    final tactical = _tactical;
    final List<CarPin> pins;
    try {
      pins = await read(tactical: tactical);
    } catch (_) {
      // Not readable now (the core still opening): the next change tries again. Nothing of the places is logged.
      return;
    }
    if (style != pinStyle() || tactical != _tactical) {
      _again = true;
      return;
    }
    final images = <String, Uint8List>{};
    final features = <Map<String, Object?>>[];
    for (final p in pins) {
      final name = pinImageId(style, p.iconId, p.tint, tactical: tactical);
      if (!_sent.contains(name) && !images.containsKey(name)) {
        images[name] = await _render(p.glyph, p.tint, style, ratio: kCarPinImageRatio, tactical: tactical);
      }
      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [p.lon, p.lat],
        },
        'properties': {'pin': name},
      });
    }
    final geo = jsonEncode({'type': 'FeatureCollection', 'features': features});
    if (geo == _lastGeo && images.isEmpty) return;
    final send = _send;
    if (send == null || !_on) return;
    await send('pins', carPinsMessage(geojson: geo, images: images, reset: _reset));
    _sent.addAll(images.keys);
    _reset = false;
    _lastGeo = geo;
  }

  static Future<Uint8List> _renderPng(IconData icon, Color tint, PinStyle style, {required double ratio, required bool tactical}) =>
      renderPinPng(icon, tint, style, ratio: ratio, tactical: tactical);
}

/// Pixels per point of the pin pictures sent to the car: the car's map shows them at that scale, so a pin is as many points as on
/// the phone (pin_image.dart) and sharp on any car screen up to three pixels per point.
const double kCarPinImageRatio = 3;

/// The `pins` message to the car (Android Auto's CarPins.kt reads it; CarPlay reads the same):
///  * `source`: the style's source to fill (kNotebookSource, whose layer draws `pin` per feature);
///  * `geojson`: a FeatureCollection of Points, each with only `pin`, the name of its picture;
///  * `images`: the pictures not sent before in this connection, by name, as PNG bytes;
///  * `ratio`: the pictures' pixels per point ([kCarPinImageRatio]);
///  * `reset`: true when the car is to drop the pictures it holds first (a new connection, another pin style, Tactical or not).
Map<String, Object?> carPinsMessage({required String geojson, required Map<String, Uint8List> images, required bool reset}) => {
      'source': kNotebookSource,
      'geojson': geojson,
      'images': images,
      'ratio': kCarPinImageRatio,
      'reset': reset,
    };

/// One pin of the phone's map: where it is and its picture's icon and colour.
@immutable
class CarPin {
  const CarPin({required this.lat, required this.lon, required this.iconId, required this.glyph, required this.tint});

  final double lat;
  final double lon;
  final String iconId;
  final IconData glyph;
  final Color tint;
}

typedef CarPinRead = Future<List<CarPin>> Function({required bool tactical});
typedef CarPinRender = Future<Uint8List> Function(IconData icon, Color tint, PinStyle style, {required double ratio, required bool tactical});

/// What the phone's Maps screen draws as pins ([CarPins]): the shown repeater lists' repeaters, then the places of the notebooks on
/// the map, each with the look the phone gives it (PinLook, repeaterTint) in a Tactical map or not.
Future<List<CarPin>> readMapPins(NotebookState notebooks, UserLayersState? userLayers, {required bool tactical}) async {
  final out = <CarPin>[];
  if (userLayers != null) {
    final tower = mapIcon(kRepeaterIcon);
    final tint = repeaterTint(tactical: tactical);
    for (final r in await userLayers.shownRepeaterPositions()) {
      out.add(CarPin(lat: r.lat, lon: r.lon, iconId: kRepeaterIcon, glyph: tower.icon, tint: tint));
    }
  }
  await notebooks.start();
  for (final e in await notebooks.pins()) {
    final at = e.place;
    if (at == null) continue;
    final look = PinLook.of(e, notebooks.notebook(e.notebookId), tactical: tactical);
    out.add(CarPin(lat: at.lat, lon: at.lon, iconId: look.icon.id, glyph: look.glyph, tint: look.tint));
  }
  return out;
}
