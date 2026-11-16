import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../app/lib/settings/key_names.dart';
import '../../../app/lib/sharing/settings_files.dart';
import '../../../app/lib/sharing/settings_log.dart';
import 'keystore.dart';

String _groupOf(String key) => settingsGroupOf(key);

/// Cache for Linux's settings sync, headless: the phone's SettingsSync (app/lib/sharing/settings_sync.dart) with no Flutter, run by the
/// helper. It keeps the settings log over `<support>/settings-sync` (settings_log.dart) as the one writer of the server's own log,
/// named by the host's engine id, with `<support>`'s files as the settings (settings_files.dart).
///
///  * Incoming: [shareChanged] (the settings share settled) and a timer read each linked peer's log from what was seen and apply
///    what is newer through settings_files.dart, for the links that take the key. No tab needs to be open. Every key is applied,
///    `ask.model` too (it writes `lastModel` only; the model loads when Ask is next used).
///  * Outgoing: FsOps calls [fileChanged] after a browser wrote a settings file; the keys of that file are compared with what was last
///    logged, and a changed one is appended if a link sends it (the phone's rule). A change made while sharing is not running, or
///    to a key no link sends, is noted and not sent.
///  * [applied] counts the changes applied; the host's `sharing.state` carries it so open tabs read their files again.
///
///  * Keys (the phone's pushKeys and takeKeys, over the host's `setSecrets` and `takeSecrets` and the [KeyStore]): the key names
///    ticked for a linked device (`.local/state.json`'s `keys`, the phone's own record) that are in the keystore go to it while its
///    link sends; the keys that arrive from a device whose link takes are written into the keystore, for the names the phone keeps
///    (`search.kagi.key`, `live.key.<alias>`) and no others. A key's value is never logged, written to the settings log or shown to
///    a tab: only its name.
class ServerSettingsSync {
  ServerSettingsSync({
    required this.support,
    required this.running,
    required this.myId,
    required this.peers,
    required this.askSince,
    DateTime Function()? now,
    this.every = const Duration(seconds: 10),
    this.log,
    this.keys,
    this.setSecrets,
    this.takeSecrets,
    this.onWebKeyKept,
  })  : _now = now ?? DateTime.now,
        _files = SettingsFiles(IoSettingsFileAccess(support), now: now),
        _dir = '${support.path}/$kSettingsShareDirName';

  /// The folder the settings share is (`<support>/settings-sync`, share_rules.dart `kSettingsShareDir`).
  static const String kSettingsShareDirName = 'settings-sync';

  final Directory support;
  final bool Function() running;
  final String? Function() myId;
  final List<Map<String, dynamic>> Function() peers;

  /// The host's `ask_since` (see SharingState.linkedSinceAsking).
  final int? Function() askSince;
  final DateTime Function() _now;
  final Duration every;
  final void Function(String message)? log;

  /// The server's keystore and the host's `setSecrets` / `takeSecrets`; keys sync only when all three are given.
  final KeyStore? keys;
  final Future<void> Function(String peer, Map<String, String> secrets)? setSecrets;
  final Future<Map<String, Map<String, String>>> Function()? takeSecrets;

  /// Called once after a take that kept the web search key (`search.kagi.key`): the helper gives the core its web search settings
  /// again (keys.replay), so the new key is used at once. A weather key (`live.key.*`) has no such call: the core holds it from a
  /// tab's `liveSetKey`, so it is used after a tab next pushes it (the accepted weather gap).
  final void Function()? onWebKeyKept;
  final SettingsFiles _files;
  final String _dir;

  final SettingsLogState _kept = SettingsLogState();
  SettingsLog? _log;
  Timer? _timer;
  bool _started = false;
  Future<void> _chain = Future.value();
  int _applied = 0;
  bool _wasRunning = false;
  String _links = '';
  final Map<String, Map<String, String>> _pushed = {};

  /// How many setting changes from linked devices were applied here.
  int get applied => _applied;

  static const Set<String> _files4 = {'settings.json', 'layout.json', 'preferences.json', 'maps.json'};
  static const String _catalogues = 'live-catalogues/';

  /// Whether [rel] (a path under the support folder) is a file some synced setting lives in.
  static bool isSettingsFile(String rel) => _files4.contains(rel) || (rel.startsWith(_catalogues) && rel.length > _catalogues.length);

  static List<String> _keysOf(String rel) => rel.startsWith(_catalogues)
      ? [for (final e in kSettingsFileMap.entries) if (e.value.file.startsWith(_catalogues)) e.key]
      : [for (final e in kSettingsFileMap.entries) if (e.value.file == rel) e.key];

