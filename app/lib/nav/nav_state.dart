import 'dart:async';
import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../car/car_overlay.dart' show pointAtFraction;
import '../location/coords.dart';
import '../chat/navigation_action.dart';
import '../location/location_service.dart';
import '../location/position_source.dart';
import '../maps/geo.dart';
import '../maps/maps_state.dart';
import '../platform/app_log.dart';
import 'eta_blend.dart';
import 'guidance.dart';
import 'nav_backend.dart';
import 'nav_position.dart';
import 'saved_first.dart';
import 'speaker.dart';
import 'travel_prefs.dart';
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

/// What places data the last map search had (cs_map_search's `warning_code`).
enum PlacesState {
  /// Nothing to say.
  ok,

  /// No places are on the phone, and none could be fetched.
  none,

  /// Places are on the phone, but not for the area searched.
  notHere,

  /// Places for the area searched are on their way; the search runs again when they land.
  fetching,
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

/// A saved place was removed from its place card (the app stops watching it).
class PlaceRemoved extends NavEvent {
  const PlaceRemoved(this.key);
  final String key;
}

/// Something outside the map (the assistant's navigation.start) wants the Maps tab on screen.
class MapRequested extends NavEvent {
  const MapRequested();
}

/// What the Maps tab is asked to show ([NavState.mapShow]): a spot, the whole route, or an area fitted in view ([area]: a region,
/// a layer's downloaded area, asked through [MapsState.showAreaOnMap]).
class MapShow {
  const MapShow({this.at, this.route = false, this.area});

