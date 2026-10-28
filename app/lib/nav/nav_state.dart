import 'notification_access.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../location/coords.dart';
import '../chat/navigation_action.dart';
import '../location/location_service.dart';
import '../location/position_source.dart';
import '../maps/maps_state.dart';
import 'guidance.dart';
import 'nav_backend.dart';
import 'nav_position.dart';
import 'speaker.dart';
import 'units.dart';

/// What the Maps tab is doing about getting somewhere.
enum NavPhase {
  /// Looking at the map; maybe a place is selected.
  browsing,

  /// A route is drawn and the person is choosing how to go.
  previewing,

  /// Turn by turn.
  guiding,
}

/// Something the rest of the app may want to hear about.
sealed class NavEvent {
  const NavEvent();
}

/// "Add to Home" was tapped on a place card. Nothing listens yet: Home gets its shortcuts later.
class AddToHomeRequested extends NavEvent {
  const AddToHomeRequested(this.place);
  final MapPlace place;
}

class PlaceSaved extends NavEvent {
  const PlaceSaved(this.place);
  final MapPlace place;
}

class NavNotice extends NavEvent {
  const NavNotice(this.text);
  final String text;
}

/// Search, selection, directions and guidance of the Maps tab. The screens read it; the core and the phone's position and
/// speech are behind seams, so all of it is tested with fakes.
class NavState extends ChangeNotifier {
  NavState({
    required this.backend,
    required this.location,
    required this.speaker,
    required this.positionSource,
    required this.fmt,
    this.onFollow,
    this.notifications,
    DateTime Function()? clock,
    this.searchDebounce = const Duration(milliseconds: 220),
    this.meaningDebounce = const Duration(milliseconds: 700),
    this.rerouteCooldown = const Duration(seconds: 8),
  }) : _clock = clock ?? DateTime.now;

  final MapBackend backend;
  final LocationService location;
  final Speaker speaker;
  final NavPositionSource positionSource;
  final Fmt fmt;
  final Duration searchDebounce;
  final Duration meaningDebounce;
  final Duration rerouteCooldown;
  final DateTime Function() _clock;

  /// Asked for the notification permission when guidance starts (null: not asked), so the ongoing guidance notification shows.
  final NotificationAccess? notifications;

  /// Called to change how the camera follows the phone (guidance turns the map to the heading).
  final void Function(FollowMode mode)? onFollow;

  NavPhase phase = NavPhase.browsing;

  // ---- search ----------------------------------------------------------------------------------------------

  /// What the search field says.
  String query = '';
  bool searching = false;
  List<MapPlace> results = const [];

  /// Why the answer is what it is: "Searching by keywords only" when meaning search could not run, or null.
  String? searchNote;

  /// The last search was by keywords only because the search model is missing ("Meaning search needs the search model").
  bool searchNeedsModel = false;
  String? searchError;
  bool searchOpen = false;
  int _searchSeq = 0;
  Timer? _searchTimer;
  Timer? _meaningTimer;

  /// Where the map is looking: results are ranked from here.
  GeoPoint? mapCentre;

  // ---- the selected place ------------------------------------------------------------------------------------

  MapPlace? selected;

  /// The selected place is a dropped pin.
  bool get selectedIsPin => selected?.matched == 'pin';
  final StreamController<NavEvent> _events = StreamController<NavEvent>.broadcast();
  Stream<NavEvent> get events => _events.stream;

  // ---- directions ---------------------------------------------------------------------------------------------

  String mode = 'drive';
  bool routing = false;
  String? routeError;

  /// The best route and its alternatives; [routeIndex] is the one chosen.
  List<MapRoute> routes = const [];
  int routeIndex = 0;
  MapRoute? get route => routes.isEmpty ? null : routes[routeIndex.clamp(0, routes.length - 1)];
  GeoPoint? _routeFrom;
  int _routeSeq = 0;

  // ---- guidance ----------------------------------------------------------------------------------------------

  MapProgress? progress;
  bool voiceOn = true;
  bool rerouting = false;
  bool arrived = false;
  Fix? lastFix;
  GuidanceEngine? _engine;
  StreamSubscription<Fix>? _fixSub;
  bool _busyProgress = false;
  Fix? _pendingFix;
  bool _sendRoute = true;
  DateTime? _lastReroute;
  bool _routeStarted = false;

  bool get available => backend.available;
  bool get guiding => phase == NavPhase.guiding;

  Fix? get fix => location.fix;

  /// The point directions start from: the phone's position.
  GeoPoint? get here => (lastFix ?? location.fix) == null ? null : GeoPoint((lastFix ?? location.fix)!.lat, (lastFix ?? location.fix)!.lon);

