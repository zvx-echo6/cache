import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../files.dart';
import '../platform/app_log.dart';
import 'sharing_state.dart';

/// The settings log's share: one folder linked devices keep the same, kept only with the devices settings go to or come from
/// (Match and Send mine), never listed under Sharing and sync; this device's page governs it.
const String kSettingsShareId = 'settings';
const String kSettingsShareDir = 'settings-sync';

/// The person's Bookshelves log (packages/cache_shelves): kept only with Match devices, never listed under Sharing and sync.
const String kBookshelvesShareId = 'bookshelves';
const String kBookshelvesDir = 'bookshelves';

/// The link kinds each of those folders is kept with (cache_sync's `with`).
const List<String> kSettingsShareModes = ['match', 'send'];
const List<String> kBookshelvesShareModes = ['match'];

/// The chosen Ask model's setting: a model not on this device waits, with Download.
const String kModelSettingKey = 'ask.model';

/// The saved places weather watches: one that has not come to this device yet says "waiting for this place".
const String kWatchPlacesKey = 'weather.watch_places';

/// The name of the model a waiting change uses ("Gemma 4 E2B · Q4_K_M"; its file name when the other device knew no better).
String waitingModelName(SettingsEvent ev) {
  final n = ev.note is Map ? (ev.note as Map)['name'] : null;
  return n is String && n.isNotEmpty ? n : '${ev.value}';
}

/// Where the model a waiting change uses downloads from ({repo, path, size, sha256, revision, url}), when the other device
/// knew; null otherwise.
Map<String, Object?>? waitingModelDownload(SettingsEvent ev) {
  final d = ev.note is Map ? (ev.note as Map)['download'] : null;
  return d is Map ? d.cast<String, Object?>() : null;
}

/// The groups under What's included, in their order there.
enum SettingsGroupId {
  appearance('Appearance', 'Theme, module icons, dark PDF pages'),
  home('Home screen', 'Layout and shortcuts'),
  weather('Weather and alerts', 'Sources on, what weather watches, your own sources'),
  notifications('Notifications', 'Which alerts pop up, quiet hours'),
  maps('Map layers', 'Which layers are on'),
  ask('Ask', 'Model, web search');

  const SettingsGroupId(this.label, this.summary);

  final String label;

  /// What the group holds, as its row says it.
  final String summary;
}

/// What never goes between devices, as the What's included page says it.
const String kNeverSynced =
    'Device name, mobile data downloads, indexing speed, space kept free, log level, Obsidian and Logseq connections, and the '
    'permissions each device asks for itself.';

/// How settings go between this device and one linked device.
enum SettingsLink {
  /// Changes on either device go to both.
  match,

  /// This device's changes go to the other; the other's own changes stay there.
  sending,

  /// The other device's changes come here; this device's own changes stay here.
  receiving,

  /// Each keeps its own.
  off,
}

/// One setting that can go between devices: its value as JSON ([read]), how it is set here ([write], applied at once, never
/// needing a restart) and what tells when it changes ([listenable]). [write] returns false when the value cannot be used here
/// yet (a model not on this device): it is kept waiting, shown, and tried again when [listenable] changes.
class SyncedSetting {
  const SyncedSetting({
    required this.key,
    required this.group,
    required this.label,
    required this.listenable,
    required this.read,
    required this.write,
    this.note,
    this.shows,
  });

  final String key;
  final SettingsGroupId group;
  final String label;
  final Listenable listenable;
  final Object? Function() read;
  final Future<bool> Function(Object? value) write;

  /// What goes with a change so the other device can show it (a model's name and where to download it, the names of watched
  /// places); never applied.
  final Object? Function()? note;

  /// What it is set to here, in words, for its row ("Dark", "3 sources on").
  final String Function()? shows;
}

/// One key kept in secure storage that can be sent to one linked device: [name] is where it is kept, [read] gives it.
class SyncedKey {
  const SyncedKey({required this.name, required this.label, required this.read});

  final String name;
  final String label;
  final Future<String?> Function() read;
}

/// One change to one setting, as a line of a device's settings log.
@immutable
class SettingsEvent {
  const SettingsEvent({required this.at, required this.dev, required this.key, required this.value, this.hasPrev = false, this.prev, this.note});

  final int at;
  final String dev;
  final String key;
  final Object? value;

  /// The value before the change, when known (a change made here); a device's settings sent as they are when the link is
  /// switched on have none.
  final bool hasPrev;
  final Object? prev;
  final Object? note;

