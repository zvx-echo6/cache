import 'dart:async';
import 'dart:isolate';

import 'package:cache_search/cache_search.dart' show MapRoute;
import 'package:flutter/foundation.dart';

import '../../maps/layers/layer_def.dart';
import '../../maps/layers/layer_engine.dart';
import '../../platform/app_log.dart';
import 'elevation_profile.dart';
import 'route_sampler.dart';

/// Works out a route's elevation profile in one go; tests give their own.
typedef ElevationLoader = Future<ElevationProfile> Function(MapRoute route);

/// A run of heights read from the tiles: the first sample of the route's samples ([resampleRoute]) it covers, and the heights.
typedef ElevationChunk = ({int first, List<double> heights});

/// A profile being worked out. [result] completes with it. [stop] ends the work at once: [result] then completes with
/// [ElevationStopped], unless the profile was already on its way.
class ElevationJob {
  ElevationJob(this.result, {this.onStop, this.chunks});

  final Future<ElevationProfile> result;

  /// The heights as they are read, in chunks (null: the job gives the whole profile at the end only). [result] still completes
  /// with the whole profile.
  final Stream<ElevationChunk>? chunks;

  /// What ends the work ([stop] calls it, once); null for work that cannot be ended.
  final void Function()? onStop;
  bool _stopped = false;

  /// Ends the work now. Calling it again, or after the work is done, does nothing.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    onStop?.call();
  }
}

/// What a job that was stopped before it had a profile ends with.
class ElevationStopped implements Exception {
  const ElevationStopped();

  @override
  String toString() => 'The elevation job was stopped';
}

/// Starts working out a route's elevation profile, as a job that can be stopped.
typedef ElevationStarter = ElevationJob Function(MapRoute route);

/// The elevation profile of the route shown (the preview's chosen route, or the one being followed), and whether the guidance
/// card's elevation panel is pulled up. A profile is worked out once per route, in a background isolate.
///
/// The read goes through the route in chunks, the part nearest the driver first, and the profile grows as they arrive: [profile]
/// is the whole route's, with no height yet where it has not been read. While a drive is under way nothing is ever "being
/// calculated" on screen: a re-route keeps what was there (the unchanged road ahead, rebased to the new route's metres) and the
/// new chunks replace it from the driver outward.
///
/// One job runs at a time. The job of a route that has been replaced or dropped is stopped, not left to finish: a long route's
/// job takes minutes of one processor core, and a route that keeps being replaced (re-routing) used to leave one running for
/// every route it had been.
class RouteElevation extends ChangeNotifier {
  /// [start] starts a job that can be stopped (the real one: [tileServerElevationJobs]); [loader] works a profile out in one
  /// go and cannot be stopped (the tests' own). One of the two is given.
  RouteElevation({ElevationLoader? loader, ElevationStarter? start})
      : assert((loader == null) != (start == null), 'a loader or a start, not both'),
        _start = start ?? ((route) => ElevationJob(Future<ElevationProfile>.sync(() => loader!(route))));

  final ElevationStarter _start;

  /// The job of the route shown, while it runs, and its chunks.
  ElevationJob? _job;
  StreamSubscription<ElevationChunk>? _chunks;

  /// The route last asked for, whose profile is being read or shown, the metres of its samples, and the heights read so far
  /// (NaN where not read).
  String? _routeId;
  List<double> _distM = const [];
  List<double> _heights = const [];
  ElevationProfile? _profile;
  bool _loading = false;
  bool _open = false;

  /// Where the position was last on the profile (profile metres), and the steepest climb shown ahead ([climbAhead]).
  double? _lastPos;
  Climb? _held;

  /// The profile of the route last asked for, as far as it has been read (see [loading]); null only when nothing at all is known
  /// yet or there is no route.
  ElevationProfile? get profile => _profile;

  /// The read of the route is not finished: the profile may have parts not read yet. Nothing on screen says so while a drive is
  /// under way; the preview keeps its "Reading the elevation".
  bool get loading => _loading;

  /// The panel on the guidance card is pulled up.
  bool get open => _open;

