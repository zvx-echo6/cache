// The settings log's own logic, with no Flutter: the event and its line, appending to this device's log, reading a peer's log
// from what was seen, `.local/state.json`, the newest-wins rule, and which way a link goes and what it includes. The phone's
// SettingsSync (settings_sync.dart) uses it, and so can plain Dart (the Cache Server helper, tests), because every file access
// goes through [SettingsLogFiles]. This file imports nothing of Flutter, and nothing that does (not sharing_state.dart).
import 'dart:convert';
import 'dart:io';

import '../files.dart';

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

/// One change to one setting, as a line of a device's settings log.
class SettingsEvent {
  const SettingsEvent({required this.at, required this.dev, required this.key, required this.value, this.hasPrev = false, this.prev, this.note, this.removed, this.added});

  final int at;
  final String dev;
  final String key;
  final Object? value;

  /// The value before the change, when known (a change made here); a device's settings sent as they are when the link is
  /// switched on have none.
  final bool hasPrev;
  final Object? prev;
  final Object? note;

  /// For a setting that is a list of ids (see [kIdListSettings]): the ids the sender removed and when (`rm`), and the ids it added
  /// itself and when (`ad`). Builds from before this ignore both and read the value alone, so they stay as they were.
  final Map<String, int>? removed;
  final Map<String, int>? added;

  static Map<String, int>? _stamps(Object? v) {
    if (v is! Map) return null;
    final out = {for (final e in v.entries) if (e.value is int) '${e.key}': e.value as int};
    return out.isEmpty ? null : out;
  }

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
    return SettingsEvent(at: at, dev: dev, key: key, value: j['val'], hasPrev: j.containsKey('prev'), prev: j['prev'], note: j['note'], removed: _stamps(j['rm']), added: _stamps(j['ad']));
  }

  String toLine() => jsonEncode({'v': 1, 'at': at, 'dev': dev, 'k': key, 'val': value, if (hasPrev) 'prev': prev, if (note != null) 'note': note, if (removed != null && removed!.isNotEmpty) 'rm': removed, if (added != null && added!.isNotEmpty) 'ad': added});
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

// ------------------------------------------------------------------ lists of ids

/// The settings that are a list of ids, merged per id and not as one whole list: a removal is remembered, so a list from a device
/// that had not heard of it yet does not put the id back (a saved place deleted here came back as a nameless row).
const Set<String> kIdListSettings = {'weather.watch_places'};

/// How long a removal is remembered, and how many are.
const int _removalKeepMs = 60 * 24 * 3600 * 1000;
const int _removalKeepMax = 500;

/// A change made here to the list of ids [key], from [before] to [after] at [at]: ids that left are removed at [at]; ids that came
/// are added at [at] (and no longer removed).
void trackIdChange(SettingsLogState st, String key, Iterable<String> before, Iterable<String> after, int at) {
  final b = before.toSet(), a = after.toSet();
  final rem = st.removed.putIfAbsent(key, () => {}), add = st.added.putIfAbsent(key, () => {});
  for (final id in b.difference(a)) {
    rem[id] = at;
    add.remove(id);
  }
  for (final id in a.difference(b)) {
    add[id] = at;
    rem.remove(id);
  }
  add.removeWhere((id, _) => !a.contains(id));
  _prune(rem, at);
}

void _prune(Map<String, int> rem, int now) {
  rem.removeWhere((_, t) => t < now - _removalKeepMs);
  if (rem.length <= _removalKeepMax) return;
  final keep = (rem.entries.toList()..sort((x, y) => y.value.compareTo(x.value))).take(_removalKeepMax);
  final m = {for (final e in keep) e.key: e.value};
  rem
    ..clear()
    ..addAll(m);
}

/// What goes with a change of the list [key]: the removals remembered, and the adds made here of ids still in [now].
({Map<String, int>? removed, Map<String, int>? added}) idStamps(SettingsLogState st, String key, Iterable<String> now) {
  final rem = st.removed[key], add = st.added[key];
  final ids = now.toSet();
  final a = add == null ? null : {for (final e in add.entries) if (ids.contains(e.key)) e.key: e.value};
  return (removed: rem == null || rem.isEmpty ? null : {...rem}, added: a == null || a.isEmpty ? null : a);
}