  static SettingsEvent? fromLine(String line) {
    Object? j;
    try {
      j = jsonDecode(line.trim());
    } catch (_) {
      return null;
    }
    if (j is! Map || j['v'] != 1) return null;
    final at = j['at'], dev = j['dev'], key = j['k'];
    if (at is! int || dev is! String || dev.isEmpty || key is! String || key.isEmpty || !j.containsKey('val')) return null;
    return SettingsEvent(at: at, dev: dev, key: key, value: j['val'], hasPrev: j.containsKey('prev'), prev: j['prev'], note: j['note']);
  }

  String toLine() => jsonEncode({'v': 1, 'at': at, 'dev': dev, 'k': key, 'val': value, if (hasPrev) 'prev': prev, if (note != null) 'note': note});
}

/// A JSON value in one spelling (map keys sorted), so two equal values compare equal.
String canonical(Object? v) => jsonEncode(_canon(v));

Object? _canon(Object? v) {
  if (v is Map) {
    final keys = [for (final k in v.keys) '$k']..sort();
    return {for (final k in keys) k: _canon(v[k])};
  }
  if (v is List) return [for (final x in v) _canon(x)];
  return v;
}

/// Whether a change from a linked device is applied here, the value here being [current] ([canonical]) and last changed at
/// [localAt]. From a device this one follows (Send mine), every change it makes is: a change made here stands until that device
/// next changes the same setting. With Match the latest change wins, except that a change made on a value this device still
/// has (its previous value is the value here) applies whatever the clocks say: only one side changed it.
bool applies(SettingsLink link, SettingsEvent ev, {required String current, required int localAt}) => switch (link) {
  SettingsLink.receiving => true,
  SettingsLink.match => (ev.hasPrev && canonical(ev.prev) == current) || ev.at > localAt,
  SettingsLink.sending || SettingsLink.off => false,
};