  /// The profile for [route] (null: none). The same route again does nothing. Another route, or none, stops the job that was
  /// running for the one before.
  ///
  /// [following]: the route is the one being driven (guidance is on). A re-route then keeps the profile that is on screen: its road
  /// ahead of the position is carried over to the new route's metres, and the new route's chunks replace it as they arrive. With
  /// [following] false (the preview, a different route chosen) the profile is cleared.
  void request(MapRoute? route, {bool following = false}) {
    if (route == null) {
      if (_routeId == null) return;
      _routeId = null;
      _stopJob();
      _profile = null;
      _distM = const [];
      _heights = const [];
      _lastPos = null;
      _held = null;
      _loading = false;
      notifyListeners();
      return;
    }
    if (route.routeId == _routeId) return;
    final old = _profile;
    final carryFrom = following && old != null && old.hasData ? (_lastPos ?? 0) : null;
    _stopJob();
    final id = _routeId = route.routeId;
    final samples = resampleRoute([for (final p in route.points) (p.lat, p.lon)]);
    _distM = [for (final s in samples) s.distM];
    _heights = List<double>.filled(_distM.length, double.nan);
    _held = null;
    _lastPos = null;
    if (carryFrom != null && _distM.length >= 2) {
      // The new route starts where the driver is: the old route's heights from there on stand in until the chunks replace them.
      for (var i = 0; i < _distM.length; i++) {
        final at = carryFrom + _distM[i];
        _heights[i] = at > old!.totalM ? double.nan : (old.elevationAt(at) ?? double.nan);
      }
      _profile = ElevationProfile.fromSamples(_distM, _heights, totalM: _distM.last);
    } else {
      _profile = null;
    }
    _loading = true;
    notifyListeners();
    // A listener asked for something else meanwhile: that request has its own job.
    if (_disposed || _routeId != id) return;
    _begin(route, carried: carryFrom != null);
  }

  void _begin(MapRoute route, {required bool carried}) {
    final ElevationJob job;
    try {
      job = _start(route);
    } catch (_) {
      _end(ElevationProfile.none(route.distanceM), carried);
      return;
    }
    _job = job;
    _chunks = job.chunks?.listen((c) {
      if (_disposed || !identical(_job, job)) return;
      final end = c.first + c.heights.length;
      if (c.first < 0 || end > _heights.length) return;
      _heights.setRange(c.first, end, c.heights);
      _profile = ElevationProfile.fromSamples(_distM, _heights, totalM: _distM.last);
      notifyListeners();
    });
    unawaited(() async {
      ElevationProfile p;
      try {
        p = await job.result;
      } catch (_) {
        p = ElevationProfile.none(route.distanceM);
      }
      if (_disposed || !identical(_job, job)) return;
      _job = null;
      unawaited(_chunks?.cancel());
      _chunks = null;
      _end(p, carried);
    }());
  }

  /// The read is done: [p] is the whole profile. A read that found no data does not take the place of what a re-route carried over.
  void _end(ElevationProfile p, bool carried) {
    if (!(carried && !p.hasData && (_profile?.hasData ?? false))) _profile = p;
    _loading = false;
    _held = null;
    notifyListeners();
  }

  void _stopJob() {
    final job = _job;
    _job = null;
    unawaited(_chunks?.cancel());
    _chunks = null;
    job?.stop();
  }

  void setOpen(bool v) {
    if (_open == v) return;
    _open = v;
    notifyListeners();
  }

  void toggle() => setOpen(!_open);

  /// Where the position is on the profile: the core's metres along the route, scaled to the profile's own length (the two
  /// measure the same line slightly differently).
  double? positionOnProfile(double? distanceAlongM, double routeM) {
    final p = _profile;
    if (p == null || distanceAlongM == null || routeM <= 0) return null;
    return _lastPos = (distanceAlongM * p.totalM / routeM).clamp(0, p.totalM).toDouble();
  }

  /// The steepest climb ahead of [posM] (profile metres) as far as the chunks read so far show it, kept steady while more
  /// arrives: the climb shown is replaced only by a clearly steeper one (a fifth steeper, and at least half a percent), by the
  /// same climb found longer (a later chunk read more of it, so it is corrected, not changed), or once it is behind the
  /// position. When the read is done the whole route's answer is given.
  Climb? climbAhead(double posM) {
    final p = _profile;
    if (p == null) return null;
    final found = p.steepestClimbAhead(posM);
    if (!_loading) return found;
    final held = _held;
    if (held == null || held.endM <= posM) return _held = found;
    if (found == null) return held;
    final same = found.startM < held.endM && found.endM > held.startM;
    final steeper = found.grade >= held.grade * 1.2 && found.grade - held.grade >= 0.005;
    if (steeper || (same && found.grade >= held.grade)) _held = found;
    return _held;
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _stopJob();
    super.dispose();
  }
}