/// A change [ev] to the list of ids [key] from another device, the list here being [current]: the list to write, or null when it
/// is as it is. [takes] is whether the change applies as a whole ([applies]: the latest change wins); the removals in it count
/// either way.
///  - An id the sender removed (`rm`) that is here and was not added here since (an id taken from a device has no time of its own)
///    goes.
///  - An id in the sender's list that was removed here later than the sender's own add of it (its list's time when the sender did
///    not say, as a build from before this does not) stays out; an add after the removal puts it back.
List<String>? mergeIdList(SettingsLogState st, String key, SettingsEvent ev, List<String> current, {required bool takes}) {
  final rem = st.removed.putIfAbsent(key, () => {}), add = st.added.putIfAbsent(key, () => {});
  for (final e in (ev.removed ?? const <String, int>{}).entries) {
    if ((rem[e.key] ?? -1) < e.value) rem[e.key] = e.value;
  }
  final now = current.toSet();
  var next = {for (final id in now) if (!((rem[id] ?? -1) > (add[id] ?? 0) && (ev.removed?.containsKey(id) ?? false))) id};
  if (takes && ev.value is List) {
    final incoming = {for (final x in ev.value as List) if (x is String) x};
    for (final id in now.difference(incoming)) {
      rem[id] = ev.at;
      add.remove(id);
    }
    next = {
      for (final id in incoming)
        if ((rem[id] ?? -1) < 0 || (ev.added?[id] ?? -1) > rem[id]!) id,
    };
    for (final id in next.intersection(incoming)) {
      if ((rem[id] ?? -1) >= 0 && (ev.added?[id] ?? -1) > rem[id]!) rem.remove(id);
    }
  }
  _prune(rem, ev.at);
  if (next.length == now.length && next.containsAll(now)) return null;
  return next.toList()..sort();
}

// ------------------------------------------------------------------ links

/// How settings go between this device ([myId]) and [peer], from the link's record (`{mode, from, off_groups, off_keys, ...}`;
/// null when there is none). A link with nothing chosen yet is Match when it was made before this version asked
/// ([linkedSinceAsking] false), and Off when it is new: nothing goes until the person answers.
SettingsLink linkOfRecord(Map<String, Object?>? link, {required String peer, required String? myId, required bool linkedSinceAsking}) {
  switch (link?['mode']) {
    case 'off':
      return SettingsLink.off;
    case 'send':
      final from = link?['from'];
      if (from == peer) return SettingsLink.receiving;
      if (from == myId) return SettingsLink.sending;
      return SettingsLink.off;
    case 'match':
      return SettingsLink.match;
    default:
      return linkedSinceAsking ? SettingsLink.off : SettingsLink.match;
  }
}

/// This device's changes go to the linked device.
bool linkSends(SettingsLink l) => l == SettingsLink.match || l == SettingsLink.sending;

/// The linked device's changes come here.
bool linkTakes(SettingsLink l) => l == SettingsLink.match || l == SettingsLink.receiving;

/// Whether a setting is included with a link: its group ([group], the group's name) is not left out and it is not unticked.
bool linkIncludes(Map<String, Object?> link, {required String group, required String key}) {
  Set<String> list(String k) => {for (final x in (link[k] as List? ?? const [])) '$x'};
  return !list('off_groups').contains(group) && !list('off_keys').contains(key);
}

// ------------------------------------------------------------------ file access

/// The file access the log needs, so plain Dart and tests can use it as the phone does.
abstract interface class SettingsLogFiles {
  /// Adds [line] (it carries its own end of line) to the end of the file at [path], making the folders on the way, flushed.
  Future<void> append(String path, String line);

  /// The file's text, or null when it is not there.
  Future<String?> read(String path);

