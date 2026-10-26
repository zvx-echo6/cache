import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../browse/opds.dart' show cacheUserAgent;
import '../video/token_store.dart';
import 'app_settings.dart';
import 'data_policy.dart';

/// The answer of checking a key with its provider.
class KeyCheck {
  const KeyCheck.ok() : ok = true, message = null;
  const KeyCheck.failed(String this.message) : ok = false;

  final bool ok;

  /// Why the key was not accepted, in words for people (null when it was).
  final String? message;
}

typedef KeyChecker = Future<KeyCheck> Function(String key);

/// Hands the web search settings to the search core (cs_set_web): provider (null: off), key, and whether the phone is online.
typedef WebSetter = Future<void> Function(String? provider, String? key, bool online);

/// Checks a Kagi key with one real search for one result (the same request the search core makes). Kagi charges for searches, so
/// this is done once, when the key is saved, and never again.
Future<KeyCheck> checkKagiKey(String key, {Uri? address, Duration timeout = const Duration(seconds: 15)}) async {
  final client = HttpClient()
    ..userAgent = cacheUserAgent
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.postUrl(address ?? Uri.parse('https://kagi.com/api/v1/search')).timeout(timeout);
    req.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $key')
      ..contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'query': 'Cache', 'limit': 1})));
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    final code = res.statusCode;
    if (code >= 200 && code < 300) return const KeyCheck.ok();
    if (code == 401 || code == 403) return const KeyCheck.failed('Kagi did not accept this key. Check that you copied all of it.');
    if (code == 402 || code == 429) {
      return const KeyCheck.failed('Kagi accepted the key but says the account has no search credit left. Add credit, then try again.');
    }
    return KeyCheck.failed('Kagi answered with an error ($code). Try again in a moment.');
  } on TimeoutException {
    return const KeyCheck.failed("Kagi took too long to answer. Check the connection and try again.");
  } on SocketException {
    return const KeyCheck.failed("Can't reach Kagi. Check the connection and try again.");
  } on HandshakeException {
    return const KeyCheck.failed("Couldn't make a secure connection to Kagi.");
  } catch (_) {
    return const KeyCheck.failed("Couldn't check the key. Try again.");
  } finally {
    client.close(force: true);
  }
}

/// The search service for the assistant's web search: its key (kept in the phone's secure storage and never shown again), the
/// person's switch, and what the search core is told (cs_set_web: provider, key and whether the phone is online). The core has
/// the key in memory only; it is set again every time the key, the switch or the connection changes, and once the core opens.
class WebSearchSetup extends ChangeNotifier {
  WebSearchSetup({
    required this.settings,
    required this.secrets,
    required this.setWeb,
    KeyChecker? check,
    ConnectionProbe? probe,
  }) : check = check ?? checkKagiKey,
       probe = probe ?? ConnectivityProbe();

  /// Where the key is kept in secure storage.
  static const String keyName = 'search.kagi.key';

  /// The provider the search core knows (cs_set_web).
  static const String provider = 'kagi';

  final AppSettings settings;
  final TokenStore secrets;

  /// Tells the search core, once it is open (it does nothing when the core could not open).
  final WebSetter setWeb;
  final KeyChecker check;
  final ConnectionProbe probe;

  bool _hasKey = false;
  StreamSubscription<ConnectionKind>? _sub;

  /// A key is saved. (The key itself is never handed out again.)
  bool get hasKey => _hasKey;

  /// Web search is on: a key is saved and the switch is on.
  bool get active => _hasKey && settings.webSearchOn;

  Future<void> init() async {
    try {
      _hasKey = (await secrets.read(keyName))?.isNotEmpty == true;
    } catch (_) {
      _hasKey = false;
    }
    notifyListeners();
    _lastOn = settings.webSearchOn;
    settings.addListener(_onSettings);
    try {
      _sub = probe.changes.listen((_) => apply());
    } catch (_) {}
    await apply();
  }

  bool _lastOn = false;

  void _onSettings() {
    if (settings.webSearchOn == _lastOn) return;
    _lastOn = settings.webSearchOn;
    unawaited(apply());
  }

  /// Checks [raw] with the provider and, only if it is accepted, saves it and switches web search on. A key that fails the check is
  /// not saved. Returns the check, whose message says why when it failed.
  Future<KeyCheck> saveKey(String raw) async {
    final key = raw.trim();
    if (key.isEmpty) return const KeyCheck.failed('Paste your key first.');
    final KeyCheck r;
    try {
      r = await check(key);
    } catch (_) {
      return const KeyCheck.failed("Couldn't check the key. Try again.");
    }
    if (!r.ok) return r;
    try {
      await secrets.write(keyName, key);
    } catch (_) {
      return const KeyCheck.failed("The key was accepted but couldn't be saved on this phone.");
    }
    _hasKey = true;
    settings.setWebSearchOn(true);
    notifyListeners();
    await apply();
    return r;
  }

  /// Forgets the key and switches web search off.
  Future<void> removeKey() async {
    try {
      await secrets.delete(keyName);
    } catch (_) {}
    _hasKey = false;
    settings.setWebSearchOn(false);
    notifyListeners();
    await apply();
  }

  /// Sets the person's switch (it does nothing until a key is saved).
  Future<void> setEnabled(bool on) async {
    if (on && !_hasKey) return;
    settings.setWebSearchOn(on);
    notifyListeners();
    await apply();
  }

  /// Tells the search core: provider, key and online, or nothing when web search is off.
  Future<void> apply() async {
    try {
      if (!active) {
        await setWeb(null, null, false);
        return;
      }
      final key = await secrets.read(keyName);
      if (key == null || key.isEmpty) {
        await setWeb(null, null, false);
        return;
      }
      final online = await probe.current() != ConnectionKind.none;
      await setWeb(provider, key, online);
    } catch (e) {
      debugPrint('Web search setup: ${e.runtimeType}');
    }
  }

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    _sub?.cancel();
    super.dispose();
  }
}