/// The real jobs: the map's elevation layer through the layer engine's tile server (its downloaded tiles and the ones viewed
/// before), sampled and smoothed in a background isolate that is killed when the job is stopped.
ElevationStarter tileServerElevationJobs(LayerEngine engine, {double Function(MapRoute route)? along}) => (route) {
      final total = route.distanceM;
      ElevationJob none() => ElevationJob(Future<ElevationProfile>.value(ElevationProfile.none(total)));
      if (!engine.ready) return none();
      LayerDef? def = engine.layer('elevation');
      def ??= engine.layers.where((l) => l.kind == LayerKind.elevation).firstOrNull;
      if (def == null) return none();
      final url = engine.tilesUrl(def.id);
      if (url.contains(':0/')) return none();
      final zoom = def.maxZoom.clamp(0, 12);
      final points = [for (final p in route.points) (p.lat, p.lon)];
      return profileJob(url, zoom, points, fromM: along?.call(route) ?? 0);
    };

/// Starts the sampling in a background isolate of its own, which [ElevationJob.stop] kills at once (also in the middle of
/// reading or decoding a tile, and with it what it held). The isolate is sent only the address, the zoom and the points, and
/// hands the profile back as it exits.
ElevationJob profileJob(String urlTemplate, int zoom, List<(double, double)> points, {double fromM = 0}) {
  final result = Completer<ElevationProfile>();
  final chunks = StreamController<ElevationChunk>();
  final port = RawReceivePort();
  Isolate? isolate;
  var stopped = false;
  final clock = Stopwatch()..start();
  var first = true;
  void finishChunks() {
    if (!chunks.isClosed) unawaited(chunks.close());
  }

  // The isolate sends the chunks as they are read (a list of the first sample and the heights); one other message ends the job:
  // the profile, its uncaught error (a list of two strings), or its exit with neither (null).
  port.handler = (Object? message) {
    if (message is List && message.length == 2 && message[0] is int && message[1] is Float64List) {
      if (first) {
        first = false;
        logInfo('Elevation: the first chunk of the route arrived after ${clock.elapsedMilliseconds} ms');
      }
      if (!chunks.isClosed && !stopped) chunks.add((first: message[0] as int, heights: message[1] as Float64List));
      return;
    }
    port.close();
    finishChunks();
    if (result.isCompleted) return;
    if (message is ElevationProfile) {
      result.complete(message);
    } else if (stopped) {
      result.completeError(const ElevationStopped());
    } else if (message is List && message.isNotEmpty) {
      result.completeError(StateError('The elevation job failed: ${message.first}'));
    } else {
      result.completeError(StateError('The elevation job ended without a profile'));
    }
  };
  unawaited(Isolate.spawn(_profileIsolate, (port.sendPort, urlTemplate, zoom, points, fromM), onError: port.sendPort, onExit: port.sendPort).then<void>((i) {
    isolate = i;
    // Stopped before the isolate had started.
    if (stopped) i.kill(priority: Isolate.immediate);
  }, onError: (Object e, StackTrace st) {
    port.close();
    finishChunks();
    if (!result.isCompleted) result.completeError(e, st);
  }));
  return ElevationJob(result.future, chunks: chunks.stream, onStop: () {
    stopped = true;
    finishChunks();
    isolate?.kill(priority: Isolate.immediate);
  });
}

/// The isolate of [profileJob].
Future<void> _profileIsolate((SendPort, String, int, List<(double, double)>, double) job) async {
  final (port, urlTemplate, zoom, points, fromM) = job;
  final tiles = LocalServerDemTiles(urlTemplate);
  final ElevationProfile profile;
  try {
    profile = await buildRouteProfileInChunks(points, tiles, zoom: zoom, fromM: fromM, onChunk: (first, heights) => port.send(<Object>[first, Float64List.fromList(heights)]));
  } finally {
    tiles.close();
  }
  Isolate.exit(port, profile);
}