  Future<T> _locked<T>(Future<T> Function() f) {
    final done = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        done.complete(await f());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  SettingsLog _logFor() {
    final me = myId() ?? '';
    final l = _log;
    if (l != null && l.device == me) return l;
    return _log = SettingsLog(dir: _dir, device: me, state: _kept);
  }

  Future<String?> _read(String key) async {
    try {
      return canonical(await _files.read(key));
    } catch (_) {
      return null;
    }
  }

  /// Reads what was kept and notes every setting as it is now (a value that changed while the helper was not watching is noted, not
  /// sent), then starts the timer.
  Future<void> start() => _locked(() async {
        if (_started) return;
        _started = true;
        await _logFor().loadState();
        for (final k in kSettingsFileMap.keys) {
          final v = await _read(k);
          if (v != null) _kept.last[k] = v;
        }
        await _save();
        _timer = Timer.periodic(every, (_) => unawaited(tick()));
      });

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _save() async {
    try {
      await _logFor().saveState();
    } catch (e) {
      log?.call('settings sync: could not keep its state: $e');
    }
  }

  // ---------------------------------------------------------------- links

  SettingsLink _linkWith(String peer, Map<String, dynamic> record) {
    final linked = record['linked'];
    final since = askSince();
    final link = (record['link'] as Map?)?.cast<String, Object?>();
    return linkOfRecord(link, peer: peer, myId: myId(), linkedSinceAsking: since != null && linked is int && linked >= since);
  }

  Map<String, Object?> _recordOf(Map<String, dynamic> p) => {...?(p['link'] as Map?)?.cast<String, Object?>()};

  bool _on(Map<String, dynamic> p, String key) => linkIncludes(_recordOf(p), group: _groupOf(key), key: key);

  bool _sendsAny(String key) => peers().any((p) {
        final id = p['id'];
        return id is String && linkSends(_linkWith(id, p)) && _on(p, key);
      });

  String _linkSignature() => [for (final p in peers()) '${p['id']}=${canonical(p['link'])}'].join(';');

  // ---------------------------------------------------------------- keys

  bool get _keysOn => keys != null && setSecrets != null && takeSecrets != null;

  /// The key name the browser's store keeps [name] under in the keystore (a name of only letters, digits and `. _ -` is itself).
  static String keystoreNameOf(String name) => encodeKeyName(name);

  /// The names of keys that sync (the phone's keepSyncedKey): the web search key and a weather source's key.
  static bool isSyncedKeyName(String name) {
    if (name == 'search.kagi.key') return true;
    const prefix = 'live.key.';
    return name.startsWith(prefix) && name.length > prefix.length;
  }

  static String _shown(String name) => name.length > 120 ? '${name.substring(0, 120)}...' : name;

  /// The key [name] is ticked for [peer]. Every key starts off.
  bool keyOn(String peer, String name) => _kept.keysFor[peer]?.contains(name) ?? false;

  /// Ticks or unticks the key [name] for [peer], keeps it, and gives the keys to the engine.
  Future<void> setKeyOn(String peer, String name, bool on) => _locked(() async {
        final set = _kept.keysFor.putIfAbsent(peer, () => <String>{});
        on ? set.add(name) : set.remove(name);
        if (set.isEmpty) _kept.keysFor.remove(peer);
        await _save();
        await _pushKeys();
      });

  /// Gives the engine, for each linked device, the ticked keys that are in the keystore while that device's link sends; nothing to
  /// the others. A reference (`keystore://...`) is never a key and is never sent.
  Future<void> _pushKeys() async {
    if (!_keysOn || !running()) return;
    final store = keys!;
    for (final p in peers()) {
      final id = p['id'];
      if (id is! String) continue;
      final out = <String, String>{};
      if (linkSends(_linkWith(id, p))) {
        for (final name in (_kept.keysFor[id] ?? const <String>{}).toList()..sort()) {
          if (!isSyncedKeyName(name)) continue;
          final v = store.get(keystoreNameOf(name));
          if (v != null && v.isNotEmpty && !v.startsWith(KeyStore.refPrefix)) out[name] = v;
        }
      }
      final before = _pushed[id];
      if (before != null && _sameMap(before, out)) continue;
      try {
        await setSecrets!(id, out);
        _pushed[id] = out;
      } catch (e) {
        log?.call('settings sync: could not give the keys for a device (${out.length} key(s))');
      }
    }
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// Writes the keys linked devices sent into the keystore, from the devices whose settings this one takes. A name this app does
  /// not keep is dropped, and logged by name.
  Future<void> _takeKeys() async {
    if (!_keysOn) return;
    Map<String, Map<String, String>> got;
    try {
      got = await takeSecrets!();
    } catch (_) {
      return;
    }
    var webKept = false;
    final byId = {for (final p in peers()) if (p['id'] is String) p['id'] as String: p};
    for (final e in got.entries) {
      final p = byId[e.key];
      if (p == null || !linkTakes(_linkWith(e.key, p))) continue;
      for (final k in e.value.entries) {
        final name = k.key;
        if (!isSyncedKeyName(name) || k.value.isEmpty) {
          log?.call('settings sync: dropped a key this server does not keep: ${_shown(name)}');
          continue;
        }
        try {
          keys!.set(keystoreNameOf(name), k.value);
          if (name == 'search.kagi.key') webKept = true;
        } catch (_) {
          log?.call('settings sync: could not keep the key ${_shown(name)}');
        }
      }
    }
    if (webKept) {
      try {
        onWebKeyKept?.call();
      } catch (e) {
        log?.call('settings sync: could not use the web search key at once: $e');
      }
    }
  }

  // ---------------------------------------------------------------- changes from linked devices

  /// The settings share changed (the host's onShareChanged): read the peers' logs.
  Future<void> shareChanged(Set<String> ids) async {
    if (ids.contains('settings')) await tick();
  }

  /// One look at the peers' logs (the timer and [shareChanged]).
  Future<void> tick() => _locked(() async {
        if (!_started || !running() || myId() == null) {
          _wasRunning = false;
          return;
        }
        final sig = _linkSignature();
        if (!_wasRunning) {
          // sharing has just started: the keys are given to the engine again
          _wasRunning = true;
          _pushed.clear();
          _links = sig;
          await _pushKeys();
        } else if (sig != _links) {
          // a link changed (here, or the other device's choice arrived)
          _links = sig;
          await _pushKeys();
        }
        await _takeKeys();
        await _pull();
      });

  Future<void> _pull() async {
    final me = myId()!;
    final slog = _logFor();
    var changed = false;
    for (final p in peers()) {
      final id = p['id'];
      if (id is! String || id == me) continue;
      final link = _linkWith(id, p);
      if (!linkTakes(link)) continue;
      final read = await slog.readPeer(id);
      if (read == null) continue;
      for (final e in read.latest.entries) {
        final key = e.key;
        if (!kSettingsFileMap.containsKey(key) || !_on(p, key)) continue;
        final (line, ev) = e.value;
        if (!slog.state.isUnseen(id, key, line)) continue;
        slog.state.markSeen(id, key, line);
        changed = true;
        final current = await _read(key);
        if (current == null) continue;
        if (current == canonical(ev.value)) continue;
        if (!applies(link, ev, current: current, localAt: _kept.localAt[key] ?? 0)) continue;
        // which setting, and which device (its id's start); never the value
        log?.call('settings sync: applying $key from device ${id.length > 8 ? id.substring(0, 8) : id}');
        try {
          // _last is set first and again after, so that what was written is never read as a change made here
          _kept.last[key] = canonical(ev.value);
          await _files.write(key, ev.value);
          _kept.localAt[key] = ev.at;
          _applied++;
        } catch (err) {
          log?.call('settings sync: could not apply $key: $err');
        }
        final now = await _read(key);
        if (now != null) _kept.last[key] = now;
      }
    }
    if (changed) await _save();
  }

  // ---------------------------------------------------------------- changes made in a browser

  /// A browser wrote [rel] (a path under the support folder, with "/"). Each setting in it that is not what was last logged is a
  /// change made here: noted, and appended when a link sends it.
  Future<void> fileChanged(String rel) {
    if (!isSettingsFile(rel)) return Future.value();
    return _locked(() async {
      if (!_started) return;
      final me = myId();
      final send = running() && me != null;
      var any = false;
      for (final key in _keysOf(rel)) {
        final v = await _read(key);
        if (v == null) continue;
        final before = _kept.last[key];
        if (before == v) continue;
        _kept.last[key] = v;
        any = true;
        final at = _now().millisecondsSinceEpoch;
        _kept.localAt[key] = at;
        _kept.waiting.remove(key);
        if (!send || !_sendsAny(key)) continue;
        try {
          await _logFor().append(SettingsEvent(
            at: at,
            dev: me,
            key: key,
            value: jsonDecode(v),
            hasPrev: before != null,
            prev: before == null ? null : jsonDecode(before),
          ));
        } catch (e) {
          log?.call('settings sync: could not write a change ($key): $e');
        }
      }
      if (any) await _save();
    });
  }
}