  /// Writes [text] to the file at [path] whole (a temp file next to it, then a rename), making the folders on the way.
  Future<void> writeAtomic(String path, String text);

  Future<bool> exists(String path);
}

/// [SettingsLogFiles] on dart:io.
class IoSettingsLogFiles implements SettingsLogFiles {
  const IoSettingsLogFiles();

  @override
  Future<void> append(String path, String line) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(line, mode: FileMode.append, flush: true);
  }

  @override
  Future<String?> read(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  @override
  Future<void> writeAtomic(String path, String text) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await writeStringAtomic(f, text);
  }

  @override
  Future<bool> exists(String path) => File(path).exists();
}

// ------------------------------------------------------------------ what is kept on this device

/// What a device keeps about its settings sync, in `.local/state.json` (a hidden folder, which never syncs).
class SettingsLogState {
  /// When each setting last changed here (made here, or taken from another device: that change's time), by key.
  final Map<String, int> localAt = {};

  /// Each setting's value as last seen, by key ([canonical]).
  final Map<String, String> last = {};

  /// What was read of each device's log: by device, by setting, the line of the latest change taken.
  final Map<String, Map<String, int>> seen = {};

  /// The keys ticked for each device, by device (their secure-storage names).
  final Map<String, Set<String>> keysFor = {};

  /// "Include API keys" is on for a device (present here), and the keys left out of it, by device. A key saved later is not in the
  /// set, so it follows the switch. [keysFor] holds the single ticks of before this switch existed until [SettingsSync.migrateKeys]
  /// has turned them into this.
  final Map<String, Set<String>> keysAll = {};

  /// The note of the change each setting last took from another device, by key.
  final Map<String, Object?> notes = {};

  /// Changes taken that cannot be used here yet (a model not on this device), by key.
  final Map<String, SettingsEvent> waiting = {};

  /// For a list-of-ids setting ([kIdListSettings]), by key: when each id was last removed (here, or by a device whose change was
  /// taken), and when each id was added here. [mergeIdList] reads them.
  final Map<String, Map<String, int>> removed = {};
  final Map<String, Map<String, int>> added = {};

  /// What was seen of [peer]'s log, by setting (made if there is none yet).
  Map<String, int> seenOf(String peer) => seen.putIfAbsent(peer, () => {});

  /// The line [line] of [peer]'s log, the latest change of [key], has not been taken yet.
  bool isUnseen(String peer, String key, int line) => (seen[peer]?[key] ?? 0) < line;

  void markSeen(String peer, String key, int line) => seenOf(peer)[key] = line;

  /// The key names only: a key itself is never kept here.
  Map<String, Object?> toJson() => {
    'localAt': localAt,
    'last': last,
    'seen': seen,
    'keys': {for (final e in keysFor.entries) e.key: e.value.toList()..sort()},
    if (keysAll.isNotEmpty) 'keysAll': {for (final e in keysAll.entries) e.key: e.value.toList()..sort()},
    'notes': notes,
    'waiting': {for (final e in waiting.entries) e.key: e.value.toLine()},
    if (removed.isNotEmpty) 'removed': removed,
    if (added.isNotEmpty) 'added': added,
  };

