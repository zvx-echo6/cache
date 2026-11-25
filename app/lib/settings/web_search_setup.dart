import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../video/token_store.dart';
import '../weather/source_health.dart';
import 'app_settings.dart';
import 'data_policy.dart';
import '../platform/app_log.dart';

/// The answer of checking a key with its provider.
class KeyCheck {
  const KeyCheck.ok() : ok = true, message = null, kind = null;
  const KeyCheck.failed(String this.message, {this.kind = KeyFailure.other}) : ok = false;

  final bool ok;

  /// Why it failed, for the sheet's second button: [KeyFailure.limit] offers "Save anyway", [KeyFailure.offline] "Save without checking".
  final KeyFailure? kind;

  /// Why the key was not accepted, in words for people (null when it was).
  final String? message;
}

/// The causes of a failed key check the sheet tells apart.
enum KeyFailure { refused, limit, offline, other }

typedef KeyChecker = Future<KeyCheck> Function(String key);

/// Runs one real web search in the search core with [key] and answers the tool's message (the search results, or the tool's error
/// JSON). It throws when the core is not available.
typedef SearchProbe = Future<String> Function(String key);

/// Hands the web search settings to the search core (cs_set_web): provider (null: off), key, and whether the phone is online.
typedef WebSetter = Future<void> Function(String? provider, String? key, bool online);

const String _rejected = "Kagi didn't accept this key. Check you copied all of it.";

/// Turns what the core's web_search tool answered into the check: the tool's own error codes (key_missing, quota, fetch_failed,
/// bad_response; docs/TOOLS.md) in words for people. A message that is not the error JSON is a set of results: the key works.
/// A rejected key is the core's own `key_missing` ("That source isn't available right now.": the core reads Kagi's `general.invalid_token` and a
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
      return const KeyCheck.failed(_rejected, kind: KeyFailure.refused);
    case 'quota':
      return const KeyCheck.failed('Kagi says this account has no search credit left, or has reached its limit. Check your balance, then try again.', kind: KeyFailure.limit);
    case 'bad_response':
      return const KeyCheck.failed("Kagi answered with something Cache couldn't read. Try again later.");
    case 'fetch_failed':
      final m = RegExp(r'HTTP (\d{3})').firstMatch(detail);
      if (m == null) return const KeyCheck.failed("Can't reach Kagi. Check your connection.", kind: KeyFailure.offline);
      final code = int.parse(m.group(1)!);
      if (code >= 500) return KeyCheck.failed('Kagi had a problem (HTTP $code). Try again in a moment.');
      return KeyCheck.failed('Kagi answered with an error (HTTP $code).');
  }
  return const KeyCheck.failed("Couldn't check the key. Try again.");
}

