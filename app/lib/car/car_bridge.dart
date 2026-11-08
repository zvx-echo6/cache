import 'dart:async';
import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../maps/maps_state.dart';
import '../maps/palette/map_palette.dart';
import '../maps/ui/map_assets.dart';
import '../nav/nav_geojson.dart';
import '../nav/nav_state.dart';
import '../nav/speaker.dart';
import '../theme.dart';
import 'car_drive.dart';
import 'car_trip.dart';

/// The car screen's link to the phone's guidance (Android Auto; the native side is app/android/.../car).
///
/// One guidance runs, the phone's [NavState]. The car shows it ([carTrip], pushed as it changes) and asks it for things: places
/// to go to, directions, start, stop, mute, a test drive. Nothing is worked out twice: searches and routes go to the same core
/// through the same [NavState] the phone screen uses, so a route started in the car shows on the phone and the other way round.
///
/// [connected] is true while a car screen is attached. It is the hook for the phone's own view while connected (later: the
/// phone shows the opposite view to the car's); today the phone just keeps working as it does.
class CarBridge {
  CarBridge({
    required this.nav,
    required this.maps,
    required this.drive,
    MethodChannel? channel,
    Future<String> Function()? glyphs,
    this.throttle = const Duration(milliseconds: 250),
  })  : _channel = channel ?? const MethodChannel('co.cache/car'),
        _glyphs = glyphs ?? MapAssets.glyphsUrl;

  final NavState nav;
  final MapsState maps;
  final CarDriveSource drive;
  final MethodChannel _channel;
  final Future<String> Function() _glyphs;
  final Duration throttle;

  /// True while the car screen is attached (see the class comment).
  final ValueNotifier<bool> connected = ValueNotifier(false);

  StreamSubscription<NavEvent>? _events;
  Timer? _pushTimer;
  String? _lastTrip;
  String? _lastRouteSig;
  String? _lastStyleKey;
  bool _started = false;

