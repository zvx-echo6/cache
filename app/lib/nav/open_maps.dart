import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A tap on one of Android's guidance notifications (the turn-by-turn one as the phone shows it, and "Cache is on the car screen")
/// asks for the Maps tab, where guidance is (Android `OpenMaps.kt`: the notification opens the app's activity with the extra
/// `cache_open: maps`).
///
/// The activity hands it over on the channel `co.cache/open`: Dart pulls with `take` once at start (a tap that started the app
/// arrives before Dart listens) and receives `open` while the app runs. The shell listens ([addListener]) and takes it ([take]).
/// The iPhone posts no guidance notification, so nothing arrives there.
///
/// A `geo:` link opened from the phone's "Open with" list (no car connected) arrives the same way, as a map with `what: maps` and
/// the `lat`, `lon` and `query` the link carried ([MapsOpen]).
class MapsOpen {
  const MapsOpen({this.lat, this.lon, this.query});
  final double? lat;
  final double? lon;
  final String? query;
}

class OpenMapsInbox extends ChangeNotifier {
  OpenMapsInbox({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('co.cache/open');

  final MethodChannel _channel;
  bool _pending = false;
  MapsOpen? _geo;

  /// The Maps tab was asked for and not taken yet.
  bool get pending => _pending;

  /// Starts listening and takes a request the app was opened with. A platform with no such channel does nothing.
  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') offer(call.arguments);
      return null;
    });
    try {
      offer(await _channel.invokeMethod<String>('take'));
    } on MissingPluginException {
      // No native side here.
    } on PlatformException {
      // Nothing to take.
    }
  }

  /// What the activity sent: `maps` asks for the Maps tab; anything else is not this inbox's.
  void offer(Object? what) {
    if (what is Map && what['what'] == 'maps') {
      final q = (what['query'] as String?)?.trim();
      _geo = MapsOpen(lat: (what['lat'] as num?)?.toDouble(), lon: (what['lon'] as num?)?.toDouble(), query: q == null || q.isEmpty ? null : q);
    } else if (what != 'maps') {
      return;
    } else {
      _geo = null;
    }
    _pending = true;
    notifyListeners();
  }

  /// True once for each request.
  bool take() {
    final p = _pending;
    _pending = false;
    return p;
  }
}

/// The place or search a `geo:` link carried with the request just taken, once (null for a notification's tap).
extension MapsOpenTake on OpenMapsInbox {
  MapsOpen? takeGeo() {
    final g = _geo;
    _geo = null;
    return g;
  }
}

/// The app's inbox.
final OpenMapsInbox openMapsInbox = OpenMapsInbox();