  // ---- search ------------------------------------------------------------------------------------------------

  void setMapCentre(double lat, double lon) => mapCentre = GeoPoint(lat, lon);

  void openSearch() {
    if (searchOpen) return;
    searchOpen = true;
    notifyListeners();
  }

  void closeSearch({bool clear = true}) {
    _searchTimer?.cancel();
    _meaningTimer?.cancel();
    _searchSeq++;
    searchOpen = false;
    searching = false;
    if (clear) {
      query = '';
      results = const [];
      searchNote = null;
      searchNeedsModel = false;
      searchError = null;
    }
    notifyListeners();
  }

  /// The field changed: show the fast answer (names, categories, coordinates) soon, and the answer by meaning when typing
  /// pauses.
  void onQueryChanged(String text) {
    query = text;
    searchOpen = true;
    _searchTimer?.cancel();
    _meaningTimer?.cancel();
    if (text.trim().isEmpty) {
      _searchSeq++;
      results = const [];
      searching = false;
      searchNote = null;
      searchNeedsModel = false;
      searchError = null;
      notifyListeners();
      return;
    }
    searching = true;
    notifyListeners();
    _searchTimer = Timer(searchDebounce, () => _runSearch(text, meaning: false));
    _meaningTimer = Timer(meaningDebounce, () => _runSearch(text, meaning: true));
  }

  /// The keyboard's search key: run the full search now.
  Future<void> submitSearch() {
    _searchTimer?.cancel();
    _meaningTimer?.cancel();
    return _runSearch(query, meaning: true);
  }

  Future<void> _runSearch(String text, {required bool meaning}) async {
    if (text.trim().isEmpty) return;
    final seq = ++_searchSeq;
    searching = true;
    try {
      final r = await backend.search(text, near: mapCentre ?? here, limit: 10, meaning: meaning);
      if (seq != _searchSeq) return;
      results = r.results;
      searchError = null;
      final words = meaning && r.kind == 'text';
      // No query vector came with the search: the search model is not on this phone.
      searchNeedsModel = words && r.meaning == 'no_embedder' && r.warning == null;
      searchNote = words && (r.meaning == 'no_vectors' || r.meaning == 'model_mismatch')
          ? 'Matching words only: the meaning search is not available'
          : null;
      if (r.warning != null) searchNote = r.warning;
    } catch (e) {
      if (seq != _searchSeq) return;
      searchError = e is CacheSearchException ? e.message : 'Search failed';
      results = const [];
      searchNeedsModel = false;
    } finally {
      if (seq == _searchSeq) searching = false;
      notifyListeners();
    }
  }

  // ---- the selected place ------------------------------------------------------------------------------------

  /// A result was tapped. A category row lists that kind of place instead of choosing one.
  void select(MapPlace p) {
    if (p.isCategory) {
      query = p.name;
      onQueryChanged(p.name);
      return;
    }
    selected = p;
    searchOpen = false;
    query = p.name;
    notifyListeners();
  }

  /// A long press on the map: a pin with its coordinates now, and the rest (grid and Plus Code, the nearest town) as soon as
  /// the core has them.
  Future<void> dropPin(double lat, double lon) async {
    final base = MapPlace.pin(lat, lon, formats: {'decimal': formatDecimal(lat, lon), 'dms': formatDms(lat, lon)});
    selected = base;
    searchOpen = false;
    notifyListeners();
    try {
      final r = await backend.search('${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}', near: here, limit: 1, meaning: false);
      final c = r.results.where((x) => x.isCoordinates).firstOrNull;
      if (c != null && selected?.id == base.id) {
        selected = MapPlace(
          id: base.id,
          type: 'coordinates',
          name: 'Dropped pin',
          kind: 'Coordinates',
          address: c.address,
          lat: lat,
          lon: lon,
          matched: 'pin',
          formats: {...base.formats, ...c.formats},
        );
        notifyListeners();
      }
    } catch (_) {
      // The pin keeps its two local formats.
    }
  }

  void clearSelection() {
    if (phase != NavPhase.browsing) return;
    selected = null;
    notifyListeners();
  }

  /// Metres from the phone to [p], or null when the position is not known.
  double? distanceFromHere(MapPlace p) {
    final h = here;
    if (h == null) return null;
    return _haversineM(h.lat, h.lon, p.lat, p.lon);
  }

  Future<void> savePlace(MapPlace p) async {
    try {
      await backend.savePlace(name: p.name, lat: p.lat, lon: p.lon, label: p.address.isEmpty ? null : p.address);
      _events.add(PlaceSaved(p));
    } catch (e) {
      _events.add(NavNotice(e is CacheSearchException && e.code == 'unsupported' ? 'Saving places is not available yet' : 'Could not save the place'));
    }
  }