  final GeoPoint? at;
  final bool route;
  final GeoBounds? area;
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
    this.simulatedDrive,
    DateTime Function()? clock,
    this.searchDebounce = const Duration(milliseconds: 220),
    this.meaningDebounce = const Duration(milliseconds: 700),
    this.rerouteCooldown = const Duration(seconds: 8),
    this.guidanceLogEvery,
    this.rerouteTimeout = const Duration(seconds: 25),
    this.arrivalEndAfter = const Duration(minutes: 5),
    this.prefs,
  }) : _clock = clock ?? DateTime.now {
    location.addListener(_onLocation);
    restored = _restore();
  }

  /// Where the way of travel and its options are remembered across restarts; null remembers nothing (tests).
  final TravelPrefs? prefs;

  /// Completes when what was remembered has been read and applied (immediately when nothing is remembered).
  late final Future<void> restored;

  final MapBackend backend;
  final LocationService location;
  final Speaker speaker;
  final NavPositionSource positionSource;
  final Fmt fmt;
  final Duration searchDebounce;
  final Duration meaningDebounce;
  final Duration rerouteCooldown;

  /// How often guidance writes its one line to the app log (fixes, the last progress answer, failures) while it runs; the
  /// app gives one minute. Null: no timer, only the line written when guidance lets go of the position service.
  final Duration? guidanceLogEvery;

  /// How long a re-route waits for the core before it is given up (see [_reroute]).
  final Duration rerouteTimeout;

  /// How long after arrival guidance ends by itself if End is not tapped ([_armArrivalEnd]); the app keeps five minutes.
  /// Settable so a test can make it short.
  Duration arrivalEndAfter;
  final DateTime Function() _clock;

  /// Called to change how the camera follows the phone (guidance turns the map to the heading).
  final void Function(FollowMode mode)? onFollow;

  /// True while [positionSource] gives a simulated drive (the car's test drive): the phone's last real fix is then not fed to
  /// guidance when it starts, so the drive is not taken off its route by where the phone really is.
  final bool Function()? simulatedDrive;

  NavPhase phase = NavPhase.browsing;

  // ---- search ----------------------------------------------------------------------------------------------

  /// What the search field says.
  String query = '';
  bool searching = false;
  List<MapPlace> results = const [];

  /// Why the answer is what it is: "Searching by keywords only" when meaning search could not run, or null.
  String? searchNote;

  String? searchError;

  /// What places data the last search had.
  PlacesState placesState = PlacesState.ok;
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

  /// The engine's id of the way of travel being routed: drive, walk, bike, offroad_foot (Walk > Off-road), offroad_moto (Bike >
  /// Dirt bike), offroad_4w (ATV > Quad), offroad_sxs (ATV > Side-by-side), or offroad_vehicle (a route the assistant planned,
  /// which no choice on the screen is). Only the first five of the assistant's ids reach it from outside ([previewSnapshot]); the
  /// others pass between this screen and the engine.
  String mode = 'drive';

  /// How an off-road route treats land the data marks private or closed: strict (only the assistant plans that; no choice on the
  /// screen is highlighted), pragmatic (the default; Standard on the screen) or emergency. Sent only with an off-road mode; drive,
  /// walk and bike keep the core's default.
  String landAccess = 'pragmatic';

  /// Drive's two toggles: avoid highways, avoid tolls (avoided where there is a reasonable way round). Sent only with Drive.
  bool avoidHighways = false;
  bool avoidTolls = false;

  // The option each way of travel comes back to when it is chosen again (Walk's Off-road, Bike's Dirt bike, ATV's Side-by-side).
  bool _walkOffroad = false;
  bool _bikeDirt = false;
  bool _atvSideBySide = false;

  // What is remembered: the person's last choices (never an assistant route's mode or strict land access).
  String _keptMode = 'drive';
  String _keptLand = 'pragmatic';
  bool _touched = false;

  /// The way of travel is one of the off-road modes (they leave the roads: Walk > Off-road, Bike > Dirt bike, ATV, and the
  /// assistant's offroad_vehicle).
  bool get offroad => isOffroadMode(mode);
  static const offroadModes = ['offroad_foot', 'offroad_vehicle', 'offroad_moto', 'offroad_4w', 'offroad_sxs'];
  static bool isOffroadMode(String m) => offroadModes.contains(m);

  /// The first row's choice of the screen for an engine id: `drive`, `walk`, `bike` or `atv`; null for offroad_vehicle (no choice
  /// is highlighted).
  static String? travelOf(String m) => switch (m) {
        'drive' => 'drive',
        'walk' || 'offroad_foot' => 'walk',
        'bike' || 'offroad_moto' => 'bike',
        'offroad_4w' || 'offroad_sxs' => 'atv',
        _ => null,
      };

  /// The way of travel highlighted in the first row ([travelOf] of [mode]).
  String? get travel => travelOf(mode);

  /// The engine id of a first-row choice, with the option that choice was last set to.
  String modeFor(String travel) => switch (travel) {
        'walk' => _walkOffroad ? 'offroad_foot' : 'walk',
        'bike' => _bikeDirt ? 'offroad_moto' : 'bike',
        'atv' => _atvSideBySide ? 'offroad_sxs' : 'offroad_4w',
        _ => 'drive',
      };

  /// Whether the Standard / Emergency row is shown: where land rules mean something (the off-road modes).
  bool get showsLandRow => offroad;

  bool routing = false;
  String? routeError;

  /// True when the off-road route failed because the area has no off-road data (the panel offers Walk and Drive).
  bool offroadDataMissing = false;

  /// True when the route failed because a place of it is outside the downloaded maps (the panel offers Download this area).
  bool outsideMaps = false;

  /// The best route and its alternatives; [routeIndex] is the one chosen.
  List<MapRoute> routes = const [];
  int routeIndex = 0;
  MapRoute? get route => routes.isEmpty ? null : routes[routeIndex.clamp(0, routes.length - 1)];
  GeoPoint? _routeFrom;
  int _routeSeq = 0;

  /// Where directions start when it is not the phone: a spot held on the map (the ring's From here). Null = the phone.
  MapPlace? fromPlace;

  /// The stops on the way, in order (the ring's Add stop, while a route is shown); the router goes through each.
  List<MapPlace> stops = const [];

  /// The most stops a route has.
  static const int maxStops = 10;
  final Set<int> _passedStops = {};

  /// The stops the route being followed goes through, in its order, as places in [stops]: the route's first stop is
  /// `_routeStops[0]`, and so on. The core counts the stops the fixes have reached along the route ([MapProgress.stopsReached]);
  /// this says which stops those are.
  List<int> _routeStops = const [];

  /// From here: directions will start at [p]. The search opens to choose where to go (or hold the map for To here).
  void setFrom(MapPlace p) {
    fromPlace = p;
    stops = const [];
    if (phase == NavPhase.previewing && selected != null) {
      notifyListeners();
      unawaited(_fetchRoutes());
      return;
    }
    openSearch();
    notifyListeners();
  }

  /// Directions start at the phone again.
  void clearFrom() {
    if (fromPlace == null) return;
    fromPlace = null;
    notifyListeners();
    if (phase == NavPhase.previewing) unawaited(_fetchRoutes());
  }

  /// Add stop: [p] joins the route shown, after the stops it has. False when no route is shown or it has [maxStops].
  Future<bool> addStop(MapPlace p) async {
    if (phase != NavPhase.previewing || selected == null) return false;
    if (stops.length >= maxStops) {
      _events.add(const NavNotice('A route has at most 10 stops'));
      return false;
    }
    stops = [...stops, p];
    notifyListeners();
    await _fetchRoutes();
    return true;
  }

  /// The stops still ahead, in order: all of them before the drive, and while guiding those not passed yet. (A stop counts as
  /// passed only during the drive it was passed in.)
  List<MapPlace> get stopsAhead => !guiding
      ? stops
      : [
          for (final (i, s) in stops.indexed)
            if (!_passedStops.contains(i)) s,
        ];

  /// The stops still ahead with the number each has in the route being followed: the number the turn banner says when the
  /// stop is reached ("Stop 2 reached"), which is its place among the stops that route was made with. A stop keeps that number
  /// when the ones before it are passed. Before the drive it is its place among all the stops.
  List<(int, MapPlace)> get numberedStopsAhead {
    if (!guiding) return [for (final (i, s) in stops.indexed) (i + 1, s)];
    final out = <(int, MapPlace)>[];
    for (final (k, i) in _routeStops.indexed) {
      if (i < stops.length && !_passedStops.contains(i)) out.add((k + 1, stops[i]));
    }
    // A stop the route was not made with (there should be none) still shows, after the others.
    for (final i in _aheadIndexes()) {
      if (!_routeStops.contains(i)) out.add((out.length + 1, stops[i]));
    }
    return out;
  }

  /// The stops the route being followed goes through, in its order, each with the number [numberedStopsAhead] gives it (its place
  /// among that route's stops, the number the turn banner says), passed ones included: the n-th stop maneuver of the route is
  /// the n-th of these. The drive screen's list reads its stop rows from here.
  List<(int, MapPlace)> get routeStopsInOrder => [
        for (final (k, i) in _routeStops.indexed)
          if (i < stops.length) (k + 1, stops[i]),
      ];

  /// The places in [stops] that are not passed, in order: what a route from here goes through.
  List<int> _aheadIndexes() => [
        for (var i = 0; i < stops.length; i++)
          if (!_passedStops.contains(i)) i,
      ];

  /// Add stop while guiding (the car's Add stop during a drive): [p] becomes the next stop, before the stops still ahead, and
  /// guidance carries on along a new route from where the phone is, through it and the other stops ahead, to the destination.
  /// False, with the route as it was, when there is no guidance to add to (not guiding, arrived, no fix yet, a new route
  /// already being worked out), when the route has [maxStops], or when no route through the stop could be found.
  Future<bool> addStopWhileGuiding(MapPlace p) async {
    final f = lastFix;
    final to = selected;
    if (!guiding || arrived || rerouting || f == null || to == null || route == null) return false;
    if (stops.length >= maxStops) {
      _events.add(const NavNotice('A route has at most 10 stops'));
      return false;
    }
    final before = stops;
    final beforePassed = {..._passedStops};
    final passed = [
      for (final (i, s) in stops.indexed)
        if (_passedStops.contains(i)) s,
    ];
    // The stops already passed keep their places at the front, so each stop keeps its number.
    final beforeRoute = _routeStops;
    stops = [...passed, p, ...stopsAhead];
    _passedStops
      ..clear()
      ..addAll([for (var i = 0; i < passed.length; i++) i]);
    _rerouteGen++;
    rerouting = true;
    _reroutingSince = _clock();
    _lastReroute = _clock();
    notifyListeners();
    var added = false;
    try {
      final r = await backend.route(
          from: {'lat': f.lat, 'lon': f.lon, 'name': 'Your location'}, to: to.toEnd(), via: _via(skipPassed: true), mode: mode, landAccess: offroad ? landAccess : null, alternatives: 0,
          avoidHighways: _sendAvoidHighways, avoidTolls: _sendAvoidTolls);
      if (!guiding) return false;
      if (r.ok) {
        routes = [r];
        routeIndex = 0;
        _routeFrom = GeoPoint(f.lat, f.lon);
        _sendRoute = true;
        _routeStarted = true;
        _engine = GuidanceEngine(fmt: fmt, mode: r.mode, destination: r.destinationName);
        progress = null;
        _routeStops = _aheadIndexes();
        added = true;
        logInfo('Guidance: a stop was added, the new route goes through ${stopsAhead.length} of ${stops.length} stops');
      } else {
        _events.add(NavNotice(routeErrorText(r)));
      }
    } catch (_) {
      _events.add(const NavNotice('Could not work out a new route'));
    } finally {
      if (!added && guiding) {
        stops = before;
        _routeStops = beforeRoute;
        _passedStops
          ..clear()
          ..addAll(beforePassed);
      }
      rerouting = false;
      _reroutingSince = null;
      notifyListeners();
    }
    return added;
  }

  Future<void> removeStop(int i) async {
    if (i < 0 || i >= stops.length) return;
    stops = [...stops]..removeAt(i);
    notifyListeners();
    if (phase == NavPhase.previewing) await _fetchRoutes();
  }

  /// Move the stop at [from] to the place [to] in the list (the place it ends up in, after it is taken out). The route is worked
  /// out again at once, as after [removeStop]. Not while guiding, and a move to the same place or out of range changes nothing.
  Future<void> reorderStop(int from, int to) async {
    if (guiding || from == to || from < 0 || to < 0 || from >= stops.length || to >= stops.length) return;
    final next = [...stops];
    next.insert(to, next.removeAt(from));
    stops = next;
    notifyListeners();
    if (phase == NavPhase.previewing) await _fetchRoutes();
  }

  List<Map<String, dynamic>> _via({bool skipPassed = false}) => [
        for (final (i, s) in stops.indexed)
          if (!skipPassed || !_passedStops.contains(i)) s.toEnd(),
      ];

  // ---- guidance ----------------------------------------------------------------------------------------------

  MapProgress? progress;

  /// The time left that the phone and the car show, in seconds: the plan's time left ([MapProgress.remainingS]) with the pace
  /// the drive has kept blended in (eta_blend.dart). The plan's own while there is no blended value for this [progress].
  int? get leftS {
    final p = progress;
    if (p == null) return null;
    return identical(p, _blendFor) ? (_blendLeft ?? p.remainingS) : p.remainingS;
  }

  final EtaBlend _blend = EtaBlend();
  MapProgress? _blendFor;
  int? _blendLeft;

  bool voiceOn = true;
  bool rerouting = false;
  bool arrived = false;

  /// The last fix guidance was given. Kept only while guidance follows the phone: it is forgotten when guidance ends, so it
  /// never stands in for the phone's position afterwards.
  Fix? lastFix;
  GuidanceEngine? _engine;

  /// How far (metres) from a maneuver the first (far) voice prompt is due, for the way of travel: the lane strip shows from here.
  double? get farStageM => _engine?.stages.first;
  StreamSubscription<Fix>? _fixSub;
  bool _busyProgress = false;
  Fix? _pendingFix;
  bool _sendRoute = true;
  DateTime? _lastReroute;
  bool _routeStarted = false;

  /// The route's time and distance in the words the opening line uses, while guidance runs; null when there is no route.
  String? get routeSummary {
    final r = route, e = _engine;
    return r == null || e == null || !guiding ? null : e.summary(r);
  }

  /// The opening line of the guidance just started is not spoken (see [start]).
  bool _quietOpening = false;

  bool get available => backend.available;
  bool get guiding => phase == NavPhase.guiding;

  Fix? get fix => location.fix;

  /// The point directions start from: the phone's position. While guiding that is the fix guidance last had; at any other time
  /// it is the position the phone has now, never the last fix of a trip that is over.
  GeoPoint? get here {
    final f = (guiding ? lastFix : null) ?? location.fix;
    return f == null ? null : GeoPoint(f.lat, f.lon);
  }

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
      searchError = null;
      placesState = PlacesState.ok;
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
      searchError = null;
      placesState = PlacesState.ok;
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
    // The saved places that match come first (saved_first.dart), and stay when the place search fails.
    var saved = const <MapPlace>[];
    try {
      saved = [for (final s in await backend.savedPlaces()) savedAsPlace(s)];
    } catch (_) {
      // An old core without saved places: the place search alone.
    }
    try {
      final r = await backend.search(text, near: mapCentre ?? here, limit: 10, meaning: meaning);
      if (seq != _searchSeq) return;
      results = savedFirst(text, saved, r.results);
      searchError = null;
      final words = meaning && r.kind == 'text';
      searchNote = words && (r.meaning == 'no_vectors' || r.meaning == 'model_mismatch')
          ? 'Matching words only: the meaning search is not available'
          : null;
      placesState = switch (r.warningCode) {
        'no_places' => PlacesState.none,
        'not_here' => PlacesState.notHere,
        'fetching' => PlacesState.fetching,
        _ => PlacesState.ok,
      };
      // The places states have their own lines; the free-text warning is for a core older than them.
      if (r.warning != null && r.warningCode == null) searchNote = r.warning;
    } catch (e) {
      if (seq != _searchSeq) return;
      searchError = e is CacheSearchException ? e.message : 'Search failed';
      results = savedFirst(text, saved, const []);
      placesState = PlacesState.ok;
    } finally {
      if (seq == _searchSeq) searching = false;
      notifyListeners();
    }
  }

  /// The places on the phone changed (a region's tiles were merged or removed): the open search runs again.
  Future<void> placesChanged() async {
    if (!searchOpen || query.trim().isEmpty) return;
    await _runSearch(query, meaning: true);
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
    refreshSaved();
  }

  /// A long press on the map: a pin with its coordinates now, and the rest (grid and Plus Code, the nearest town) as soon as
  /// the core has them.
  Future<void> dropPin(double lat, double lon) async {
    final base = MapPlace.pin(lat, lon, name: pinName(lat, lon), formats: {'decimal': formatDecimal(lat, lon), 'dms': formatDms(lat, lon)});
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
          name: base.name,
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
    await refreshSaved();
  }

  List<SavedPlaceRecord> _saved = const [];

  /// Reads the saved places again, so a place card knows whether its place is saved.
  Future<void> refreshSaved() async {
    try {
      final saved = await backend.savedPlaces();
      if (_disposed) return;
      _saved = saved;
      notifyListeners();
    } catch (_) {
      // An old core without saved places: every card offers Save place.
    }
  }

  /// The saved place [p] is (the same name at the same position), or null.
  SavedPlaceRecord? savedFor(MapPlace p) =>
      _saved.where((s) => s.name == p.name && (s.lat - p.lat).abs() < 1e-6 && (s.lon - p.lon).abs() < 1e-6).firstOrNull;

  /// Removes a saved place; the app stops watching it (see [PlaceRemoved]).
  Future<void> removePlace(SavedPlaceRecord s) async {
    try {
      await backend.deletePlace(s.key);
      _events.add(PlaceRemoved(s.key));
    } catch (_) {
      _events.add(const NavNotice('Could not remove the place'));
    }
    await refreshSaved();
  }

  void addToHome(MapPlace p) => _events.add(AddToHomeRequested(p));

  void requestMap() => _events.add(const MapRequested());

  // ---- showing a spot on the map -----------------------------------------------------------------------------

  /// What something off the map (a stop's row, a turn of the drive screen, a point of the elevation chart, a saved place's page)
  /// asked the Maps tab to show, and has not been shown yet: a spot ([MapShow.at]) or the whole route ([MapShow.route]). The
  /// Maps screen takes it ([takeMapShow]) when its map is ready, brings it into view and marks a spot.
  MapShow? get mapShow => _mapShow;
  MapShow? _mapShow;

  /// Takes what is to be shown (the Maps screen, once it has shown it).
  MapShow? takeMapShow() {
    final s = _mapShow;
    _mapShow = null;
    return s;
  }

  /// The Maps tab, brought to [at] with the spot marked.
  void showOnMap(GeoPoint at) {
    _mapShow = MapShow(at: at);
    notifyListeners();
    requestMap();
  }

  /// The Maps tab, brought to the point [fraction] of the way along the route shown (a point of its elevation chart).
  void showAlongRoute(double fraction) {
    final r = route;
    if (r == null || r.points.isEmpty || fraction.isNaN) return;
    showOnMap(pointAtFraction(r.points, fraction.clamp(0.0, 1.0).toDouble()));
  }

  /// The Maps tab with the whole route shown in it (the drive screen's route mini map).
  void showRouteOnMap() {
    if (route == null) return;
    _mapShow = const MapShow(route: true);
    notifyListeners();
    requestMap();
  }

  /// A place from elsewhere in the app (a saved place's page) on the Maps tab: its card while looking at the map; while a route
  /// is shown or followed (which a card would replace) the spot only.
  void showPlace(MapPlace p) {
    if (phase != NavPhase.browsing) {
      showOnMap(p.point);
      return;
    }
    select(p);
    requestMap();
  }

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
    landAccess = snapshot.landAccess;
    avoidHighways = false;
    avoidTolls = false;
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

  /// Directions from the phone's position to [to]. The app's own screens do not ask while guiding (they say to finish or end
  /// the route first); if this is reached while guiding all the same, guidance is ended first, so its position service is
  /// never left running behind a preview.
  Future<void> openDirections(MapPlace to) async {
    // Emergency routing lasts for one trip: a destination that is not the one being previewed starts a trip on Standard.
    final sameTrip = phase == NavPhase.previewing && selected?.id == to.id;
    if (guiding) await end();
    if (!sameTrip && landAccess != 'pragmatic') {
      landAccess = 'pragmatic';
      _keptLand = 'pragmatic';
    }
    selected = to;
    phase = NavPhase.previewing;
    searchOpen = false;
    notifyListeners();
    await _fetchRoutes();
  }

  /// Choose the way of travel by its engine id (see [mode]): the options of Walk, Bike and ATV, or a way of travel as it was last
  /// set. Routes again while previewing. Remembered across restarts.
  Future<void> setMode(String m) async {
    if (m == mode) return;
    mode = m;
    switch (m) {
      case 'walk' || 'offroad_foot':
        _walkOffroad = m == 'offroad_foot';
      case 'bike' || 'offroad_moto':
        _bikeDirt = m == 'offroad_moto';
      case 'offroad_4w' || 'offroad_sxs':
        _atvSideBySide = m == 'offroad_sxs';
    }
    if (TravelChoices.modes.contains(m)) _keptMode = m;
    _remember();
    notifyListeners();
    if (phase == NavPhase.previewing) await _fetchRoutes();
  }

  /// Choose Drive, Walk, Bike or ATV (`drive`, `walk`, `bike`, `atv`), with the option that choice was last set to.
  Future<void> setTravel(String t) => setMode(modeFor(t));

  /// The land access of off-road routes (Standard is `pragmatic`, Emergency `emergency`); routes again when an off-road route is
  /// shown. Lasts for the current trip: a new destination and a restart both go back to Standard (the way of travel and its options are
  /// what is remembered).
  Future<void> setLandAccess(String l) async {
    if (l == landAccess) return;
    landAccess = l;
    if (l != 'strict') _keptLand = l;
    _remember();
    notifyListeners();
    if (phase == NavPhase.previewing && offroad) await _fetchRoutes();
  }

  /// Drive's toggles: avoid highways, avoid tolls. Routes again while previewing a drive. Remembered across restarts.
  Future<void> setAvoid({bool? highways, bool? tolls}) async {
    final h = highways ?? avoidHighways, t = tolls ?? avoidTolls;
    if (h == avoidHighways && t == avoidTolls) return;
    avoidHighways = h;
    avoidTolls = t;
    _remember();
    notifyListeners();
    if (phase == NavPhase.previewing && mode == 'drive') await _fetchRoutes();
  }

  bool get _sendAvoidHighways => mode == 'drive' && avoidHighways;
  bool get _sendAvoidTolls => mode == 'drive' && avoidTolls;

  void _remember() {
    _touched = true;
    final p = prefs;
    if (p == null) return;
    unawaited(p.save(TravelChoices(
      mode: _keptMode,
      avoidHighways: avoidHighways,
      avoidTolls: avoidTolls,
      landAccess: 'pragmatic', // Emergency is for one trip: never kept for the next start
      walkOffroad: _walkOffroad,
      bikeDirt: _bikeDirt,
      atvSideBySide: _atvSideBySide,
    )));
  }

  /// Reads what was remembered and shows it, unless the person (or the assistant's route) chose something in the meantime.
  Future<void> _restore() async {
    final p = prefs;
    if (p == null) return;
    final c = await p.load();
    if (_disposed || _touched || phase != NavPhase.browsing) return;
    _walkOffroad = c.walkOffroad;
    _bikeDirt = c.bikeDirt;
    _atvSideBySide = c.atvSideBySide;
    avoidHighways = c.avoidHighways;
    avoidTolls = c.avoidTolls;
    landAccess = 'pragmatic'; // a file from before Emergency became per-trip may still say emergency: not carried over
    _keptLand = 'pragmatic';
    mode = c.mode;
    _keptMode = c.mode;
    notifyListeners();
  }

  void selectRoute(int i) {
    if (i < 0 || i >= routes.length || i == routeIndex) return;
    routeIndex = i;
    notifyListeners();
  }

  /// Directions were asked for before the phone had a position, and the panel said so: the routes are still wanted.
  bool _waitingForPosition = false;

  /// The phone's position changed. If directions are waiting for the first one, ask for the routes now, so the panel does not keep
  /// saying "not known" until something else (a mode switch) asks again.
  void _onLocation() {
    if (_disposed || !_waitingForPosition) return;
    if (phase != NavPhase.previewing || fromPlace != null || here == null) return;
    _waitingForPosition = false;
    unawaited(_fetchRoutes());
  }

  Future<void> _fetchRoutes() async {
    _waitingForPosition = false;
    final to = selected;
    final fromPin = fromPlace;
    final from = fromPin == null ? here : GeoPoint(fromPin.lat, fromPin.lon);
    if (to == null) return;
    final seq = ++_routeSeq;
    routes = const [];
    routeIndex = 0;
    routeError = null;
    offroadDataMissing = false;
    outsideMaps = false;
    if (from == null) {
      _waitingForPosition = true;
      routeError = 'Your position is not known yet. Turn on location to get directions from where you are.';
      notifyListeners();
      return;
    }
    routing = true;
    _routeFrom = from;
    notifyListeners();
    try {
      final r = await backend.route(
          from: {'lat': from.lat, 'lon': from.lon, 'name': fromPin?.name ?? 'Your location'},
          to: to.toEnd(),
          via: _via(),
          mode: mode,
          landAccess: offroad ? landAccess : null,
          alternatives: stops.isEmpty ? 2 : 0,
          avoidHighways: _sendAvoidHighways,
          avoidTolls: _sendAvoidTolls);
      if (seq != _routeSeq) return;
      if (!r.ok) {
        routeError = routeErrorText(r);
        offroadDataMissing = offroad && r.errors.isNotEmpty && r.errors.first.code == 'not_set_up';
        outsideMaps = r.errors.isNotEmpty && r.errors.first.code == 'out_of_coverage';
      } else {
        routes = [r, ...r.alternatives];
        if (r.warnings.any((w) => w.code == 'offroad_unavailable')) {
          _events.add(const NavNotice('Part of this trip is off the roads, and the off-road map data is not on this device'));
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
      'no_road_data' => "Road data for this trip isn't on this device yet. Connect and try again.",
      'route_too_long' => 'The off-road part of this trip is too long to work out',
      'upstream_timeout' => 'Working out the route took too long. Try again',
      'not_set_up' => 'Off-road needs off-road data for this area',
      _ => 'Could not get directions',
    };
  }

  /// Back from the preview to looking at the map (the place stays selected).
  void cancelDirections() {
    _routeSeq++;
    _waitingForPosition = false;
    phase = NavPhase.browsing;
    fromPlace = null;
    stops = const [];
    routes = const [];
    routeError = null;
    routing = false;
    notifyListeners();
  }

  // ---- guidance ----------------------------------------------------------------------------------------------

  /// Start turn-by-turn on the chosen route.
  ///
  /// [quietOpening]: the opening line is not spoken for this start (Siri started the route and says its own words); every later
  /// prompt is spoken as usual.
  Future<void> start({bool quietOpening = false}) async {
    final r = route;
    if (r == null || phase != NavPhase.previewing) return;
    _cancelArrivalEnd();
    phase = NavPhase.guiding;
    arrived = false;
    _rerouteGen++;
    rerouting = false;
    _reroutingSince = null;
    progress = null;
    _sendRoute = true;
    _routeStarted = false;
    _quietOpening = quietOpening;
    _lastReroute = null;
    _passedStops.clear();
    _routeStops = _aheadIndexes();
    _engine = GuidanceEngine(fmt: fmt, mode: r.mode, destination: r.destinationName);
    onFollow?.call(FollowMode.headingUp);
    notifyListeners();
    final name = r.destinationName.isEmpty ? 'your destination' : r.destinationName;
    // Notification permission is not asked here: a system prompt left unanswered held the position back. It is asked when
    // weather and alerts are switched on; without it guidance still runs (Android 13 and later then hide its notification).
    location.holdStream(true);
    if (phase != NavPhase.guiding) {
      location.holdStream(false);
      return;
    }
    _fixSub = positionSource.start(title: 'Cache navigation', text: 'Guiding you to $name').listen(_onFix, onError: _onFixError);
    _simulated = simulatedDrive?.call() ?? false;
    _startGuidanceLog();
    // The route's own time at the start, and at arrival the time the drive took (numbers only): a drive in the log then says
    // how far the router's estimate was from the drive.
    _startedAt = _clock();
    _plannedS = r.durationS;
    logInfo('Guidance: the route\'s time is ${r.durationS} s for ${r.distanceM.round()} m');
    // The first fix may already be known; the stream gives the next ones.
    final f = location.fix;
    if (f != null && !(simulatedDrive?.call() ?? false)) unawaited(_handleFix(f));
  }

  /// When this guidance started, and the time the route said then (see [start]).
  DateTime? _startedAt;
  int? _plannedS;

  /// True while the guidance that is running is a simulated drive (asked once, when it starts).
  bool _simulated = false;

  void _onFix(Fix f) {
    _diag.fixes++;
    _diag.lastFix = f;
    location.publish(f);
    unawaited(_handleFix(f));
  }

  /// The position stream reported an error. Before, nothing listened for it; it is counted and logged, and the stream goes on.
  void _onFixError(Object e) {
    _diag.streamErrors++;
    _diag.streamFailures.failed('Guidance: the position stream reported an error', e, _clock());
  }

  // ---- the guidance log ----------------------------------------------------------------------------------
  // One line a minute while guidance runs, so a drive in the log says whether fixes came, what the core answered and what
  // failed. These are log lines only; nothing here changes what guidance does.

  final _GuidanceDiag _diag = _GuidanceDiag();
  Timer? _guidanceLogTimer;

  void _startGuidanceLog() {
    _guidanceLogTimer?.cancel();
    _diag.reset(_clock());
    logInfo('Guidance: started, waiting for fixes from the position service${_simulated ? ' (a simulated drive)' : ''}');
    final every = guidanceLogEvery;
    if (every != null) _guidanceLogTimer = Timer.periodic(every, (_) => logGuidanceMinute());
    _guidanceLogOn = true;
  }

  bool _guidanceLogOn = false;

  void _stopGuidanceLog() {
    _guidanceLogTimer?.cancel();
    _guidanceLogTimer = null;
    if (!_guidanceLogOn) return;
    _guidanceLogOn = false;
    logGuidanceMinute();
  }

  /// Writes the guidance line for the time since the last one and starts counting again. The timer calls it once every
  /// [guidanceLogEvery] while guidance runs, and once more when guidance lets go of the position service.
  @visibleForTesting
  void logGuidanceMinute() {
    final now = _clock();
    final d = _diag;
    final secs = now.difference(d.since).inSeconds;
    final f = d.lastFix ?? lastFix;
    final fixPart = f == null
        ? 'no fix yet'
        : 'last fix ${_age(now, f.time)} old, accuracy ${f.accuracyM.round()} m';
    final p = d.lastProgress;
    final progressPart = p == null
        ? 'no progress answer'
        : 'last progress ${_age(now, d.lastProgressAt!)} old: on route ${p.onRoute}, off route ${p.offRoute} '
            '(${p.offRouteCount} fixes off), ${p.offsetM.round()} m from the route, ${p.distanceAlongM.round()} of ${p.totalM.round()} m along';
    final parts = <String>[
      '${d.fixes} fixes in ${secs}s',
      fixPart,
      '${d.progressCalls} progress calls',
      progressPart,
      '${d.progressErrors} progress errors${d.firstProgressError == null ? '' : ' (first: ${d.firstProgressError})'}',
      if (d.streamErrors > 0) '${d.streamErrors} position stream errors',
      if (d.offRouteAnswers > 0) '${d.offRouteAnswers} off-route answers',
      if (d.reroutesSkipped > 0) '${d.reroutesSkipped} re-routes skipped (one already running or within the cooldown)',
      if (d.rerouteFailures > 0) '${d.rerouteFailures} re-routes failed',
      if (rerouting && _reroutingSince != null) 'a new route has been worked out for ${now.difference(_reroutingSince!).inSeconds}s',
    ];
    logInfo('Guidance: ${parts.join(', ')}');
    d.next(now);
  }

  static String _age(DateTime now, DateTime t) {
    final s = now.difference(t).inMilliseconds / 1000;
    return '${s.toStringAsFixed(s.abs() < 10 ? 1 : 0)} s';
  }

  DateTime? _reroutingSince;

  /// Feeds a fix to guidance. Updates are one at a time: a fix that arrives while the core is busy replaces the one waiting.
  ///
  /// After arrival a fix is only the vehicle's position: it is kept as [lastFix] and told (the phone map, the car's marker),
  /// and nothing else is done with it (no progress, prompt or re-route).
  Future<void> _handleFix(Fix f) async {
    if (!guiding) return;
    lastFix = f;
    if (arrived) {
      notifyListeners();
      return;
    }
    // The next stop, once the phone came within 100 m of it, is passed: a new route after going off the route leaves it out.
    // Only the next one: stops are visited in order, and being near a later stop does not pass it or the ones before it.
    final nextStop = _aheadIndexes().firstOrNull;
    if (nextStop != null && _haversineM(f.lat, f.lon, stops[nextStop].lat, stops[nextStop].lon) < 100 && _passedStops.add(nextStop)) {
      logInfo('Guidance: stop ${nextStop + 1} of ${stops.length} is passed (a fix within 100 m of it)');
    }
    if (_busyProgress) {
      _pendingFix = f;
      return;
    }
    _busyProgress = true;
    try {
      Fix? cur = f;
      while (cur != null && guiding && !arrived) {
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
    _diag.progressCalls++;
    try {
      final p = await backend.progress(r, lat: f.lat, lon: f.lon, accuracyM: f.accuracyM, now: _clock(), sendRoute: _sendRoute);
      _sendRoute = false;
      _diag.lastProgress = p;
      _diag.lastProgressAt = _clock();
      if (p.offRoute) _diag.offRouteAnswers++;
      if (!guiding || arrived || route?.routeId != r.routeId) return;
      // A new plan (the first answer after Start, a re-route, an added stop: each clears the progress first) starts the
      // measured pace again.
      if (progress == null || progress!.routeId != p.routeId) _blend.reset();
      _blendLeft = _blend.update(at: _clock(), distanceAlongM: p.distanceAlongM, planLeftS: p.remainingS);
      _blendFor = p;
      progress = p;
      // The stops the core has seen reached along this route are passed, so the list of stops ahead (the route panel, the
      // car's overview) and the route being followed are one list.
      for (var k = 0; k < p.stopsReached && k < _routeStops.length; k++) {
        if (_passedStops.add(_routeStops[k])) {
          logInfo('Guidance: stop ${_routeStops[k] + 1} of ${stops.length} is passed (reached along the route)');
        }
      }
      if (!_routeStarted) {
        _routeStarted = true;
        if (_quietOpening) {
          _quietOpening = false;
        } else {
          _say(_engine!.opening(r, p.current));
        }
      }
      for (final line in _engine!.update(p)) {
        _say(line);
      }
      if (p.arrived) {
        // Arrival is final for this trip: no later fix goes to guidance, so nothing reroutes or speaks again. The position
        // service keeps running until End: its fixes still move the phone map's marker and camera and the car's marker
        // ([_handleFix]); before, it was let go here and every map froze on the arrival point until End. The phase stays
        // guiding, so the arrived banner (and the car's) shows until it is dismissed.
        arrived = true;
        _blend.reset();
        _pendingFix = null;
        _stopGuidanceLog();
        _armArrivalEnd();
        notifyListeners();
        logInfo('Guidance: arrived, the position keeps coming until End');
        final began = _startedAt;
        if (began != null) logInfo('Guidance: arrived after ${_clock().difference(began).inSeconds} s; the route\'s time at the start was $_plannedS s');
        return;
      }
      if (p.offRoute) await _reroute(f);
      notifyListeners();
    } catch (e) {
      // A bad update is skipped; the next fix tries again. A core that lost the route is sent it again.
      if (e is CacheSearchException && e.code == 'not_found') _sendRoute = true;
      // It is counted for the guidance line and logged (the first, then at most once a minute): before, a drive whose every
      // update failed left nothing in the log.
      _diag.progressErrors++;
      _diag.firstProgressError ??= _GuidanceDiag.describe(e);
      _diag.progressFailures.failed('Guidance: a progress update failed', e, _clock());
    }
  }

  /// Counts re-route requests: an answer is applied only by the request that is still the newest ([_reroute]). Start, End and
  /// Add stop while guiding move it on too, so an answer from before them is never applied after them.
  int _rerouteGen = 0;

  Future<void> _reroute(Fix f) async {
    final now = _clock();
    if (rerouting) {
      _diag.reroutesSkipped++;
      final since = _reroutingSince;
      logInfo('Guidance: off the route, re-route skipped: one is already being worked out'
          '${since == null ? '' : ' (for ${now.difference(since).inSeconds}s)'}');
      return;
    }
    final last = _lastReroute;
    if (last != null && now.difference(last) < rerouteCooldown) {
      _diag.reroutesSkipped++;
      logInfo('Guidance: off the route, re-route skipped: ${now.difference(last).inSeconds}s since the last one '
          '(it waits ${rerouteCooldown.inSeconds}s)');
      return;
    }
    final old = route;
    final to = selected;
    if (old == null || to == null) {
      _diag.rerouteFailures++;
      logError('Guidance: off the route, but there is ${old == null ? 'no route' : 'no destination'} to work out a new one for');
      return;
    }
    final gen = ++_rerouteGen;
    rerouting = true;
    _reroutingSince = now;
    _lastReroute = now;
    notifyListeners();
    _say('Rerouting.');
    try {
      // The core is one queue: a route can wait behind a slow call (opening the core, a model loading). The limit is long enough
      // for that; past it this request is given up, the next off-route fix asks again, and its answer, if it still comes, is
      // never used.
      final r = await backend
          .route(
              // The way the vehicle is going rides with the start (heading_deg, only when it is moving): the router then starts the
              // new route forward. Without it a start on a road mid-block was snapped either way, and a driver who turned early
              // got a route that began with a U-turn, which he was off again after a few more seconds (a re-route every cooldown).
              from: {'lat': f.lat, 'lon': f.lon, 'name': 'Your location', if (f.heading != null) 'heading_deg': f.heading},
              to: to.toEnd(), via: _via(skipPassed: true), mode: mode, landAccess: offroad ? landAccess : null, alternatives: 0, avoidHighways: _sendAvoidHighways, avoidTolls: _sendAvoidTolls)
          .timeout(rerouteTimeout);
      if (gen != _rerouteGen || !guiding || !identical(selected, to)) {
        logInfo('Guidance: a new route came after guidance had moved on, it is not used');
        return;
      }
      if (r.ok) {
        routes = [r];
        routeIndex = 0;
        _routeFrom = GeoPoint(f.lat, f.lon);
        _sendRoute = true;
        _routeStarted = true;
        _engine = GuidanceEngine(fmt: fmt, mode: r.mode, destination: r.destinationName);
        progress = null;
        _routeStops = _aheadIndexes();
        logInfo('Guidance: off the route, the new route goes through ${stopsAhead.length} of ${stops.length} stops');
      } else {
        _diag.rerouteFailures++;
        logError('Guidance: off the route, no new route (${r.errors.isEmpty ? 'no error code' : r.errors.first.code})');
        _events.add(NavNotice(routeErrorText(r)));
      }
    } on TimeoutException {
      if (gen == _rerouteGen && guiding) {
        _diag.rerouteFailures++;
        logError('Guidance: off the route, no new route within ${rerouteTimeout.inSeconds}s; the next fix off the route asks again');
        _events.add(const NavNotice('Could not work out a new route'));
      }
    } catch (e) {
      if (gen == _rerouteGen && guiding) {
        _diag.rerouteFailures++;
        logError('Guidance: off the route, working out a new route failed: ${_GuidanceDiag.describe(e)}');
        _events.add(const NavNotice('Could not work out a new route'));
      }
    } finally {
      // Only the newest request lets go of the flag: one that was overtaken (a new drive, Add stop) leaves the newer one's.
      if (gen == _rerouteGen) {
        rerouting = false;
        _reroutingSince = null;
        notifyListeners();
      }
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

  /// Lets go of what guidance holds to follow the phone: its fixes, the position service (with its notification and wake
  /// lock) and the hold on the map's own position stream. The guidance fix is forgotten with them, so [here] is the phone's
  /// own position again. Calling it again is harmless.
  Future<void> _stopTracking() async {
    _stopGuidanceLog();
    final sub = _fixSub;
    _fixSub = null;
    _pendingFix = null;
    lastFix = null;
    try {
      await sub?.cancel();
      await positionSource.stop();
    } finally {
      location.holdStream(false);
    }
  }

  /// Ends guidance by itself [arrivalEndAfter] after arrival if End was not tapped, the same way End does ([end]), so the
  /// position service (its notification and wake lock on Android) is not left running for a trip that is over. End, a new
  /// route or a new destination (each goes through [end] or [start]) cancels it; the generation check is a second guard.
  void _armArrivalEnd() {
    _arrivalEndTimer?.cancel();
    final gen = _rerouteGen;
    _arrivalEndTimer = Timer(arrivalEndAfter, () {
      _arrivalEndTimer = null;
      if (_disposed || !guiding || !arrived || gen != _rerouteGen) return;
      logInfo('Guidance: ended by itself 5 minutes after arrival');
      unawaited(end());
    });
  }

  Timer? _arrivalEndTimer;

  void _cancelArrivalEnd() {
    _arrivalEndTimer?.cancel();
    _arrivalEndTimer = null;
  }

  /// End guidance: stop the position service and the voice, back to the map with the place still selected.
  Future<void> end() async {
    _cancelArrivalEnd();
    if (!guiding) return;
    await _stopTracking();
    logInfo('Guidance: ended, the position service is let go');
    // What was passed belongs to the drive that is over: the next route's stops are all ahead (a stale mark hid the stop
    // added to the next route from the car's route screen).
    _passedStops.clear();
    _routeStops = const [];
    if (_simulated) {
      // A simulated drive's fixes went to the location service as guidance fixes do ([_onFix]), so its last point was left
      // there as the phone's position: the map, "here" and the car's home map all showed it until something read a real
      // position. It is forgotten, and the phone's real position is read again (no prompt: only a permission already given).
      _simulated = false;
      location.forgetPublished();
      unawaited(location.request(explain: () async => false));
    }
    await speaker.stop();
    phase = NavPhase.browsing;
    routes = const [];
    fromPlace = null;
    stops = const [];
    progress = null;
    arrived = false;
    _rerouteGen++;
    rerouting = false;
    _reroutingSince = null;
    lastFix = null;
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

  /// The places of the route asked for, in the order a missing download is looked for ([outsideMaps], [offroadDataMissing]):
  /// where to, the stops, then the start.
  List<GeoPoint> get routeEnds => [if (selected case final to?) to.point, for (final s in stops) s.point, ?_routeFrom];

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    location.removeListener(_onLocation);
    _searchTimer?.cancel();
    _meaningTimer?.cancel();
    _guidanceLogTimer?.cancel();
    _guidanceLogTimer = null;
    _cancelArrivalEnd();
    _fixSub?.cancel();
    positionSource.stop();
    location.holdStream(false);
    lastFix = null;
    _events.close();
    super.dispose();
  }
}

/// What guidance counts between two of its log lines ([NavState.logGuidanceMinute]).
class _GuidanceDiag {
  DateTime since = DateTime.fromMillisecondsSinceEpoch(0);
  int fixes = 0;
  int progressCalls = 0;
  int progressErrors = 0;
  String? firstProgressError;
  int streamErrors = 0;
  int offRouteAnswers = 0;
  int reroutesSkipped = 0;
  int rerouteFailures = 0;

  /// Kept from one line to the next: their age says how long ago the last one came.
  Fix? lastFix;
  MapProgress? lastProgress;
  DateTime? lastProgressAt;

  final _FailureLog progressFailures = _FailureLog();
  final _FailureLog streamFailures = _FailureLog();

  /// A new drive.
  void reset(DateTime now) {
    next(now);
    lastFix = null;
    lastProgress = null;
    lastProgressAt = null;
    progressFailures.reset();
    streamFailures.reset();
  }

  /// The counts start again after a line.
  void next(DateTime now) {
    since = now;
    fixes = 0;
    progressCalls = 0;
    progressErrors = 0;
    firstProgressError = null;
    streamErrors = 0;
    offRouteAnswers = 0;
    reroutesSkipped = 0;
    rerouteFailures = 0;
  }

  /// An error in one line of the log: the core's code and message, or the error's own text, at most 200 characters.
  static String describe(Object e) {
    final s = (e is CacheSearchException ? '${e.code}: ${e.message}' : '$e').replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length <= 200 ? s : '${s.substring(0, 200)}...';
  }
}

/// Logs a failure that can repeat with every fix: the first one, then at most one line a minute, saying how many were not
/// logged in between.
class _FailureLog {
  static const Duration every = Duration(minutes: 1);
  DateTime? _lastAt;
  int _notLogged = 0;

  void reset() {
    _lastAt = null;
    _notLogged = 0;
  }

  void failed(String what, Object? error, DateTime now) {
    final last = _lastAt;
    if (last != null && now.difference(last) < every) {
      _notLogged++;
      return;
    }
    final more = _notLogged > 0 ? ' ($_notLogged more since the last such line)' : '';
    logError('$what$more${error == null ? '' : ': ${_GuidanceDiag.describe(error)}'}');
    _lastAt = now;
    _notLogged = 0;
  }
}

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}
