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

  String? _routeId;
  ElevationProfile? _profile;
  bool _loading = false;
  bool _open = false;

  /// The profile of the route last asked for, or null while it is worked out (or when there is no route).
  ElevationProfile? get profile => _profile;
  bool get loading => _loading;

  /// The panel on the guidance card is pulled up.
  bool get open => _open;

  /// The profile for [route] (null: none). The same route again does nothing. Another route, or none, stops the job that was
  /// running for the one before.
  void request(MapRoute? route) {
    if (route == null) {
      if (_routeId == null) return;
      _routeId = null;
      _stopJob();
      _profile = null;
      _loading = false;
      notifyListeners();
      return;
    }
    if (route.routeId == _routeId) return;
    _stopJob();
    final id = _routeId = route.routeId;
    _profile = null;
    _loading = true;
    notifyListeners();
    // A listener asked for something else meanwhile: that request has its own job.
    if (_disposed || _routeId != id) return;
    final ElevationJob job;
    try {
      job = _start(route);
    } catch (_) {
      _profile = ElevationProfile.none(route.distanceM);
      _loading = false;
      notifyListeners();
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
      _job = null;
      _profile = p;
      _loading = false;
      notifyListeners();
    }());
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
  /// measure the same line slightly differently).
  double? positionOnProfile(double? distanceAlongM, double routeM) {
    final p = _profile;
    if (p == null || distanceAlongM == null || routeM <= 0) return null;
    return (distanceAlongM * p.totalM / routeM).clamp(0, p.totalM).toDouble();
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
