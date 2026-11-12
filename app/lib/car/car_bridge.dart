import 'dart:async';
import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../maps/maps_state.dart';
import '../nav/elevation/route_elevation.dart';
import '../maps/palette/map_palette.dart';
import '../maps/ui/map_assets.dart';
import '../nav/nav_geojson.dart';
import '../nav/nav_state.dart';
import '../nav/speaker.dart';
import '../platform/app_log.dart';
import '../theme.dart';
import 'car_drive.dart';
import 'car_overlay.dart';
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
    this.elevation,
    this.theme,
    this.overlay,
    this.settings,
    MethodChannel? channel,
    Future<String> Function()? glyphs,
    this.ready,
    this.onConnected,
    this.throttle = const Duration(milliseconds: 250),
  })  : _channel = channel ?? const MethodChannel('co.cache/car'),
        _glyphs = glyphs ?? MapAssets.glyphsUrl;

  final NavState nav;
  final MapsState maps;
  final CarDriveSource drive;

  /// The app-level elevation of the route shown (one for the phone's Maps screen and the car); null: the car draws no climb card.
  final RouteElevation? elevation;

  /// The phone's chosen theme (the car picks its day or night one, car_overlay.dart).
  final CacheThemeId Function()? theme;

  /// The two car switches (Settings > Car); null: the defaults. [settings] tells the bridge when they may have changed, so the car
  /// has the new trip within one update.
  final Map<String, bool> Function()? overlay;
  final Listenable? settings;
  final MethodChannel _channel;
  final Future<String> Function() _glyphs;
  final Duration throttle;

  /// Resolves once the search core is open. The car can start Cache with the phone app closed, and asks for saved places at once:
  /// places, search and directions wait for the core (at most [readyWait]) instead of answering empty.
  final Future<void> Function()? ready;
  static const Duration readyWait = Duration(seconds: 30);

  /// Called when a car screen attaches: the app reads a current position (the car may have started Cache with the phone app
  /// closed, when nothing else has read one yet).
  final Future<void> Function()? onConnected;

  Future<void> _ready() async {
    final r = ready;
    if (r == null) return;
    try {
      await r().timeout(readyWait);
    } catch (_) {
      // Not open in time: answer with what there is.
    }
  }

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
    nav.location.addListener(_onLocation);
    elevation?.addListener(_schedule);
    settings?.addListener(_onSettings);
    _lastTheme = theme?.call();
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
    if (_started) nav.location.removeListener(_onLocation);
    elevation?.removeListener(_schedule);
    settings?.removeListener(_onSettings);
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
      _pushedPhase = null;
      _schedule();
      final c = onConnected;
      if (c != null) unawaited(c().catchError((Object _) {}));
      // Saved places the car asked for before the core was open: tell it to ask again once it is.
      unawaited(_ready().then((_) => _send('savedChanged', null)));
    } else {
      // The car went away. A real drive goes on: the phone keeps guiding, and the car shows it again when it connects again
      // (the trip is pushed on connecting). A simulated test drive is the deliberate exception: it exists only for the car
      // (Google's review asks for it through the car), so it ends with the car session and the phone is back on its real
      // position.
      final testDrive = drive.simulating;
      drive.simulate = false;
      if (testDrive && nav.guiding) unawaited(nav.end());
    }
  }

  // ---- pushing to the car ------------------------------------------------------------------------------------

  /// The phase the car was last told.
  NavPhase? _pushedPhase;

  void _schedule() {
    if (!connected.value) return;
    // Guidance starting or ending (or a preview opening or closing) is told at once, whoever ended it (End route on either
    // screen, the car's host, an arrival dismissed): nothing on the car that depends on "guiding" waits for the throttle.
    if (nav.phase != _pushedPhase) {
      _pushTimer?.cancel();
      _pushTimer = null;
      unawaited(push());
      return;
    }
    _pushTimer ??= Timer(throttle, () {
      _pushTimer = null;
      unawaited(push());
    });
  }

  CacheThemeId? _lastTheme;

  /// What makes the car reload its map: the layers it draws (their ids and style signatures) and the pin style; the theme is tracked
  /// on its own ([_onSettings]). The phone's MapsState.styleKey also has each layer's opacity, whether the engine is ready and the
  /// connection count, and those must not reload the car's map: a reconnect would reload it every time the phone regains data, a
  /// not-ready engine has no style to send (the car asks again by itself), and an opacity change waits for the next load (the car
  /// style does draw layers at their opacity; the owner chose not to reload for it).
  String get _carStyleKey => [
        for (final u in maps.uses) u.def.id,
        'pins-${maps.pinStyle.name}',
        for (final l in maps.engine.layers) l.styleSignature,
      ].join(',');

  /// A phone setting changed: a new theme reloads the car's map style (the car asks for it again with the same request it always
  /// uses), and the trip goes out again for the switches and the palette.
  void _onSettings() {
    final t = theme?.call();
    if (t != _lastTheme) {
      _lastTheme = t;
      if (connected.value) unawaited(_send('styleChanged', null));
    }
    _schedule();
  }

  void _onMaps() {
    if (!connected.value) return;
    final key = _carStyleKey;
    if (key == _lastStyleKey) return;
    _lastStyleKey = key;
    unawaited(_send('styleChanged', null));
  }

  /// The phone's position changed. While nothing is guided that position is the car's marker ([snapshot]), and nothing else
  /// tells the car about it: [NavState] does not change when the phone moves. (While guiding, guidance itself changes with
  /// every fix, so the trip goes out from there.)
  void _onLocation() {
    if (!nav.guiding) _schedule();
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
    // The Maps screen asks for the route's profile only while it is shown, so the car asks too (the same route again does nothing).
    elevation?.request(nav.phase == NavPhase.browsing ? null : nav.route);
    return carTrip(nav, position: pos, heading: heading, elevation: elevation?.profile, theme: theme?.call() ?? CacheThemeId.dark, overlay: overlay?.call());
  }

  Future<void> push() async {
    if (!connected.value) return;
    _pushedPhase = nav.phase;
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
    logInfo('Car asks: ${call.method}');
    if (const {'saved', 'search', 'directions', 'navigateTo', 'start'}.contains(call.method)) await _ready();
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
        // The car has the ended trip before this is answered.
        await push();
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
    final palette = mapPaletteFor(carMapTheme(dark: dark, chosen: theme?.call() ?? CacheThemeId.dark));
    final String glyphs;
    try {
      glyphs = await _glyphs();
    } catch (_) {
      return null;
    }
    _lastStyleKey = _carStyleKey;
    return {
      'style': await maps.styleJson(palette, glyphs),
      'colors': {for (final r in const ['route', 'routeCasing', 'routeOffroad', 'routeAlternate', 'position', 'positionRing', 'pin']) r: palette.css(r)},
    };
  }

  /// The saved places, as places to go to.
  Future<List<MapPlace>> savedPlaces() async {
    try {
      final saved = await nav.backend.savedPlaces();
      logInfo('Car: ${saved.length} saved places');
      return [for (final s in saved) _savedPlace(s)];
    } catch (e, st) {
      logError('Car: saved places could not be read', error: e, stack: st);
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

  /// Saved places whose name is the query come first, then the map search by name, address and category word only: the car never
  /// asks for a query vector, so the search model is not loaded for it (owner's decision). The phone's own search panel is left as
  /// it is. Every car search path (the car's search box, a name in a navigation request) comes through here.
  Future<List<MapPlace>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final saved = [for (final s in await savedPlaces()) if (s.name.toLowerCase() == q.toLowerCase()) s];
    List<MapPlace> found = const [];
    try {
      final r = await nav.backend.search(q, near: nav.here, limit: 10, meaning: false);
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