  /// Places the car was last shown, by id, so a tap in the car picks the very place the phone found.
  final Map<String, MapPlace> _shown = {};

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler(_onCall);
    nav.addListener(_schedule);
    maps.addListener(_onMaps);
    _events = nav.events.listen(_onEvent);
    try {
      // The native side may have a car session already (the car started the app): it answers with whether it does.
      final r = await _channel.invokeMethod<Object?>('hello');
      if (r is Map && r['connected'] == true) _setConnected(true);
    } on MissingPluginException {
      // No car side on this platform (iOS, the tests): nothing to link.
    } on PlatformException {
      // Same.
    }
  }

  void dispose() {
    _pushTimer?.cancel();
    nav.removeListener(_schedule);
    maps.removeListener(_onMaps);
    _events?.cancel();
    if (_started) _channel.setMethodCallHandler(null);
    connected.dispose();
  }

  void _setConnected(bool on) {
    if (connected.value == on) return;
    connected.value = on;
    if (on) {
      _lastTrip = null;
      _lastRouteSig = null;
      _schedule();
    } else {
      drive.simulate = false;
    }
  }

  // ---- pushing to the car ------------------------------------------------------------------------------------

  void _schedule() {
    if (!connected.value) return;
    _pushTimer ??= Timer(throttle, () {
      _pushTimer = null;
      unawaited(push());
    });
  }

  void _onMaps() {
    if (!connected.value) return;
    final key = maps.styleKey;
    if (key == _lastStyleKey) return;
    _lastStyleKey = key;
    unawaited(_send('styleChanged', null));
  }

  void _onEvent(NavEvent e) {
    if (e is NavNotice) unawaited(_send('notice', {'text': e.text}));
  }

  /// The trip as it is now, and the route line when it changed.
  Map<String, dynamic> snapshot() {
    final p = nav.progress;
    final f = nav.lastFix ?? nav.fix;
    final onRoute = nav.guiding && p != null && p.onRoute;
    final pos = onRoute ? p.matched : (f == null ? null : GeoPoint(f.lat, f.lon));
    final heading = onRoute ? p.routeBearingDeg.toDouble() : f?.heading;
    return carTrip(nav, position: pos, heading: heading);
  }

  Future<void> push() async {
    if (!connected.value) return;
    final trip = snapshot();
    final text = jsonEncode(trip);
    if (text != _lastTrip) {
      _lastTrip = text;
      await _send('trip', trip);
    }
    final sig = '${nav.phase.name}|${nav.routeIndex}|${[for (final r in nav.routes) r.routeId].join(',')}';
    if (sig != _lastRouteSig) {
      _lastRouteSig = sig;
      final shown = nav.phase == NavPhase.browsing ? const <MapRoute>[] : nav.routes;
      await _send('route', {'geojson': jsonEncode(routeGeoJson(shown, nav.routeIndex)), 'bounds': shown.isEmpty ? null : shown[nav.routeIndex.clamp(0, shown.length - 1)].bounds});
    }
  }

  Future<void> _send(String method, Object? args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      _setConnected(false);
    } on PlatformException {
      // The car side went away between the check and the call.
    }
  }

  /// A spoken prompt is about to play: the car side takes navigation audio focus for it.
  Future<void> prompt(String text) async {
    if (connected.value) await _send('prompt', {'text': text});
  }

  Future<void> promptStop() async {
    if (connected.value) await _send('promptStop', null);
  }

  // ---- the car asking --------------------------------------------------------------------------------------

  Future<Object?> _onCall(MethodCall call) async {
    final a = call.arguments is Map ? (call.arguments as Map).cast<String, Object?>() : const <String, Object?>{};
    switch (call.method) {
      case 'connected':
        _setConnected(a['on'] == true);
        return null;
      case 'snapshot':
        return snapshot();
      case 'style':
        return style(dark: a['dark'] == true);
      case 'saved':
        return [for (final p in await savedPlaces()) _placeOut(p)];
      case 'search':
        return [for (final p in await search((a['query'] ?? '') as String)) _placeOut(p)];
      case 'directions':
        final p = _shown[a['id']];
        if (p == null) return false;
        unawaited(nav.openDirections(p));
        return true;
      case 'selectRoute':
        nav.selectRoute((a['index'] as num?)?.toInt() ?? 0);
        return null;
      case 'start':
        await nav.start();
        return nav.guiding;
      case 'cancel':
        if (nav.phase == NavPhase.previewing) nav.cancelDirections();
        return null;
      case 'stop':
        await nav.end();
        return null;
      case 'voice':
        if ((a['on'] == true) != nav.voiceOn) nav.toggleVoice();
        return nav.voiceOn;
      case 'autoDrive':
        drive.simulate = a['on'] == true;
        return null;
      case 'navigateTo':
        return navigateTo(
          lat: (a['lat'] as num?)?.toDouble(),
          lon: (a['lon'] as num?)?.toDouble(),
          query: a['query'] as String?,
          start: a['start'] != false,
        );
    }
    throw MissingPluginException(call.method);
  }

  Map<String, Object?> _placeOut(MapPlace p) {
    _shown[p.id] = p;
    final d = nav.distanceFromHere(p);
    return {'id': p.id, 'name': p.name, 'address': p.address.isNotEmpty ? p.address : p.kind, 'lat': p.lat, 'lon': p.lon, 'distanceM': d};
  }

  /// The style the car map draws: the same layers as the phone's map in the light or dark map palette (the car says which),
  /// with the colors of the route and the position for the lines the car adds on top.
  Future<Map<String, Object?>?> style({required bool dark}) async {
    if (!maps.engine.ready) return null;
    final palette = mapPaletteFor(dark ? CacheThemeId.dark : CacheThemeId.light);
    final String glyphs;
    try {
      glyphs = await _glyphs();
    } catch (_) {
      return null;
    }
    _lastStyleKey = maps.styleKey;
    return {
      'style': await maps.styleJson(palette, glyphs),
      'colors': {for (final r in const ['route', 'routeCasing', 'routeOffroad', 'routeAlternate', 'position', 'positionRing', 'pin']) r: palette.css(r)},
    };
  }

  /// The saved places, as places to go to.
  Future<List<MapPlace>> savedPlaces() async {
    try {
      final saved = await nav.backend.savedPlaces();
      return [for (final s in saved) _savedPlace(s)];
    } catch (_) {
      return const [];
    }
  }

  static MapPlace _savedPlace(SavedPlaceRecord s) => MapPlace(
      id: 'place:${s.lat.toStringAsFixed(6)},${s.lon.toStringAsFixed(6)}',
      type: 'place',
      name: s.name,
      kind: 'Saved place',
      address: s.label ?? '',
      lat: s.lat,
      lon: s.lon,
      matched: 'saved');

  /// Saved places whose name is the query come first, then the map search (by meaning when the search model is loaded). The
  /// phone's own search panel is left as it is.
  Future<List<MapPlace>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final saved = [for (final s in await savedPlaces()) if (s.name.toLowerCase() == q.toLowerCase()) s];
    List<MapPlace> found = const [];
    try {
      final r = await nav.backend.search(q, near: nav.here, limit: 10, meaning: true);
      found = [for (final p in r.results) if (!p.isCategory) p];
    } catch (_) {}
    return [...saved, ...found].take(12).toList();
  }

  /// A navigation request from another app or the assistant (Android Auto's `androidx.car.app.action.NAVIGATE` with a `geo:`
  /// address): coordinates go straight to directions; a name that is a saved place does too; any other name comes back as the
  /// places found, for the driver to pick. [start] begins guidance once the route is ready (`intent=navigation`), otherwise the
  /// route is only shown (`intent=directions`).
  Future<Map<String, Object?>> navigateTo({double? lat, double? lon, String? query, bool start = true}) async {
    final q = (query ?? '').trim();
    MapPlace? to;
    if (lat != null && lon != null && !(lat == 0 && lon == 0)) {
      to = MapPlace.pin(lat, lon, name: q.isEmpty ? 'Dropped pin' : q);
    } else if (q.isNotEmpty) {
      final saved = [for (final s in await savedPlaces()) if (s.name.toLowerCase() == q.toLowerCase()) s];
      if (saved.isNotEmpty) {
        to = saved.first;
      } else {
        return {'places': [for (final p in await search(q)) _placeOut(p)]};
      }
    }
    if (to == null) return {'places': const []};
    _placeOut(to);
    if (nav.guiding) await nav.end();
    await nav.openDirections(to);
    if (start && nav.route != null) await nav.start();
    return {'started': nav.guiding, 'id': to.id};
  }
}

/// The phone's voice, which also takes the car's navigation audio focus for each prompt while a car screen is attached. The
/// prompts themselves are the phone's (the [GuidanceEngine] in NavState), said by the phone's text-to-speech.
class CarAwareSpeaker implements Speaker {
  CarAwareSpeaker(this.inner, {required this.car});

  final Speaker inner;
  final CarBridge? Function() car;

  @override
  Future<void> speak(String text) async {
    try {
      await car()?.prompt(text);
    } catch (_) {}
    await inner.speak(text);
  }

  @override
  Future<void> stop() async {
    await inner.stop();
    try {
      await car()?.promptStop();
    } catch (_) {}
  }
}