  void addToHome(MapPlace p) => _events.add(AddToHomeRequested(p));

  // ---- directions --------------------------------------------------------------------------------------------

  /// Load the assistant's retained route exactly. Guidance needs a separate Start tap.
  /// Active guidance is never replaced; the shell explains the conflict.
  bool previewSnapshot(MapRoute snapshot) {
    if (guiding || !NavigationAction.usable('nav:${snapshot.routeId}', snapshot)) return false;
    _routeSeq++;
    closeSearch();
    final end = snapshot.destination;
    selected = MapPlace(id: (snapshot.to['id'] as String?) ?? 'nav:${snapshot.routeId}',
        type: 'place', name: snapshot.destinationName, kind: '', address: '',
        lat: end.lat, lon: end.lon, matched: 'route');
    routes = [snapshot];
    routeIndex = 0;
    mode = snapshot.mode;
    _routeFrom = GeoPoint((snapshot.from['lat'] as num).toDouble(), (snapshot.from['lon'] as num).toDouble());
    routeError = null;
    routing = false;
    progress = null;
    arrived = false;
    _sendRoute = true;
    phase = NavPhase.previewing;
    notifyListeners();
    return true;
  }

  /// Directions from the phone's position to [to].
  Future<void> openDirections(MapPlace to) async {
    selected = to;
    phase = NavPhase.previewing;
    searchOpen = false;
    notifyListeners();
    await _fetchRoutes();
  }

  Future<void> setMode(String m) async {
    if (m == mode) return;
    mode = m;
    notifyListeners();
    if (phase == NavPhase.previewing) await _fetchRoutes();
  }

  void selectRoute(int i) {
    if (i < 0 || i >= routes.length || i == routeIndex) return;
    routeIndex = i;
    notifyListeners();
  }

  Future<void> _fetchRoutes() async {
    final to = selected;
    final from = here;
    if (to == null) return;
    final seq = ++_routeSeq;
    routes = const [];
    routeIndex = 0;
    routeError = null;
    if (from == null) {
      routeError = 'Your position is not known yet. Turn on location to get directions from where you are.';
      notifyListeners();
      return;
    }
    routing = true;
    _routeFrom = from;
    notifyListeners();
    try {
      final r = await backend.route(from: {'lat': from.lat, 'lon': from.lon, 'name': 'Your location'}, to: to.toEnd(), mode: mode, alternatives: 2);
      if (seq != _routeSeq) return;
      if (!r.ok) {
        routeError = routeErrorText(r);
      } else {
        routes = [r, ...r.alternatives];
        if (r.warnings.any((w) => w.code == 'offroad_unavailable')) {
          _events.add(const NavNotice('Part of this trip is off the roads, and the off-road map data is not on this phone'));
        }
      }
    } catch (e) {
      if (seq != _routeSeq) return;
      routeError = e is CacheSearchException ? (e.code == 'unsupported' ? 'Directions are not available in this build yet' : e.message) : 'Could not get directions';
    } finally {
      if (seq == _routeSeq) routing = false;
      notifyListeners();
    }
  }

  /// A route the core could not make, in words for people.
  static String routeErrorText(MapRoute r) {
    final code = r.errors.isEmpty ? 'internal' : r.errors.first.code;
    return switch (code) {
      'no_route' => 'No way found between these places',
      'too_far' => 'These places are too far apart for one trip',
      'out_of_coverage' => 'One of these places is outside the downloaded maps',
      'route_too_long' => 'The off-road part of this trip is too long to work out',
      'upstream_timeout' => 'Working out the route took too long. Try again',
      _ => 'Could not get directions',
    };
  }

  /// Back from the preview to looking at the map (the place stays selected).
  void cancelDirections() {
    _routeSeq++;
    phase = NavPhase.browsing;
    routes = const [];
    routeError = null;
    routing = false;
    notifyListeners();
  }

  // ---- guidance ----------------------------------------------------------------------------------------------