/// How a web search went, from what the core's web_search tool answered: [SourceFailure.none] for results (or anything that is not the
/// tool's error JSON). A refused key (the core's `key_missing`, or a 401/403) is [SourceFailure.keyRejected]; its `quota` or a 429 is
/// [SourceFailure.limit]; the rest are trouble on the way, not for the person to fix.
SourceFailure searchFailureFrom(String content) {
  Map<String, dynamic>? j;
  try {
    final d = jsonDecode(content);
    if (d is Map<String, dynamic>) j = d;
  } catch (_) {}
  if (j == null || j['ok'] != false) return SourceFailure.none;
  final e = j['error'];
  final type = e is Map ? '${e['type']}' : '';
  final detail = e is Map ? '${e['detail']}' : '';
  switch (type) {
    case 'key_missing':
      return SourceFailure.keyRejected;
    case 'quota':
      return SourceFailure.limit;
    case 'bad_response':
      return SourceFailure.unreadable;
    case 'fetch_failed':
      final m = RegExp(r'HTTP (\d{3})').firstMatch(detail);
      if (m == null) return SourceFailure.unreachable;
      final code = int.parse(m.group(1)!);
      if (code == 401 || code == 403) return SourceFailure.keyRejected;
      return code == 429 ? SourceFailure.limit : SourceFailure.providerError;
  }
  return SourceFailure.providerError;
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

  SourceFailure _lastFailure = SourceFailure.none;

  /// How the assistant's last web search went (nothing is asked of Kagi to know); [SourceFailure.none] before any, and again after a
  /// new key or none.
  SourceFailure get lastFailure => _lastFailure;

  /// Notes what the core answered to a web search the assistant made.
  void noteSearch(String content) {
    final f = searchFailureFrom(content);
    if (f == _lastFailure) return;
    _lastFailure = f;
    notifyListeners();
  }

  /// What Settings > Weather and alerts says about web search, as for a source: off, needs a key (on without one), a key the last
  /// search was refused with, its limit, else working. Trouble on the way is not shown (the next search clears it anyway).
  SourceRowState get rowState {
    if (!settings.webSearchOn) return SourceRowState.off;
    if (!_hasKey) return SourceRowState.needsKey;
    return switch (_lastFailure) {
      SourceFailure.keyRejected || SourceFailure.keyMissing => SourceRowState.keyRejected,
      SourceFailure.limit => SourceRowState.limitReached,
      _ => SourceRowState.working,
    };
  }

  /// Web search is on: a key is saved and the switch is on.
  bool get active => _hasKey && settings.webSearchOn;

  /// Reads again whether a key is saved.
  Future<void> rescanKey() async {
    try {
      _hasKey = (await secrets.read(keyName))?.isNotEmpty == true;
    } catch (_) {
      _hasKey = false;
    }
    notifyListeners();
  }

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

  /// Checks [raw] with the provider and, only if it is accepted, saves it (turning nothing on). A key that fails the check is
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
      return const KeyCheck.failed("The key was accepted but couldn't be saved on this device.");
    }
    _hasKey = true;
    _lastFailure = SourceFailure.none;
    notifyListeners();
    await apply();
    return r;
  }

  /// Keeps a key a linked device sent (it was checked there) and uses it at once; the switch stays as the settings say.
  Future<void> keepKey(String raw) async {
    final key = raw.trim();
    if (key.isEmpty) return;
    await secrets.write(keyName, key);
    _hasKey = true;
    _lastFailure = SourceFailure.none;
    notifyListeners();
    await apply();
  }

  /// Forgets the key. The switch stays as it is: with no key Ask quietly uses what is on the device.
  Future<void> removeKey() async {
    try {
      await secrets.delete(keyName);
    } catch (_) {}
    _hasKey = false;
    _lastFailure = SourceFailure.none;
    notifyListeners();
    await apply();
  }

  /// Sets the person's switch. It is always usable; with no key web search stays silent ([active] needs both).
  Future<void> setEnabled(bool on) async {
    settings.setWebSearchOn(on);
    notifyListeners();
    await apply();
  }

  Map<String, dynamic>? _request;

  /// This tab's setting for a tool request in a browser (Cache Server's engine is shared): `{provider, reference, online}`, or null
  /// when web search is off. The reference is the server's `keystore://` name for the key; a raw key is never put here.
  Map<String, dynamic>? get requestWeb => _request;

  /// Tells the search core: provider, key and online, or nothing when web search is off.
  Future<void> apply() async {
    try {
      if (!active) {
        _request = null;
        await setWeb(null, null, false);
        return;
      }
      final key = await secrets.read(keyName);
      if (key == null || key.isEmpty) {
        _request = null;
        await setWeb(null, null, false);
        return;
      }
      final online = await probe.current() != ConnectionKind.none;
      _request = key.startsWith('keystore://') ? {'provider': provider, 'reference': key, 'online': online} : null;
      await setWeb(provider, key, online);
    } catch (e) {
      logError('Web search setup', error: e);
    }
  }

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    _sub?.cancel();
    super.dispose();
  }
}
