import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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

/// Runs one real web search in the search core with [key] and answers the tool's message (the search results, or the tool's error
/// JSON). It throws when the core is not available.
typedef SearchProbe = Future<String> Function(String key);

/// Hands the web search settings to the search core (cs_set_web): provider (null: off), key, and whether the phone is online.
typedef WebSetter = Future<void> Function(String? provider, String? key, bool online);

const String _rejected = "Kagi didn't accept this key. Check you copied all of it.";

/// Turns what the core's web_search tool answered into the check: the tool's own error codes (key_missing, quota, fetch_failed,
/// bad_response; docs/TOOLS.md) in words for people. A message that is not the error JSON is a set of results: the key works.
/// A rejected key is the core's own `key_missing` ("web search key rejected": the core reads Kagi's `general.invalid_token` and a
/// 401/403 as that), never a bare status code here. Any other bad status comes back as `fetch_failed` with "(HTTP n)" in its detail:
/// 5xx is Kagi's own trouble; no status at all is a connection that did not work.
KeyCheck keyCheckFromToolContent(String content) {
  Map<String, dynamic>? j;
  try {
    final d = jsonDecode(content);
    if (d is Map<String, dynamic>) j = d;
  } catch (_) {}
  if (j == null || j['ok'] != false) return const KeyCheck.ok();
  final e = j['error'];
  final type = e is Map ? '${e['type']}' : '';
  final detail = e is Map ? '${e['detail']}' : '';
  switch (type) {
    case 'key_missing':
      return const KeyCheck.failed(_rejected);
    case 'quota':
      return const KeyCheck.failed('Kagi says this account has no search credit left, or has reached its limit. Check your balance, then try again.');
    case 'bad_response':
      return const KeyCheck.failed("Kagi answered with something Cache couldn't read. Try again later.");
    case 'fetch_failed':
      final m = RegExp(r'HTTP (\d{3})').firstMatch(detail);
      if (m == null) return const KeyCheck.failed("Couldn't reach Kagi. Check your connection.");
      final code = int.parse(m.group(1)!);
      if (code >= 500) return KeyCheck.failed('Kagi had a problem (HTTP $code). Try again in a moment.');
      return KeyCheck.failed('Kagi answered with an error (HTTP $code).');
  }
  return const KeyCheck.failed("Couldn't check the key. Try again.");
}

/// The search service for the assistant's web search: its key (kept in the phone's secure storage and never shown again), the
/// person's switch, and what the search core is told (cs_set_web: provider, key and whether the phone is online). The core has
/// the key in memory only; it is set again every time the key, the switch or the connection changes, and once the core opens.
class WebSearchSetup extends ChangeNotifier {
  WebSearchSetup({
    required this.settings,
    required this.secrets,
    required this.setWeb,
    SearchProbe? searchProbe,
    KeyChecker? check,
    ConnectionProbe? probe,
  }) : check = check ?? _viaCore(searchProbe),
       probe = probe ?? ConnectivityProbe();

  /// The check through the core's own web_search: the request the assistant will make, so a key that passes works.
  static KeyChecker _viaCore(SearchProbe? p) => (key) async {
    if (p == null) return const KeyCheck.failed("Couldn't check the key. Try again.");
    return keyCheckFromToolContent(await p(key));
  };

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
    if (!r.ok) {
      // The check lent the core the key for one search: put the core's settings back.
      await apply();
      return r;
    }
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
