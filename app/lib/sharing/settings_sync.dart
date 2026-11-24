import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../chat/ask_focus.dart';
import '../platform/app_log.dart';
import 'settings_log.dart';
import 'sharing_state.dart';

export 'settings_log.dart' show SettingsEvent, SettingsLink, canonical, applies;
export 'share_rules.dart' show kSettingsShareId, kSettingsShareDir, kBookshelvesShareId, kBookshelvesDir, kSettingsShareModes, kBookshelvesShareModes;

/// The chosen Ask model's setting: a model not on this device waits, with Download.
const String kModelSettingKey = 'ask.model';

/// The saved places weather watches. A watched place whose saved place is not on this device stays in the setting but is not listed
/// or fetched until that place arrives.
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
  weather('Weather and alerts', 'Sources on, what weather watches'),
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

/// The web search key's name and label, as the phone keeps and shows it.
const String kKagiKeyName = 'search.kagi.key';
const String kKagiKeyLabel = 'Kagi (web search)';

/// One key kept in secure storage that can be sent to one linked device: [name] is where it is kept, [read] gives it.
class SyncedKey {
  const SyncedKey({required this.name, required this.label, required this.read});

  final String name;
  final String label;
  final Future<String?> Function() read;
}

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
    required List<SyncedKey> Function() keys,
    required this.storeKey,
    required this.dir,
    this.downloadModel,
    this.placesHere,
    this.onServerKeysChanged,
    DateTime Function()? now,
    this.every = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now,
       _appKeys = keys {
    _byKey = {for (final s in settings) s.key: s};
  }

  final SharingState sharing;

  /// Every setting that can go between devices. A setting not here never goes, and is never taken from another device's log.
  final List<SyncedSetting> settings;

  /// The keys saved on this device (what this app works out: their names and labels).
  final List<SyncedKey> Function() _appKeys;

  /// The keys that can be ticked for a linked device. On a phone, the keys saved here ([_appKeys]). In a browser the server is the
  /// device: the keys its keystore holds that can sync, as the server last said ([watchServerKeys]), named as the phone names
  /// them where this app can work that out. Never a key's value.
  List<SyncedKey> keys() {
    if (!sharing.onServer) return _appKeys();
    final known = {for (final k in _appKeys()) k.name: k.label};
    return [for (final n in _serverNames) SyncedKey(name: n, label: known[n] ?? _plainLabel(n), read: () async => null)];
  }

  /// A key this tab cannot name from its own sources: the web search key's own name, or a source's alias, as a phone says it.
  static String _plainLabel(String name) {
    if (name == kKagiKeyName) return kKagiKeyLabel;
    const prefix = 'live.key.';
    return name.startsWith(prefix) && name.length > prefix.length ? name.substring(prefix.length) : name;
  }

  /// Keeps a key a linked device sent; false when [name] is not a key this app keeps.
  final Future<bool> Function(String name, String value) storeKey;

  /// The settings share's folder.
  final Future<Directory?> Function() dir;
  final DateTime Function() _now;
  final Duration every;

  /// Starts the download of a model a linked device uses ([waitingModelDownload]); only when the person taps Download.
  final Future<void> Function(Map<String, Object?> download)? downloadModel;

  /// In a browser: told when the keys the server holds change (one saved in another tab, or sent by a linked device), so the tab reads
  /// its own key list again (the Settings row "API keys").
  final void Function()? onServerKeysChanged;

  /// The saved places on this device, by key.
  final Future<Set<String>> Function()? placesHere;

  late final Map<String, SyncedSetting> _byKey;

  /// What this device keeps of the settings sync, in [_log] once the folder is known (see [SettingsLogState]).
  final SettingsLogState _kept = SettingsLogState();
  Map<String, int> get _localAt => _kept.localAt;
  Map<String, String> get _last => _kept.last;
  Map<String, Set<String>> get _keysFor => _kept.keysFor;
  Map<String, Set<String>> get _keysAll => _kept.keysAll;
  Map<String, Set<String>> get _keysHeld => _kept.keysHeld;
  Map<String, SettingsEvent> get _waiting => _kept.waiting;
  Map<String, Object?> get _notes => _kept.notes;

  /// The keys last given to the sync engine for each device (in memory only).
  final Map<String, Map<String, String>> _pushed = {};

  final Set<String> _applying = {};
  final List<VoidCallback> _unlisten = [];
  Timer? _timer;
  Directory? _dir;
  SettingsLog? _log;
  bool _started = false;
  bool _wasRunning = false;
  bool _disposed = false;
  String _links = '';

  bool get started => _started;

  Future<Directory?> _folder() async {
    final d = _dir ??= await dir();
    return d;
  }

  /// The log in the settings folder [d], as this device (the state is kept before the device has an id; nothing is appended then).
  SettingsLog? _logFor(Directory? d) {
    if (d == null) return null;
    final me = sharing.myId ?? '';
    final l = _log;
    if (l != null && l.dir == d.path && l.device == me) return l;
    return _log = SettingsLog(dir: d.path, device: me, state: _kept);
  }

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

  /// How settings go between this device and [peer]. A link with nothing chosen yet is Match when it was made before this
  /// version asked ([SharingState.linkedSinceAsking]), and Off when it is new: nothing goes until the person answers.
  SettingsLink linkWith(String peer) {
    return linkOfRecord(sharing.linkOf(peer), peer: peer, myId: sharing.myId, linkedSinceAsking: sharing.linkedSinceAsking(peer));
  }

  /// A new link whose question ("Sync Cache settings with Desk?") neither device has answered yet: Off meanwhile.
  bool unanswered(String peer) {
    final l = sharing.linkOf(peer);
    return l?['ask'] == true || (l?['mode'] == null && sharing.linkedSinceAsking(peer));
  }

  final Set<String> _marking = {};

  /// Sets a new link with nothing chosen to Off, waiting for the answer (`ask`). The engine already makes every new link so;
  /// this covers a link that reaches the app without a kind. A link made before this version is left as it is (Match).
  Future<void> markNew(String peer) async {
    final l = sharing.linkOf(peer);
    if (l?['mode'] != null || !sharing.linkedSinceAsking(peer) || !_marking.add(peer)) return;
    try {
      await sharing.setLink(peer, {...?l, 'mode': 'off', 'from': sharing.myId, 'ask': true});
    } catch (e) {
      logError('Settings sync: could not set a new link to Off', error: e);
    } finally {
      _marking.remove(peer);
    }
  }

  /// The answer to the question asked right after linking: Match, Send mine or Off, chosen here as on the device's page; null
  /// when it was closed, which is Off while neither device has answered and keeps what the other device answered meanwhile.
  Future<void> answer(String peer, SettingsLink? to) async {
    // The first answer is the pair's: once either device has answered, a later one is only read (a notice), never applied.
    if (!unanswered(peer)) return;
    await setLink(peer, to ?? SettingsLink.off);
  }

  /// The device that answered the question for the pair ([Link] `by`), null while it is open.
  String? decidedBy(String peer) => sharing.linkOf(peer)?['by'] as String?;

  /// The other device answered first: this one's question is only a notice of what it chose.
  bool decidedByOther(String peer) {
    final by = decidedBy(peer);
    return by != null && by != sharing.myId;
  }

  bool _sendsTo(String peer) => linkSends(linkWith(peer));
  bool _takesFrom(String peer) => linkTakes(linkWith(peer));

  Map<String, Object?> _linkValue(String peer) => {...?sharing.linkOf(peer)};

  Set<String> _list(Map<String, Object?> l, String k) => {for (final x in (l[k] as List? ?? const [])) '$x'};

  /// Chooses how settings go with [peer] for both devices in one step (Match, Send mine, Take theirs or Off); the other device
  /// takes the same record with the next sync. The record says which way (`from`) relative to the two ids. Switching Match or
  /// Send mine on makes this device where they come from: its included settings go as they are.
  Future<void> setLink(String peer, SettingsLink to) async {
    final was = linkWith(peer);
    if (was == to && !unanswered(peer)) return;
    final first = unanswered(peer);
    final l = _linkValue(peer)
      ..remove('ask')
      ..['mode'] = switch (to) {
        SettingsLink.match => 'match',
        SettingsLink.sending || SettingsLink.receiving => 'send',
        _ => 'off',
      }
      ..['from'] = to == SettingsLink.receiving ? peer : sharing.myId;
    // Who answered the question, and when: the first answer is kept (the engine's merge compares `at`, then the lower id).
    if (first) {
      l['by'] = sharing.myId;
      l['at'] = _now().millisecondsSinceEpoch;
    }
    await sharing.setLink(peer, l);
    if (to != SettingsLink.off && to != SettingsLink.receiving) await _seed([for (final s in settings) if (settingOn(peer, s.key)) s.key]);
    _links = _linkSignature();
    await pushKeys();
    _tell();
  }

  /// [g] is included with [peer].
  bool groupOn(String peer, SettingsGroupId g) => !_list(_linkValue(peer), 'off_groups').contains(g.name);

  /// The setting [key] is included with [peer]: its group is, and it is not unticked.
  bool settingOn(String peer, String key) {
    final s = _byKey[key];
    if (s == null) return false;
    return linkIncludes(_linkValue(peer), group: s.group.name, key: key);
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
    l['mode'] ??= sharing.linkedSinceAsking(peer) ? 'off' : 'match';
    await sharing.setLink(peer, l);
    _tell();
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
      final stamps = _stampsOf(s.key, jsonDecode(v), before: before == null ? null : jsonDecode(before), at: at);
      if (!_sendsAny(s.key)) continue;
      _write(SettingsEvent(
        at: at,
        dev: sharing.myId ?? '',
        key: s.key,
        value: jsonDecode(v),
        hasPrev: before != null,
        prev: before == null ? null : jsonDecode(before),
        note: _noteOf(s),
        removed: stamps?.removed,
        added: stamps?.added,
      ));
    }
    if (any) unawaited(_saveState());
  }

  static List<String> _ids(Object? v) => [for (final x in (v is List ? v : const [])) if (x is String) x];

  /// For a list-of-ids setting ([kIdListSettings]): notes a change made here ([before] to [value] at [at], when given) and gives what
  /// goes with the change: the removals and the adds. Null for any other setting.
  ({Map<String, int>? removed, Map<String, int>? added})? _stampsOf(String key, Object? value, {Object? before, int? at}) {
    if (!kIdListSettings.contains(key)) return null;
    if (at != null) trackIdChange(_kept, key, _ids(before), _ids(value), at);
    return idStamps(_kept, key, _ids(value));
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
      final stamps = _stampsOf(k, jsonDecode(v));
      _write(SettingsEvent(at: at, dev: sharing.myId ?? '', key: k, value: jsonDecode(v), note: _noteOf(s), removed: stamps?.removed, added: stamps?.added));
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
    final log = _logFor(await _folder());
    if (me == null || log == null || ev.dev != me) return;
    try {
      await log.append(ev);
    } catch (e) {
      logError('Settings sync: could not write a change', error: e, detail: ev.key);
    }
  }

  // ---------------------------------------------------------------- changes from linked devices

  /// One look: when sharing has just started, the keys are given to the engine; then the keys that came are kept and the logs
  /// of the devices whose settings this one takes are read.
  bool _waitingForAsk = false;

  Future<void> tick() async {
    // While Ask answers, no new round starts (one waits, the timer's other ticks do not pile up behind it); it goes on after.
    if (_waitingForAsk) return;
    if (askFocusShared?.focused ?? false) {
      _waitingForAsk = true;
      try {
        await askIdle(worker: 'Settings sync');
      } finally {
        _waitingForAsk = false;
      }
    }
    if (!sharing.running || sharing.myId == null) {
      _wasRunning = false;
      return;
    }
    if (!_wasRunning) {
      _wasRunning = true;
      _pushed.clear();
      _links = _linkSignature();
      // choices kept for a device that is no longer linked (an unlink while this was not watching) go before the keys are given
      await _forgetUnlinked();
      await pushKeys();
    }
    await takeKeys();
    await pull();
  }

  String _linkSignature() => [for (final p in sharing.peers) '${p['id']}=${canonical(p['link'])}'].join(';');

  /// A link changed (here, or the other device's choice arrived): keys and settings follow it.
  void _onSharing() {
    if (!sharing.running) return;
    for (final p in sharing.peers) {
      final id = p['id'];
      if (id is String && (p['link'] as Map?)?['mode'] == null && sharing.linkedSinceAsking(id)) unawaited(markNew(id));
    }
    unawaited(_forgetUnlinked());
    final sig = _linkSignature();
    if (sig == _links) return;
    _links = sig;
    unawaited(() async {
      await pushKeys();
      await pull();
      _tell();
    }());
  }

  /// A device that is no longer linked takes its key choices with it ("Include API keys" and the keys left out), so a device that
  /// links again starts with the switch off. Not in a browser: the server forgets them when the device is unlinked.
  Future<void> _forgetUnlinked() async {
    if (sharing.onServer || !sharing.running) return;
    final linked = {for (final p in sharing.peers) if (p['id'] is String) p['id'] as String};
    final gone = {..._keysAll.keys, ..._keysFor.keys, ..._keysHeld.keys}.where((id) => !linked.contains(id)).toList();
    if (gone.isEmpty) return;
    for (final id in gone) {
      _keysAll.remove(id);
      _keysFor.remove(id);
      _keysHeld.remove(id);
      _pushed.remove(id);
    }
    await _saveState();
    _tell();
  }

  /// Applies what the devices whose settings this one takes changed since the last look.
  Future<void> pull() async {
    final me = sharing.myId;
    final log = _logFor(await _folder());
    if (me == null || log == null) return;
    var changed = false;
    for (final p in sharing.peers) {
      final id = p['id'];
      if (id is! String || id == me || !_takesFrom(id)) continue;
      final read = await log.readPeer(id);
      if (read == null) continue;
      final latest = read.latest;
      final link = linkWith(id);
      for (final e in latest.entries) {
        final s = _byKey[e.key];
        if (s == null || !settingOn(id, e.key)) continue;
        final (line, ev) = e.value;
        if (!log.state.isUnseen(id, e.key, line)) continue;
        log.state.markSeen(id, e.key, line);
        changed = true;
        final current = _read(s);
        if (current == null) continue;
        var evNow = ev;
        if (kIdListSettings.contains(e.key)) {
          // merged per id: the value to write is the sender's list less what was removed here later, and what it removed goes
          if (current == canonical(ev.value)) {
            _waiting.remove(e.key);
            continue;
          }
          final takes = applies(link, ev, current: current, localAt: _localAt[e.key] ?? 0);
          final next = mergeIdList(_kept, e.key, ev, _ids(jsonDecode(current)), takes: takes);
          if (next == null) {
            _waiting.remove(e.key);
            continue;
          }
          evNow = SettingsEvent(at: takes ? ev.at : (_localAt[e.key] ?? ev.at), dev: ev.dev, key: ev.key, value: next, note: ev.note);
        } else {
          if (current == canonical(ev.value)) {
            _waiting.remove(e.key);
            continue;
          }
          if (!applies(link, ev, current: current, localAt: _localAt[e.key] ?? 0)) continue;
        }
        // which setting a linked device changed here, and which device (its id's start; never the value: some hold place names)
        logInfo('Settings sync: applying ${e.key} from device ${id.length > 8 ? id.substring(0, 8) : id}');
        await _apply(s, evNow);
      }
    }
    if (changed) {
      await _saveState();
      _tell();
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
      _tell();
    }
  }

  /// A change taken that cannot be used here yet, by setting key (the model a linked device uses, not downloaded here).
  SettingsEvent? waiting(String key) => _waiting[key];

  /// What came with the change [key] last took from a linked device (see [SyncedSetting.note]).
  Object? noteOf(String key) => _notes[key];

  /// How many of the watched saved places are on this device ([here]: the saved places here, by key); null until that is known.
  /// The ones that are not here stay in the setting and are not counted or shown.
  int? watchedPlacesHere(Set<String>? here) {
    final s = _byKey[kWatchPlacesKey];
    if (s == null || here == null) return null;
    final watched = s.read();
    return [for (final k in (watched is List ? watched : const [])) if (k is String && here.contains(k)) k].length;
  }

  // ---------------------------------------------------------------- keys

  /// "Include API keys" is on for [peer]. Off for a newly linked device. The switch is its own choice, as on a phone: it stays on while a
  /// key is left out, and on with no key saved. In a browser the server holds it.
  bool includeKeys(String peer) => sharing.onServer ? _serverInclude.contains(peer) : _keysAll.containsKey(peer);

  /// The key [name] goes to [peer]: the switch is on and the key is not left out. A key saved later follows the switch.
  bool keyOn(String peer, String name) {
    if (sharing.onServer) return _serverOn[name]?.contains(peer) ?? false;
    final all = _keysAll[peer];
    if (all != null) return !all.contains(name);
    return _keysFor[peer]?.contains(name) ?? false;
  }

  /// The keys saved here that go to [peer].
  int keysOn(String peer) => keys().where((k) => keyOn(peer, k.name)).length;

  /// The "Include API keys" switch for [peer]: on sends every key (each can be left out below it, and keys saved later go too); off
  /// sends none.
  Future<void> setIncludeKeys(String peer, bool on) async {
    if (sharing.onServer) {
      try {
        _takeServerKeys(await sharing.setServerIncludeKeys(peer, on));
      } catch (e) {
        logError('Settings sync: the server did not take the Include API keys switch', error: e);
        await refreshServerKeys();
      }
      _tell();
      return;
    }
    if (on) {
      // the keys left out before the switch went off stay left out
      _keysAll[peer] = _keysHeld.remove(peer) ?? <String>{};
    } else {
      final out = _keysAll.remove(peer);
      if (out != null && out.isNotEmpty) _keysHeld[peer] = out;
    }
    _keysFor.remove(peer);
    await _saveState();
    await pushKeys();
    _tell();
  }

  /// Test only: the single ticks an earlier version kept for [peer].
  @visibleForTesting
  void seedLegacyTicks(String peer, Set<String> names) => _keysFor[peer] = {...names};

  /// Turns the single ticks of before "Include API keys" into the switch: a device with any key ticked gets the switch on with every
  /// other saved key left out, so exactly the same keys go; a device with none stays off. Nothing is asked again. Safe to run twice.
  Future<void> migrateKeys() async {
    if (sharing.onServer || _keysFor.isEmpty) return;
    final saved = [for (final k in _appKeys()) k.name];
    // The keys are not read yet (the weather part starts after this): try again at the next push, never guess an empty list.
    if (saved.isEmpty) return;
    for (final peer in _keysFor.keys.toList()) {
      final ticked = _keysFor[peer] ?? const <String>{};
      if (ticked.isNotEmpty && !_keysAll.containsKey(peer)) _keysAll[peer] = {for (final n in saved) if (!ticked.contains(n)) n};
      _keysFor.remove(peer);
    }
    await _saveState();
  }

  Future<void> setKeyOn(String peer, String name, bool on) async {
    if (sharing.onServer) return _setServerKeyOn(peer, name, on);
    final all = _keysAll[peer];
    if (all == null) {
      // The switch is off: a single key can only be left out of an included set.
      if (!on) return;
      _keysAll[peer] = {for (final k in keys()) if (k.name != name) k.name};
      _keysHeld.remove(peer);
    } else {
      on ? all.remove(name) : all.add(name);
    }
    await _saveState();
    await pushKeys();
    _tell();
  }

  // The server's keys, in a browser (the server is the device: it keeps the keys and the ticks, and sends them itself).
  List<String> _serverNames = const [];
  Map<String, Set<String>> _serverOn = const {};
  Set<String> _serverInclude = const {};
  Timer? _serverTimer;
  bool _serverKeysBusy = false;
  bool _serverKeysRead = false;

  /// In a browser: reads the server's key names and ticks now and every 10 s, and again when sharing starts. Names and ticks only.
  void watchServerKeys() {
    if (_serverTimer != null) return;
    sharing.addListener(_onServerSharing);
    _serverTimer = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(refreshServerKeys()));
    _onServerSharing();
  }

  void _onServerSharing() {
    if (sharing.onServer && sharing.running && !_serverKeysRead) unawaited(refreshServerKeys());
  }

  /// Reads the server's key names and ticks again.
  Future<void> refreshServerKeys() async {
    if (_disposed || _serverKeysBusy || !sharing.onServer || !sharing.running) return;
    _serverKeysBusy = true;
    try {
      _takeServerKeys(await sharing.serverKeys());
    } catch (e) {
      // Tried again by the timer, not at every state read.
      _serverKeysRead = true;
      logError('Settings sync: could not read the server\'s keys', error: e);
    } finally {
      _serverKeysBusy = false;
    }
  }

  void _takeServerKeys(ServerKeys got) {
    _serverKeysRead = true;
    final names = [for (final k in got.keys) k.name];
    final on = {for (final k in got.keys) k.name: k.on};
    final namesSame = listEquals(names, _serverNames);
    final same = namesSame && names.every((n) => setEquals(on[n], _serverOn[n])) && setEquals(got.include, _serverInclude);
    _serverNames = names;
    _serverOn = on;
    _serverInclude = got.include;
    if (!namesSame) onServerKeysChanged?.call();
    if (!same) _tell();
  }

  Future<void> _setServerKeyOn(String peer, String name, bool on) async {
    try {
      _takeServerKeys(await sharing.setServerKeyOn(peer, name, on));
    } catch (e) {
      logError('Settings sync: the server did not take a key tick', error: e);
      await refreshServerKeys();
    }
    _tell();
  }

  /// Gives the sync engine, for each linked device, the keys ticked for it while this device's settings go there; none to the
  /// others.
  Future<void> pushKeys() async {
    // In a browser the server gives its own keys to the engine; a tab never holds one.
    if (sharing.onServer || !sharing.running) return;
    await migrateKeys();
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
    if (sharing.onServer) return;
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
    if (any) _tell();
  }

  // ---------------------------------------------------------------- kept on this device

  Future<void> _readState() async {
    final log = _logFor(await _folder());
    if (log == null) return;
    await log.loadState();
  }

  /// The key names only: a key itself is never written here.
  Future<void> _saveState() async {
    final log = _logFor(_dir);
    if (log == null) return;
    try {
      await log.saveState();
    } catch (e) {
      logError('Settings sync: could not keep its state', error: e);
    }
  }

  /// Tells the pages, unless this is gone (a look that was running when it went).
  void _tell() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_serverTimer != null) {
      _serverTimer!.cancel();
      sharing.removeListener(_onServerSharing);
    }
    for (final u in _unlisten) {
      u();
    }
    super.dispose();
  }
}
