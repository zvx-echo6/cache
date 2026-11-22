import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where a `cachelink:` link from outside (a system camera, another app) waits until the Sharing page takes it.
///
/// The phone hands the link to the app natively (Android `MainActivity`, iPhone `SceneDelegate`) on the channel `co.cache/link`,
/// not through Flutter's own deep-link routing (switched off in the manifest and Info.plist). Dart pulls with `take` once at
/// start (a link that opened the app arrives before Dart listens) and receives `opened` while the app runs.
/// One link waits at most; a second one while one waits is dropped. While the app lock is on nothing consumes it, so it waits.
class LinkInbox extends ChangeNotifier {
  LinkInbox({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('co.cache/link');

  final MethodChannel _channel;
  String? _pending;
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether a Sharing page is open and takes links itself (the shell then does not open another).
  bool pageOpen = false;

  /// The link waiting, or null.
  String? get pending => _pending;

  /// Starts listening and takes a link the app was opened with. A platform with no such channel (browser, desktop) does nothing.
  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened' && call.arguments is String) offer(call.arguments as String);
      return null;
    });
    try {
      final first = await _channel.invokeMethod<String>('take');
      if (first != null) offer(first);
    } on MissingPluginException {
      // No native side here.
    } on PlatformException {
      // Nothing to take.
    }
  }

  /// A link arrived (also used by tests). Dropped when one already waits or it is the one just delivered twice.
  void offer(String link) {
    if (link.isEmpty || _pending != null || (link == _last && DateTime.now().difference(_lastAt) < const Duration(seconds: 2))) return;
    _pending = link;
    notifyListeners();
  }

  /// Hands over the waiting link, once.
  String? take() {
    final p = _pending;
    _pending = null;
    if (p != null) {
      // A link opened again later is a new one; only an immediate repeat (both native paths firing) is dropped.
      _last = p;
      _lastAt = DateTime.now();
    }
    return p;
  }
}

/// The app's inbox.
final LinkInbox linkInbox = LinkInbox();
