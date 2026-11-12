import 'dart:async';
import 'dart:isolate';

import 'package:cache_search/cache_search.dart' show MapRoute;
import 'package:flutter/foundation.dart';

import '../../maps/layers/layer_def.dart';
import '../../maps/layers/layer_engine.dart';
import 'elevation_profile.dart';
import 'route_sampler.dart';

/// Works out a route's elevation profile in one go; tests give their own.
typedef ElevationLoader = Future<ElevationProfile> Function(MapRoute route);

/// A profile being worked out. [result] completes with it. [stop] ends the work at once: [result] then completes with
/// [ElevationStopped], unless the profile was already on its way.
class ElevationJob {
  ElevationJob(this.result, {this.onStop});

  final Future<ElevationProfile> result;

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

  /// The job of the route shown, while it runs.
  ElevationJob? _job;

  /// The route last asked for, whose profile is being read or shown.
  String? _routeId;
  ElevationProfile? _profile;
  bool _loading = false;
  bool _open = false;

  /// While following a route, a newer route (a re-route) asked for while a profile is shown or being read: it is read after, and
  /// until then the profile there is stays on screen ([stale]).
  MapRoute? _pending;

  /// The profile on screen is of an earlier route than the one now followed: the new one is being read.
  bool _stale = false;

  /// Where the position was on the profile when it went stale, and the last place worked out (profile metres).
  double? _frozenPos, _lastPos;

  /// The profile of the route last asked for. While a re-route's new profile is being read it is the earlier route's ([stale]), and
  /// it is null only when there is nothing at all to show (nothing yet read, or no route).
  ElevationProfile? get profile => _profile;

  /// A profile is being worked out (it may be shown, stale, meanwhile).
  bool get loading => _loading;

  /// The profile shown is of the route before a re-route; the new route's is on its way.
  bool get stale => _stale;

  /// The panel on the guidance card is pulled up.
  bool get open => _open;

  /// The profile for [route] (null: none). The same route again does nothing. Another route, or none, stops the job that was
  /// running for the one before.
  ///
  /// [following]: the route is the one being driven (guidance is on). A re-route then does not clear the profile and does not stop
  /// the job that is running: what there is stays on screen (with the position where it was) until the new route's profile is
  /// ready, which is read after the running job ends; only the newest route is read. The reading state is then only for when
  /// there is nothing at all to show. With [following] false (the preview, a different route chosen) the profile is cleared.
  void request(MapRoute? route, {bool following = false}) {
    if (route == null) {
      if (_routeId == null) return;
      _routeId = null;
      _pending = null;
      _stale = false;
      _frozenPos = _lastPos = null;
      _stopJob();
      _profile = null;
      _loading = false;
      notifyListeners();
      return;
    }
    if (route.routeId == _routeId) return;
    if (following && (_profile != null || _job != null)) {
      _routeId = route.routeId;
      _pending = route;
      if (_job == null) _startPending();
      return;
    }
    _pending = null;
    _stale = false;
    _frozenPos = _lastPos = null;
    _stopJob();
    final id = _routeId = route.routeId;
    _profile = null;
    _loading = true;
    notifyListeners();
    // A listener asked for something else meanwhile: that request has its own job.
    if (_disposed || _routeId != id) return;
    _begin(route);
  }

  /// Reads the pending route's profile; what is on screen stays until it is ready.
  void _startPending() {
    final r = _pending;
    _pending = null;
    if (r == null || _disposed) return;
    if (_profile != null && !_stale) {
      _stale = true;
      _frozenPos = _lastPos;
    }
    _loading = true;
    notifyListeners();
    _begin(r);
  }

  void _begin(MapRoute route) {
    final ElevationJob job;
    try {
      job = _start(route);
    } catch (_) {
      _finish(null, ElevationProfile.none(route.distanceM), route);
      return;
    }
    _job = job;
    unawaited(() async {
      ElevationProfile p;
      try {
        p = await job.result;
      } catch (_) {
        p = ElevationProfile.none(route.distanceM);
      }
      if (_disposed || !identical(_job, job)) return;
      _finish(job, p, route);
    }());
  }