/// Settings between linked devices, per setting, never as one whole settings file. Each change made here is an event (setting,
/// value, its previous value, time, device) appended to this device's own log in the settings share, `log/<device>.jsonl`, one
/// writer per file (as the library logs). Every device reads the logs of the devices whose settings it takes and applies each
/// setting's latest change ([applies]). What it last saw of each log and when each setting last changed here are kept beside
/// the logs in `.local/` (a hidden folder, which never syncs).
///
/// How settings go is kept per link, the same on both devices (the sync engine's `set_link`): `{mode, from, off_groups,
/// off_keys}`. The device it is chosen on is where settings come from: switching Match or Send mine on sends its included
/// settings as they are. Keys are never in the log: each key ticked for a device is given to the sync engine for that device
/// alone ([SharingState.setSecrets]), which holds it in memory and sends it only to that device over its own encrypted
/// connection; the device keeps it in its secure storage ([storeKey]).
class SettingsSync extends ChangeNotifier {
  SettingsSync({
    required this.sharing,
    required this.settings,
    required this.keys,
    required this.storeKey,
    required this.dir,
    this.downloadModel,
    this.placesHere,
    DateTime Function()? now,
    this.every = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now {
    _byKey = {for (final s in settings) s.key: s};
  }

  final SharingState sharing;

  /// Every setting that can go between devices. A setting not here never goes, and is never taken from another device's log.
  final List<SyncedSetting> settings;

  /// The keys saved on this device.
  final List<SyncedKey> Function() keys;

  /// Keeps a key a linked device sent; false when [name] is not a key this app keeps.
  final Future<bool> Function(String name, String value) storeKey;

  /// The settings share's folder.
  final Future<Directory?> Function() dir;
  final DateTime Function() _now;
  final Duration every;

  /// Starts the download of a model a linked device uses ([waitingModelDownload]); only when the person taps Download.
  final Future<void> Function(Map<String, Object?> download)? downloadModel;

  /// The saved places on this device, by key.
  final Future<Set<String>> Function()? placesHere;

  late final Map<String, SyncedSetting> _byKey;

  /// When each setting last changed here (made here, or taken from another device: that change's time), by key.
  final Map<String, int> _localAt = {};

  /// Each setting's value as last seen, by key ([canonical]).
  final Map<String, String> _last = {};

  /// What was read of each device's log: by device, by setting, the line of the latest change taken.
  final Map<String, Map<String, int>> _seen = {};

  /// The keys ticked for each device, by device (their secure-storage names).
  final Map<String, Set<String>> _keysFor = {};

  /// Changes taken that cannot be used here yet (a model not on this device), by key, with their note.
  final Map<String, SettingsEvent> _waiting = {};

  /// The note of the change each setting last took from another device, by key.
  final Map<String, Object?> _notes = {};

  /// The keys last given to the sync engine for each device (in memory only).
  final Map<String, Map<String, String>> _pushed = {};

  final Set<String> _applying = {};
  final List<VoidCallback> _unlisten = [];
  Timer? _timer;
  Directory? _dir;
  bool _started = false;
  bool _wasRunning = false;
  String _links = '';

  bool get started => _started;

  Future<Directory?> _folder() async => _dir ??= await dir();

  File? _stateFile() => _dir == null ? null : File('${_dir!.path}/.local/state.json');

  /// Reads what was kept, notes every setting as it is now, and starts listening for changes.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final d = await _folder();
    await _readState();
    final first = _last.isEmpty;
    for (final s in settings) {
      final v = _read(s);
      if (v == null) continue;
      // A value that changed while Cache was not watching (set by an earlier version) is noted, not sent.
      _last[s.key] = v;
    }
    if (first) await _saveState();
    final groups = <Listenable, List<SyncedSetting>>{};
    for (final s in settings) {
      groups.putIfAbsent(s.listenable, () => []).add(s);
    }
    for (final e in groups.entries) {
      void on() => _changed(e.value);
      e.key.addListener(on);
      _unlisten.add(() => e.key.removeListener(on));
    }
    void onSharing() => _onSharing();
    sharing.addListener(onSharing);
    _unlisten.add(() => sharing.removeListener(onSharing));
    if (d != null) _timer = Timer.periodic(every, (_) => unawaited(tick()));
    unawaited(tick());
  }

  String? _read(SyncedSetting s) {
    try {
      return canonical(s.read());
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- links

  /// How settings go between this device and [peer]. A link with nothing chosen yet (made before this version) is Match.
  SettingsLink linkWith(String peer) {
    final l = sharing.linkOf(peer);
    switch (l?['mode']) {
      case 'off':
        return SettingsLink.off;
      case 'send':
        final from = l?['from'];
        if (from == peer) return SettingsLink.receiving;
        if (from == sharing.myId) return SettingsLink.sending;
        return SettingsLink.off;
      default:
        return SettingsLink.match;
    }
  }

  bool _sendsTo(String peer) => const {SettingsLink.match, SettingsLink.sending}.contains(linkWith(peer));
  bool _takesFrom(String peer) => const {SettingsLink.match, SettingsLink.receiving}.contains(linkWith(peer));

  Map<String, Object?> _linkValue(String peer) => {...?sharing.linkOf(peer)};

  Set<String> _list(Map<String, Object?> l, String k) => {for (final x in (l[k] as List? ?? const [])) '$x'};

  /// Chooses how settings go with [peer] (Match, Send mine or Off; not [SettingsLink.receiving], which is the other device's
  /// Send mine). Switching Match or Send mine on makes this device where they come from: its included settings go as they are.
  Future<void> setLink(String peer, SettingsLink to) async {
    if (to == SettingsLink.receiving) throw ArgumentError('Receiving is chosen on the other device');
    final was = linkWith(peer);
    if (was == to) return;
    final l = _linkValue(peer)
      ..['mode'] = switch (to) {
        SettingsLink.match => 'match',
        SettingsLink.sending => 'send',
        _ => 'off',
      }
      ..['from'] = sharing.myId;
    await sharing.setLink(peer, l);
    if (to != SettingsLink.off) await _seed([for (final s in settings) if (settingOn(peer, s.key)) s.key]);
    _links = _linkSignature();
    await pushKeys();
    notifyListeners();
  }

  /// [g] is included with [peer].
  bool groupOn(String peer, SettingsGroupId g) => !_list(_linkValue(peer), 'off_groups').contains(g.name);

  /// The setting [key] is included with [peer]: its group is, and it is not unticked.
  bool settingOn(String peer, String key) {
    final s = _byKey[key];
    if (s == null) return false;
    final l = _linkValue(peer);
    return !_list(l, 'off_groups').contains(s.group.name) && !_list(l, 'off_keys').contains(key);
  }

  List<SyncedSetting> settingsOf(SettingsGroupId g) => [for (final s in settings) if (s.group == g) s];

  /// Includes or leaves out a whole group (every setting in it).
  Future<void> setGroupOn(String peer, SettingsGroupId g, bool on) async {
    final l = _linkValue(peer);
    final groups = _list(l, 'off_groups');
    final off = _list(l, 'off_keys');
    final before = {for (final s in settingsOf(g)) if (settingOn(peer, s.key)) s.key};
    on ? groups.remove(g.name) : groups.add(g.name);
    if (on) off.removeAll(settingsOf(g).map((s) => s.key));
    await _setLists(peer, l, groups, off);
    if (on) await _seedFor(peer, [for (final s in settingsOf(g)) if (!before.contains(s.key)) s.key]);
  }

  /// Includes or leaves out one setting. Including one of a group that is left out includes the group with that setting alone.
  Future<void> setSettingOn(String peer, String key, bool on) async {
    final s = _byKey[key];
    if (s == null) return;
    final l = _linkValue(peer);
    final groups = _list(l, 'off_groups');
    final off = _list(l, 'off_keys');
    if (on && groups.contains(s.group.name)) {
      groups.remove(s.group.name);
      off.addAll([for (final x in settingsOf(s.group)) if (x.key != key) x.key]);
    }
    on ? off.remove(key) : off.add(key);
    await _setLists(peer, l, groups, off);
    if (on) await _seedFor(peer, [key]);
  }

  Future<void> _setLists(String peer, Map<String, Object?> l, Set<String> groups, Set<String> off) async {
    l['off_groups'] = groups.toList()..sort();
    l['off_keys'] = off.toList()..sort();
    l['mode'] ??= 'match';
    await sharing.setLink(peer, l);
    notifyListeners();
  }

  Future<void> _seedFor(String peer, List<String> keys) async {
    if (_sendsTo(peer) && keys.isNotEmpty) await _seed(keys);
  }

  /// "6 of 6", how many groups are included with [peer].
  int groupsOn(String peer) => SettingsGroupId.values.where((g) => groupOn(peer, g) && settingsOf(g).any((s) => settingOn(peer, s.key))).length;

  // ---------------------------------------------------------------- changes made here

  void _changed(List<SyncedSetting> list) {
    var any = false;
    for (final s in list) {
      final v = _read(s);
      if (v == null) continue;
      final before = _last[s.key];
      if (before == v) {
        // A value that could not be used before may be usable now (the model arrived).
        if (_waiting.containsKey(s.key)) unawaited(_retry(s));
        continue;
      }
      _last[s.key] = v;
      any = true;
      if (_applying.contains(s.key)) continue;
      final at = _now().millisecondsSinceEpoch;
      _localAt[s.key] = at;
      _waiting.remove(s.key);
      if (!_sendsAny(s.key)) continue;
      _write(SettingsEvent(
        at: at,
        dev: sharing.myId ?? '',
        key: s.key,
        value: jsonDecode(v),
        hasPrev: before != null,
        prev: before == null ? null : jsonDecode(before),
        note: _noteOf(s),
      ));
    }
    if (any) unawaited(_saveState());
  }

  Object? _noteOf(SyncedSetting s) {
    try {
      return s.note?.call();
    } catch (_) {
      return null;
    }
  }

  /// [key] goes to at least one linked device: a link that sends, which includes it.
  bool _sendsAny(String key) => sharing.peers.any((p) {
    final id = p['id'];
    return id is String && _sendsTo(id) && settingOn(id, key);
  });

  /// Sends [keys] as they are now: the link was switched on here, or they were included.
  Future<void> _seed(Iterable<String> keys) async {
    final at = _now().millisecondsSinceEpoch;
    for (final k in keys) {
      final s = _byKey[k];
      if (s == null) continue;
      final v = _read(s);
      if (v == null) continue;
      _localAt[k] = at;
      _write(SettingsEvent(at: at, dev: sharing.myId ?? '', key: k, value: jsonDecode(v), note: _noteOf(s)));
    }
    await flush();
    await _saveState();
  }

  Future<void> _writes = Future.value();

  /// Appends [ev] after the lines being written now, so the log keeps the order the changes were made in.
  void _write(SettingsEvent ev) => _writes = _writes.then((_) => _append(ev));

  /// Waits for the changes being written to the log.
  Future<void> flush() => _writes;

  Future<void> _append(SettingsEvent ev) async {
    final me = sharing.myId;
    final d = await _folder();
    if (me == null || d == null || ev.dev != me) return;
    try {
      final f = File('${d.path}/log/$me.jsonl');
      await f.parent.create(recursive: true);
      await f.writeAsString('${ev.toLine()}\n', mode: FileMode.append, flush: true);
    } catch (e) {
      logError('Settings sync: could not write a change', error: e, detail: ev.key);
    }
  }

  // ---------------------------------------------------------------- changes from linked devices

  /// One look: when sharing has just started, the keys are given to the engine; then the keys that came are kept and the logs
  /// of the devices whose settings this one takes are read.
  Future<void> tick() async {
    if (!sharing.running || sharing.myId == null) {
      _wasRunning = false;
      return;
    }
    if (!_wasRunning) {
      _wasRunning = true;
      _pushed.clear();
      _links = _linkSignature();
      await pushKeys();
    }
    await takeKeys();
    await pull();
  }

  String _linkSignature() => [for (final p in sharing.peers) '${p['id']}=${canonical(p['link'])}'].join(';');

  /// A link changed (here, or the other device's choice arrived): keys and settings follow it.
  void _onSharing() {
    if (!sharing.running) return;
    final sig = _linkSignature();
    if (sig == _links) return;
    _links = sig;
    unawaited(() async {
      await pushKeys();
      await pull();
      notifyListeners();
    }());
  }

  /// Applies what the devices whose settings this one takes changed since the last look.
  Future<void> pull() async {
    final me = sharing.myId;
    final d = await _folder();
    if (me == null || d == null) return;
    var changed = false;
    for (final p in sharing.peers) {
      final id = p['id'];
      if (id is! String || id == me || !_takesFrom(id)) continue;
      final f = File('${d.path}/log/$id.jsonl');
      List<String> lines;
      try {
        if (!await f.exists()) continue;
        lines = (await f.readAsString()).split('\n');
      } catch (_) {
        continue;
      }
      final seen = _seen.putIfAbsent(id, () => {});
      // A log that got shorter was started again: read it all again.
      if (seen.values.any((n) => n > lines.length)) seen.clear();
      final latest = <String, (int, SettingsEvent)>{};
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trim().isEmpty) continue;
        final ev = SettingsEvent.fromLine(lines[i]);
        if (ev == null || ev.dev != id) continue;
        latest[ev.key] = (i + 1, ev);
      }
      final link = linkWith(id);
      for (final e in latest.entries) {
        final s = _byKey[e.key];
        if (s == null || !settingOn(id, e.key)) continue;
        final (line, ev) = e.value;
        if ((seen[e.key] ?? 0) >= line) continue;
        seen[e.key] = line;
        changed = true;
        final current = _read(s);
        if (current == null) continue;
        if (current == canonical(ev.value)) {
          _waiting.remove(e.key);
          continue;
        }
        if (!applies(link, ev, current: current, localAt: _localAt[e.key] ?? 0)) continue;
        await _apply(s, ev);
      }
    }
    if (changed) {
      await _saveState();
      notifyListeners();
    }
  }

  Future<void> _apply(SyncedSetting s, SettingsEvent ev) async {
    _notes[s.key] = ev.note;
    _applying.add(s.key);
    bool ok;
    try {
      _last[s.key] = canonical(ev.value);
      ok = await s.write(ev.value);
    } catch (e) {
      logError('Settings sync: could not apply a change', error: e, detail: s.key);
      ok = false;
    } finally {
      _applying.remove(s.key);
    }
    final now = _read(s);
    if (now != null) _last[s.key] = now;
    if (ok) {
      _waiting.remove(s.key);
      _localAt[s.key] = ev.at;
    } else {
      _waiting[s.key] = ev;
    }
  }

  Future<void> _retry(SyncedSetting s) async {
    final ev = _waiting[s.key];
    if (ev == null || _applying.contains(s.key)) return;
    await _apply(s, ev);
    if (!_waiting.containsKey(s.key)) {
      await _saveState();
      notifyListeners();
    }
  }

  /// A change taken that cannot be used here yet, by setting key (the model a linked device uses, not downloaded here).
  SettingsEvent? waiting(String key) => _waiting[key];

  /// What came with the change [key] last took from a linked device (see [SyncedSetting.note]).
  Object? noteOf(String key) => _notes[key];

  /// The watched saved places that are not on this device yet ([here]: the saved places here, by key), by name when the other
  /// device named them.
  List<String> placesNotHere(Set<String>? here) {
    final s = _byKey[kWatchPlacesKey];
    if (s == null || here == null) return const [];
    final watched = s.read();
    final names = _notes[kWatchPlacesKey] is Map ? (_notes[kWatchPlacesKey] as Map) : const {};
    return [
      for (final k in (watched is List ? watched : const []))
        if (k is String && !here.contains(k)) (names[k] is String ? names[k] as String : 'A place'),
    ];
  }

  // ---------------------------------------------------------------- keys

  /// The key [name] is ticked for [peer]. Every key starts off.
  bool keyOn(String peer, String name) => _keysFor[peer]?.contains(name) ?? false;

  /// The keys saved here that are ticked for [peer].
  int keysOn(String peer) => keys().where((k) => keyOn(peer, k.name)).length;

  Future<void> setKeyOn(String peer, String name, bool on) async {
    final set = _keysFor.putIfAbsent(peer, () => <String>{});
    on ? set.add(name) : set.remove(name);
    if (set.isEmpty) _keysFor.remove(peer);
    await _saveState();
    await pushKeys();
    notifyListeners();
  }

  /// Gives the sync engine, for each linked device, the keys ticked for it while this device's settings go there; none to the
  /// others.
  Future<void> pushKeys() async {
    if (!sharing.running) return;
    final saved = keys();
    for (final p in sharing.peers) {
      final id = p['id'];
      if (id is! String) continue;
      final out = <String, String>{};
      if (_sendsTo(id)) {
        for (final k in saved) {
          if (!keyOn(id, k.name)) continue;
          try {
            final v = await k.read();
            if (v != null && v.isNotEmpty) out[k.name] = v;
          } catch (_) {}
        }
      }
      final before = _pushed[id];
      if (before != null && mapEquals(before, out)) continue;
      try {
        await sharing.setSecrets(id, out);
        _pushed[id] = out;
      } catch (e) {
        logError('Settings sync: could not give the keys for a device', error: e);
      }
    }
  }

  /// Keeps the keys linked devices sent, from the devices whose settings this one takes.
  Future<void> takeKeys() async {
    Map<String, Map<String, String>> got;
    try {
      got = await sharing.takeSecrets();
    } catch (_) {
      return;
    }
    var any = false;
    for (final e in got.entries) {
      if (!_takesFrom(e.key)) continue;
      for (final k in e.value.entries) {
        try {
          if (await storeKey(k.key, k.value)) any = true;
        } catch (err) {
          logError('Settings sync: could not keep a key', error: err);
        }
      }
    }
    if (any) notifyListeners();
  }

  // ---------------------------------------------------------------- kept on this device

  Future<void> _readState() async {
    await _folder();
    final f = _stateFile();
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      for (final e in ((j['localAt'] as Map?) ?? const {}).entries) {
        if (e.value is int) _localAt['${e.key}'] = e.value as int;
      }
      for (final e in ((j['last'] as Map?) ?? const {}).entries) {
        if (e.value is String) _last['${e.key}'] = e.value as String;
      }
      for (final e in ((j['seen'] as Map?) ?? const {}).entries) {
        if (e.value is Map) _seen['${e.key}'] = {for (final x in (e.value as Map).entries) if (x.value is int) '${x.key}': x.value as int};
      }
      for (final e in ((j['keys'] as Map?) ?? const {}).entries) {
        if (e.value is List) _keysFor['${e.key}'] = {for (final x in e.value as List) '$x'};
      }
      for (final e in ((j['notes'] as Map?) ?? const {}).entries) {
        _notes['${e.key}'] = e.value;
      }
      for (final e in ((j['waiting'] as Map?) ?? const {}).entries) {
        final ev = e.value is String ? SettingsEvent.fromLine(e.value as String) : null;
        if (ev != null) _waiting['${e.key}'] = ev;
      }
    } catch (_) {
      // A damaged file: start again (each device's log is read again from its start, which applies nothing twice).
    }
  }

  /// The key names only: a key itself is never written here.
  Future<void> _saveState() async {
    final f = _stateFile();
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await writeStringAtomic(
        f,
        jsonEncode({
          'localAt': _localAt,
          'last': _last,
          'seen': _seen,
          'keys': {for (final e in _keysFor.entries) e.key: e.value.toList()..sort()},
          'notes': _notes,
          'waiting': {for (final e in _waiting.entries) e.key: e.value.toLine()},
        }),
      );
    } catch (e) {
      logError('Settings sync: could not keep its state', error: e);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final u in _unlisten) {
      u();
    }
    super.dispose();
  }
}