  /// Start turn-by-turn on the chosen route.
  Future<void> start() async {
    final r = route;
    if (r == null || phase != NavPhase.previewing) return;
    phase = NavPhase.guiding;
    arrived = false;
    rerouting = false;
    progress = null;
    _sendRoute = true;
    _routeStarted = false;
    _lastReroute = null;
    _engine = GuidanceEngine(fmt: fmt, mode: r.mode, destination: r.destinationName);
    onFollow?.call(FollowMode.headingUp);
    notifyListeners();
    final name = r.destinationName.isEmpty ? 'your destination' : r.destinationName;
    // Android 13 and later show the guidance notification only once the user has allowed notifications. Asked here, with
    // the app on screen; a refusal does not stop guidance (the position service still runs).
    if (notifications != null) {
      try {
        await notifications!.request();
      } catch (_) {}
      if (phase != NavPhase.guiding) return; // ended while the prompt was up
    }
    location.holdStream(true);
    if (phase != NavPhase.guiding) {
      location.holdStream(false);
      return;
    }
    _fixSub = positionSource.start(title: 'Cache navigation', text: 'Guiding you to $name').listen(_onFix);
    // The first fix may already be known; the stream gives the next ones.
    final f = location.fix;
    if (f != null) unawaited(_handleFix(f));
  }

  void _onFix(Fix f) {
    location.publish(f);
    unawaited(_handleFix(f));
  }

  /// Feeds a fix to guidance. Updates are one at a time: a fix that arrives while the core is busy replaces the one waiting.
  Future<void> _handleFix(Fix f) async {
    if (!guiding) return;
    lastFix = f;
    if (_busyProgress) {
      _pendingFix = f;
      return;
    }
    _busyProgress = true;
    try {
      Fix? cur = f;
      while (cur != null && guiding) {
        _pendingFix = null;
        await _progressFor(cur);
        cur = _pendingFix;
      }
    } finally {
      _busyProgress = false;
    }
  }

  Future<void> _progressFor(Fix f) async {
    final r = route;
    if (r == null || !guiding) return;
    try {
      final p = await backend.progress(r, lat: f.lat, lon: f.lon, accuracyM: f.accuracyM, now: _clock(), sendRoute: _sendRoute);
      _sendRoute = false;
      if (!guiding || route?.routeId != r.routeId) return;
      progress = p;
      if (!_routeStarted) {
        _routeStarted = true;
        _say(_engine!.opening(r, p.current));
      }
      for (final line in _engine!.update(p)) {
        _say(line);
      }
      if (p.arrived) {
        arrived = true;
        notifyListeners();
        return;
      }
      if (p.offRoute) await _reroute(f);
      notifyListeners();
    } catch (e) {
      // A bad update is skipped; the next fix tries again. A core that lost the route is sent it again.
      if (e is CacheSearchException && e.code == 'not_found') _sendRoute = true;
    }
  }

  Future<void> _reroute(Fix f) async {
    final now = _clock();
    if (rerouting || (_lastReroute != null && now.difference(_lastReroute!) < rerouteCooldown)) return;
    final old = route;
    final to = selected;
    if (old == null || to == null) return;
    rerouting = true;
    _lastReroute = now;
    notifyListeners();
    _say('Rerouting.');
    try {
      final r = await backend.route(from: {'lat': f.lat, 'lon': f.lon, 'name': 'Your location'}, to: to.toEnd(), mode: mode, alternatives: 0);
      if (!guiding) return;
      if (r.ok) {
        routes = [r];
        routeIndex = 0;
        _routeFrom = GeoPoint(f.lat, f.lon);
        _sendRoute = true;
        _routeStarted = true;
        _engine = GuidanceEngine(fmt: fmt, mode: r.mode, destination: r.destinationName);
        progress = null;
      } else {
        _events.add(NavNotice(routeErrorText(r)));
      }
    } catch (_) {
      _events.add(const NavNotice('Could not work out a new route'));
    } finally {
      rerouting = false;
      notifyListeners();
    }
  }

  void _say(String text) {
    if (voiceOn) unawaited(speaker.speak(text));
  }

  void toggleVoice() {
    voiceOn = !voiceOn;
    if (!voiceOn) unawaited(speaker.stop());
    notifyListeners();
  }

  /// End guidance: stop the position service and the voice, back to the map with the place still selected.
  Future<void> end() async {
    if (!guiding) return;
    await _fixSub?.cancel();
    _fixSub = null;
    await positionSource.stop();
    location.holdStream(false);
    await speaker.stop();
    phase = NavPhase.browsing;
    routes = const [];
    progress = null;
    arrived = false;
    rerouting = false;
    onFollow?.call(FollowMode.follow);
    notifyListeners();
  }

  /// Done with the place too: clear everything.
  Future<void> finish() async {
    await end();
    selected = null;
    notifyListeners();
  }

  GeoPoint? get routeStart => _routeFrom;

  @override
  void dispose() {
    _searchTimer?.cancel();
    _meaningTimer?.cancel();
    _fixSub?.cancel();
    positionSource.stop();
    location.holdStream(false);
    _events.close();
    super.dispose();
  }
}

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}