  void _finish(ElevationJob? job, ElevationProfile p, MapRoute route) {
    _job = null;
    if (_pending != null) {
      // A newer route was asked for while this one was read. This profile is better than none: it is shown (it is not the newest
      // route's, so it is stale) while the newest is read. A profile with no data does not replace one that has.
      if (p.hasData || _profile == null || !_profile!.hasData) {
        _profile = p;
      }
      _stale = true;
      _frozenPos = _lastPos;
      notifyListeners();
      _startPending();
      return;
    }
    // A profile with no data (the read failed or there are no tiles) does not replace one that has data, for a route that
    // replaced the one shown (a re-route).
    if (_stale && !p.hasData && (_profile?.hasData ?? false)) {
      _stale = false;
      _loading = false;
      notifyListeners();
      return;
    }
    _profile = p;
    _stale = false;
    _frozenPos = _lastPos = null;
    _loading = false;
    notifyListeners();
  }

  void _stopJob() {
    final job = _job;
    _job = null;
    job?.stop();
  }

  void setOpen(bool v) {
    if (_open == v) return;
    _open = v;
    notifyListeners();
  }

  void toggle() => setOpen(!_open);

  /// Where the position is on the profile: the core's metres along the route, scaled to the profile's own length (the two
  /// measure the same line slightly differently). While the profile is of the route before a re-route ([stale]) the position stays
  /// where it was on it (null if it was not known).
  double? positionOnProfile(double? distanceAlongM, double routeM) {
    final p = _profile;
    if (p == null) return null;
    if (_stale) return _frozenPos;
    if (distanceAlongM == null || routeM <= 0) return null;
    return _lastPos = (distanceAlongM * p.totalM / routeM).clamp(0, p.totalM).toDouble();
  }

  /// The position for the car's climb card and mini map: [distanceAlongM] and [routeM] as they are, or, while the profile is
  /// [stale], the position held on it with the profile's own length, so the card keeps showing the climb ahead of that place.
  (double?, double) carPosition(double? distanceAlongM, double routeM) {
    final p = _profile;
    if (_stale && p != null) return (_frozenPos, p.totalM);
    if (p != null && distanceAlongM != null && routeM > 0) _lastPos = (distanceAlongM * p.totalM / routeM).clamp(0, p.totalM).toDouble();
    return (distanceAlongM, routeM);
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
ElevationStarter tileServerElevationJobs(LayerEngine engine) => (route) {
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
      return profileJob(url, zoom, points);
    };

/// Starts the sampling in a background isolate of its own, which [ElevationJob.stop] kills at once (also in the middle of
/// reading or decoding a tile, and with it what it held). The isolate is sent only the address, the zoom and the points, and
/// hands the profile back as it exits.
ElevationJob profileJob(String urlTemplate, int zoom, List<(double, double)> points) {
  final result = Completer<ElevationProfile>();
  final port = RawReceivePort();
  Isolate? isolate;
  var stopped = false;
  // One message ends the job: the profile, the isolate's uncaught error (a list of two), or its exit with neither (null).
  port.handler = (Object? message) {
    port.close();
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
  unawaited(Isolate.spawn(_profileIsolate, (port.sendPort, urlTemplate, zoom, points), onError: port.sendPort, onExit: port.sendPort).then<void>((i) {
    isolate = i;
    // Stopped before the isolate had started.
    if (stopped) i.kill(priority: Isolate.immediate);
  }, onError: (Object e, StackTrace st) {
    port.close();
    if (!result.isCompleted) result.completeError(e, st);
  }));
  return ElevationJob(result.future, onStop: () {
    stopped = true;
    isolate?.kill(priority: Isolate.immediate);
  });
}

/// The isolate of [profileJob].
Future<void> _profileIsolate((SendPort, String, int, List<(double, double)>) job) async {
  final (port, urlTemplate, zoom, points) = job;
  final tiles = LocalServerDemTiles(urlTemplate);
  final ElevationProfile profile;
  try {
    profile = await buildRouteProfile(points, tiles, zoom: zoom);
  } finally {
    tiles.close();
  }
  Isolate.exit(port, profile);
}