  /// Takes what [j] (the decoded state file) holds; what is not in the expected form is left out.
  void load(Object? j) {
    if (j is! Map) return;
    for (final e in ((j['localAt'] as Map?) ?? const {}).entries) {
      if (e.value is int) localAt['${e.key}'] = e.value as int;
    }
    for (final e in ((j['last'] as Map?) ?? const {}).entries) {
      if (e.value is String) last['${e.key}'] = e.value as String;
    }
    for (final e in ((j['seen'] as Map?) ?? const {}).entries) {
      if (e.value is Map) seen['${e.key}'] = {for (final x in (e.value as Map).entries) if (x.value is int) '${x.key}': x.value as int};
    }
    for (final e in ((j['keys'] as Map?) ?? const {}).entries) {
      if (e.value is List) keysFor['${e.key}'] = {for (final x in e.value as List) '$x'};
    }
    for (final e in ((j['keysAll'] as Map?) ?? const {}).entries) {
      if (e.value is List) keysAll['${e.key}'] = {for (final x in e.value as List) '$x'};
    }
    for (final e in ((j['notes'] as Map?) ?? const {}).entries) {
      notes['${e.key}'] = e.value;
    }
    for (final k in const ['removed', 'added']) {
      final into = k == 'removed' ? removed : added;
      for (final e in ((j[k] as Map?) ?? const {}).entries) {
        final m = SettingsEvent._stamps(e.value);
        if (m != null) into['${e.key}'] = {...m};
      }
    }
    for (final e in ((j['waiting'] as Map?) ?? const {}).entries) {
      final ev = e.value is String ? SettingsEvent.fromLine(e.value as String) : null;
      if (ev != null) waiting['${e.key}'] = ev;
    }
  }
}

/// What was read of one device's log: its length in lines and the latest change of each setting, with the line it is on.
class PeerLog {
  PeerLog(this.lineCount, this.latest);

  final int lineCount;

  /// By setting key: (the line number, 1-based, the change).
  final Map<String, (int, SettingsEvent)> latest;

  /// The changes on a line after what [seen] (by setting) says was taken.
  Map<String, (int, SettingsEvent)> unseen(Map<String, int> seen) => {
    for (final e in latest.entries)
      if ((seen[e.key] ?? 0) < e.value.$1) e.key: e.value,
  };
}

/// A settings share's folder [dir] as one device ([device]) uses it: this device's own log `log/<device>.jsonl` (one writer per
/// file), the other devices' logs read from [state]'s `seen` onward, and `.local/state.json`.
class SettingsLog {
  SettingsLog({required this.dir, required this.device, SettingsLogFiles? files, SettingsLogState? state})
      : files = files ?? const IoSettingsLogFiles(),
        state = state ?? SettingsLogState();

  final String dir;

  /// This device's id: the name of the log it writes.
  final String device;
  final SettingsLogFiles files;
  final SettingsLogState state;

  String logPath(String dev) => '$dir/log/$dev.jsonl';
  String get statePath => '$dir/.local/state.json';

  /// Appends [ev] to this device's log, one line. Only this device's own changes go in it (`ev.dev` is this device); any other is
  /// left out. Throws when the line cannot be written.
  Future<void> append(SettingsEvent ev) async {
    if (ev.dev != device) return;
    await files.append(logPath(device), '${ev.toLine()}\n');
  }

  /// Reads [peer]'s log: the latest change of each setting and its line. Null when the log is not there or cannot be read. A log
  /// that got shorter than what was seen of it was started again, so what was seen of it is forgotten ([state]) and it is read
  /// whole. Taking a change is [SettingsLogState.markSeen], by the caller, once it has dealt with it.
  Future<PeerLog?> readPeer(String peer) async {
    List<String> lines;
    try {
      final text = await files.read(logPath(peer));
      if (text == null) return null;
      lines = text.split('\n');
    } catch (_) {
      return null;
    }
    final seen = state.seenOf(peer);
    if (seen.values.any((n) => n > lines.length)) seen.clear();
    final latest = <String, (int, SettingsEvent)>{};
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      final ev = SettingsEvent.fromLine(lines[i]);
      if (ev == null || ev.dev != peer) continue;
      latest[ev.key] = (i + 1, ev);
    }
    return PeerLog(lines.length, latest);
  }

  /// Reads `.local/state.json` into [state]. A missing or damaged file leaves it as it is (each device's log is then read again
  /// from its start, which applies nothing twice).
  Future<void> loadState() async {
    try {
      final text = await files.read(statePath);
      if (text == null) return;
      state.load(jsonDecode(text));
    } catch (_) {}
  }

  /// Writes [state] to `.local/state.json`. Throws when it cannot be written.
  Future<void> saveState() => files.writeAtomic(statePath, jsonEncode(state.toJson()));
}
