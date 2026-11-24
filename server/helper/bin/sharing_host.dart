import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../app/lib/sharing/share_rules.dart';
import '../../../app/lib/search/indexes_dir.dart' show kIndexesDirName;
import '../../../packages/cache_search/lib/src/errors.dart';
import '../../../packages/cache_search/lib/src/sync_core_io.dart';
import 'line_protocol.dart';

/// Cache for Linux's sharing host: the one owner of the sync engine on the server (the phone's `SharingState`, without Flutter).
///
/// A linked Linux machine is one more device like a phone: the engine (cache_sync, in libcache_search.so) is opened on `<data>/sync`
/// (the folder that holds the identity the Bookshelves log is named by), given the same config, shares, off lists and network
/// policy a phone gives it (app/lib/sharing/sharing_state.dart `_start`), and polled once every 2 s into a cached status that every
/// browser tab reads. Nothing in a browser drives the engine: a tab only asks the host (`sharing.*` ops, [SharingOps]).
///
/// What the host keeps, in `<data>/sharing.json` in the phone's format (`enabled`, `ask_since`, `off`): whether sharing is set up
/// and the items switched off. The shares themselves are the engine's own (`<data>/sync/sync.json`); the config that is not saved
/// (what never syncs, off lists, which links a share is kept with) is given again at every open. Sharing starts at helper start
/// when `sharing.json` says it is enabled, with no browser open, and not before it is set up.
///
/// Network: the engine's own defaults, as on a phone (n0's relays and lookup, the Mainline DHT, mDNS). [engineConfig] exists for
/// tests only (the loopback test turns all four off); the helper never passes one.
///
/// The host is the single owner of the engine, and its operations are plain methods ([invoke] is what the ops call), so later
/// work inside the host (settings sync, with its keys: [setSecrets] and [takeSecrets]) runs the same way a browser's request does,
/// except that a browser may not reach the keys.
class SharingHost {
  SharingHost({
    required this.dataDir,
    required this.supportDir,
    required this.docsDir,
    this.deviceName = 'Cache server',
    this.opener,
    this.libraryPath,
    this.engineConfig = const {},
    this.pollEvery = const Duration(seconds: 2),
    this.log,
  }) : table = ShareTable.forServer(dataDir: dataDir, supportDir: supportDir, docsDir: docsDir);

  final Directory dataDir;
  final Directory supportDir;
  final Directory docsDir;
  final String deviceName;

  /// Opens the engine; the real one when null (the core library at [libraryPath]).
  final SyncOpener? opener;
  final String? libraryPath;

  /// Added to the engine's config (tests only; see the class comment).
  final Map<String, Object?> engineConfig;
  final Duration pollEvery;
  final void Function(String message)? log;
  final ShareTable table;

  SyncCoreLike? _core;
  bool _enabled = false;
  bool _starting = false;
  bool _stopped = false;
  String? error;
  Map<String, dynamic> status = const {};
  Timer? _poll;
  bool _polling = false;
  int _ticks = 0;
  int? _askSince;
  final Map<String, Set<String>> _off = {};
  final Map<String, List<String>> _sentOff = {};
  final Map<String, List<String>> _only = {};
  final Map<String, List<String>> _neverFetch = {};
  Future<void> _chain = Future.value();

  /// `<data>/sharing.json` (the phone keeps it in its support folder; the server's is outside the folders a browser can write).
  File get flagFile => File('${dataDir.path}/sharing.json');
  Directory get syncDir => Directory('${dataDir.path}/sync');

  bool get enabled => _enabled;

  /// The engine's own device id (from its status); null before the engine runs.
  String? get myId => status['id'] is String && (status['id'] as String).isNotEmpty ? status['id'] as String : null;

  /// When links began to be asked about (`ask_since`).
  int? get askSince => _askSince;

  /// How many settings changes from linked devices the host applied (set by the helper; tabs read their files again when it moves).
  int Function()? settingsApplied;
  bool get running => _core != null;

  /// Called with the ids of the shared folders whose files a sync added, changed or removed, once the folder has nothing more to
  /// fetch (a library is never read half-way through): what the server reads again after a sync (library rescan, indexes).
  void Function(Set<String> shareIds)? onShareChanged;

  /// For each share id, how many times it has settled with other contents; a tab that sees the number move reads that folder again.
  final Map<String, int> _changed = {};

  // ---- one operation at a time

  /// Runs [f] after the operations before it; the engine's own calls are safe from several threads, but the host's lists and files
  /// are not.
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

  // ---- sharing.json

  /// Starts sharing if it was set up before (the phone's `init`).
  Future<void> init() => _locked(() async {
        try {
          final f = flagFile;
          if (!f.existsSync()) return;
          final j = jsonDecode(f.readAsStringSync());
          if (j is! Map) return;
          final off = j['off'];
          if (off is Map) {
            _off
              ..clear()
              ..addAll({for (final e in off.entries) if (e.value is List) '${e.key}': {for (final k in e.value as List) '$k'}});
          }
          final since = j['ask_since'];
          if (since is int) {
            _askSince = since;
          } else {
            // The first run of this version: every link there is now was made before it.
            _askSince = DateTime.now().millisecondsSinceEpoch;
            _save();
          }
          if (j['enabled'] == true) {
            _enabled = true;
            await _start();
          }
        } catch (e) {
          error = 'Sharing could not start: $e';
          log?.call(error!);
        }
      });

  void _save() {
    final f = flagFile;
    f.parent.createSync(recursive: true);
    final text = jsonEncode({
      'enabled': _enabled,
      'ask_since': ?_askSince,
      if (_off.values.any((v) => v.isNotEmpty)) 'off': {for (final e in _off.entries) if (e.value.isNotEmpty) e.key: [...e.value]..sort()},
    });
    // Written under a hidden name and renamed over the file, so nothing reads half of it.
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(f.path);
  }

  // ---- start and stop

  /// The first time: creates this device's identity and starts sharing.
  Future<void> setUp() => _locked(() async {
        _enabled = true;
        _askSince ??= DateTime.now().millisecondsSinceEpoch;
        _save();
        await _start();
      });

  Future<void> _start() async {
    if (_core != null || _starting || _stopped) return;
    _starting = true;
    error = null;
    try {
      syncDir.createSync(recursive: true);
      final open = opener ?? _openReal;
      // What each device builds for itself inside a shared folder never syncs (a library's search index).
      final core = await open({
        'dir': syncDir.path,
        'name': deviceName,
        'exclude': {for (final k in table.kinds) ...k.notShared, for (final a in table.always) a.id: a.exclude},
        'local_deletes': {for (final a in table.always) a.id: a.localDeletes},
        'last': {for (final a in table.always) a.id: a.last},
        'hidden': {for (final a in table.always) a.id: a.hidden},
        // An always-shared folder fetches nothing until the host says what it may fetch (setOnly).
        'only': {for (final a in table.always) a.id: _only[a.id] ?? const <String>[]},
        'never_fetch': {for (final e in _neverFetch.entries) e.key: e.value},
        // The items switched off, from the start, so the first round already leaves them out.
        'off': {for (final k in table.kinds) for (final id in k.shares.keys) id: _sentOff[id] = _offOf(k, id)},
        // What may be sent from a folder every item uses (the notebooks' photos): only what something shared refers to.
        'gate': await _gates(),
        // Folders kept only with some linked devices (the Bookshelves log with Match devices, the settings log with Match and Send mine).
        'with': {for (final l in table.links) l.id: l.modes},
        ...engineConfig,
      });
      _core = core;
      // The server is always online: sync uses the network (the phone's rule for Wi-Fi).
      await core.call('set_policy', {'network': true});
      await _refresh();
      await _keepOwnLog();
      await _retire();
      await _addFolders([...table.always.map((a) => (a.id, a.name, a.dir)), ...table.links.map((l) => (l.id, l.name, l.dir))]);
      _poll = Timer.periodic(pollEvery, (_) => _tick());
      await _refresh();
    } catch (e) {
      error = 'Sharing could not start: ${e is CacheSearchException ? e.message : e}';
      log?.call(error!);
      final c = _core;
      _core = null;
      _poll?.cancel();
      _poll = null;
      try {
        await c?.close();
      } catch (_) {}
    } finally {
      _starting = false;
    }
  }

  /// Stops the engine and the polling (the helper's input ended). Nothing is deleted, and the shares stay set.
  Future<void> stop() async {
    _stopped = true;
    _poll?.cancel();
    _poll = null;
    await _locked(() async {
      final c = _core;
      _core = null;
      try {
        await c?.close();
      } catch (e) {
        log?.call('sharing: stopping the engine failed: $e');
      }
    });
  }

  /// The server's own Bookshelves log, `log/<its id>.jsonl`, is never replaced by another device's copy of it (a backup put back on a
  /// phone is an older copy that looks newer to the engine). The Rust server is the one writer of that file; the other devices' logs
  /// still arrive beside it. The engine's own id is the id the log is named by (`<data>/sync` is the identity the server reads), so it
  /// is known only after the engine is open; it is set before the folder is shared, and again at every open.
  Future<void> _keepOwnLog() async {
    final id = status['id'];
    if (id is! String || id.isEmpty) return;
    final own = ['$kBookshelvesLogDir/$id.jsonl'];
    _neverFetch[kBookshelvesShareId] = own;
    await _engine('set_never_fetch', {'id': kBookshelvesShareId, 'never_fetch': own});
  }

  /// Shared folders earlier versions had and this one does not (the same list the phone retires).
  static const List<String> retiredShares = ['shared'];

  Future<void> _retire() async {
    for (final id in retiredShares) {
      if (shareOf(id) == null) continue;
      try {
        await _engine('share_remove', {'id': id});
        log?.call('sharing: stopped sharing a folder this version no longer shares; its files stay ($id)');
      } catch (e) {
        log?.call('sharing: could not stop sharing a retired folder ($id): $e');
      }
    }
  }

  /// Shares every folder given that is not shared yet (its folder is made if it is missing).
  Future<void> _addFolders(List<(String, String, Directory)> folders) async {
    for (final (id, name, dir) in folders) {
      if (shareOf(id) != null) continue;
      try {
        dir.createSync(recursive: true);
        await _engine('share_add', {'id': id, 'name': name, 'path': dir.path});
      } catch (e) {
        log?.call('sharing: could not share $name: $e');
      }
    }
  }

  // ---- the status cache

  Future<void> _tick() async {
    if (_polling || _core == null) return;
    _polling = true;
    try {
      await _refresh();
      // The photos an entry refers to change with the notebooks: the gate is kept current (the phone's every 30 s).
      if (++_ticks % 15 == 0) await refreshGate();
    } finally {
      _polling = false;
    }
  }

  Future<void> _refresh() async {
    final c = _core;
    if (c == null) return;
    try {
      status = await c.call('status');
      _noteShareChanges();
    } catch (_) {}
  }

  /// Each shared folder's files and bytes as last seen with nothing pending: what a change is measured against.
  final Map<String, (int, int)> _settled = {};

  void _noteShareChanges() {
    final changed = <String>{};
    for (final sh in shares) {
      final id = sh['id'];
      if (id is! String) continue;
      final now = (((sh['files'] as num?) ?? 0).toInt(), ((sh['bytes'] as num?) ?? 0).toInt());
      final before = _settled[id];
      // The first look only notes where the folder stands, even mid-sync, so what that sync brings is still a change when it
      // settles.
      if (before == null) {
        _settled[id] = now;
        continue;
      }
      if (((sh['pending_files'] as num?) ?? 0) > 0) continue;
      _settled[id] = now;
      if (before != now) changed.add(id);
    }
    for (final id in changed) {
      _changed[id] = (_changed[id] ?? 0) + 1;
    }
    if (changed.isNotEmpty) onShareChanged?.call(changed);
  }

  List<Map<String, dynamic>> get peers => [for (final p in (status['peers'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
  List<Map<String, dynamic>> get shares => [for (final p in (status['shares'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
  Map<String, dynamic>? shareOf(String id) => shares.where((s) => s['id'] == id).firstOrNull;

  /// What the browser reads (`sharing.state`): the cached engine status, never a fresh engine call.
  ///
  /// `{enabled, running, starting, error, name, status, ask_since, kinds, off, changed, link}`: `status` is the engine's `status` as
  /// last polled (`{}` before the engine runs); `kinds` is the share table (`[{id, label, shares: [share ids]}]`); `off` the items
  /// switched off by kind (item keys `<share>/<path>`); `changed` the per-share counter of settled changes; `link` the
  /// `link_start` progress.
  Map<String, dynamic> snapshot() => {
        'enabled': _enabled,
        'running': running,
        'starting': _starting,
        'error': error,
        'name': (status['name'] as String?) ?? deviceName,
        'status': status,
        'ask_since': _askSince,
        'kinds': [
          for (final k in table.kinds) {'id': k.id, 'label': k.label, 'shares': k.shares.keys.toList()},
        ],
        'off': {for (final e in _off.entries) if (e.value.isNotEmpty) e.key: ([...e.value]..sort())},
        'changed': {..._changed},
        'settings_applied': settingsApplied?.call() ?? 0,
        'private_included': privateIncluded?.call() ?? const <String>[],
        'link': {..._link},
      };

  // ---- what is shared

  /// Whether the kind shares something here (its switch is on).
  bool kindOn(ShareKind k) => k.shares.keys.any((id) => shareOf(id) != null);

  ShareKind _kind(Object? id) {
    for (final k in table.kinds) {
      if (k.id == id) return k;
    }
    throw CacheSearchException('bad_args', 'No such kind to share: $id');
  }

  /// Private items left out of a share: the paths the helper says are private and not switched on (the notebooks' folders). Set by
  /// the helper ([attachNotebookSync]).
  List<String> Function(String shareId)? extraOff;

  /// The files the engine may send from the gated folder of share [id] (the notebooks' photos), given the share's off list. Set by the
  /// helper; a gated share with none sends nothing.
  Future<List<String>> Function(String shareId, List<String> off)? photosAllowed;

  /// The private notebooks switched on ("Include in sync and sharing"), and the switch. Set by the helper.
  List<String> Function()? privateIncluded;
  Future<void> Function(String notebookId, bool on)? setPrivateIncluded;

  /// The paths switched off in the share [id] of [k], as the engine's patterns: the items switched off, and the private items not
  /// switched on.
  List<String> _offOf(ShareKind k, String id) => ({
        for (final key in _off[k.id] ?? const <String>{})
          if (key.startsWith('$id/')) key.substring(id.length + 1),
        ...?extraOff?.call(id),
      }).toList()
        ..sort();

  /// The off lists last given to the engine's `set_off` are in [_sentOff]; the gate each share was last given:
  final Map<String, Map<String, Object?>> _sentGate = {};

  /// The gate for [id] of [k] as it is now: null when the share has none. A failure to work it out sends nothing from the folder
  /// rather than everything.
  Future<Map<String, Object?>?> _gateOf(ShareKind k, String id) async {
    final dir = k.gated[id];
    if (dir == null) return null;
    final allowed = photosAllowed;
    if (allowed == null) return {'dir': dir, 'allow': const <String>[]};
    try {
      return {'dir': dir, 'allow': await allowed(id, _offOf(k, id))};
    } catch (e) {
      log?.call('sharing: could not work out which files may be sent ($id): $e');
      return {'dir': dir, 'allow': const <String>[]};
    }
  }

  Future<Map<String, Map<String, Object?>>> _gates() async {
    final out = <String, Map<String, Object?>>{};
    for (final k in table.kinds) {
      for (final id in k.shares.keys) {
        final g = await _gateOf(k, id);
        if (g != null) out[id] = _sentGate[id] = g;
      }
    }
    return out;
  }

  Future<void> _applyGate(ShareKind k, String id) async {
    final g = await _gateOf(k, id);
    if (_core == null || g == null) return;
    if (_sentGate[id] != null && jsonEncode(_sentGate[id]) == jsonEncode(g)) return;
    try {
      await _engine('set_gate', {'id': id, ...g});
      _sentGate[id] = g;
    } catch (e) {
      log?.call('sharing: could not set which files may be sent ($id): $e');
    }
  }

  /// Before something writes files into a gated folder (notebook sync, its photos), and every 30 s: the engine's list of what may be
  /// sent from it is made current.
  Future<void> refreshGate() => _locked(() async {
        for (final k in table.kinds) {
          for (final id in k.shares.keys) {
            if (k.gated[id] != null) await _applyGate(k, id);
          }
        }
      });

  /// The off lists (and what they change, the photo gate) are given to the engine again: the private notebooks left out changed.
  Future<void> refreshOff() => _locked(() async {
        if (_core == null) return;
        await _applyOff();
      });

  Future<void> _applyOff() async {
    for (final k in table.kinds) {
      for (final id in k.shares.keys) {
        final off = _offOf(k, id);
        if (_sentOff[id] != null && _sameList(_sentOff[id]!, off)) continue;
        try {
          await _engine('set_off', {'id': id, 'off': off});
          _sentOff[id] = off;
        } catch (e) {
          log?.call('sharing: could not set the items switched off ($id): $e');
        }
        // An item switched on or off changes which photos something shared refers to.
        await _applyGate(k, id);
      }
    }
  }

  /// Switches one kind on or off: every folder of it. On shares every item; off stops sharing it, and the files stay.
  Future<void> setKind(String kind, bool on) => _locked(() async {
        final k = _kind(kind);
        _needCore();
        if (!on) {
          for (final id in k.shares.keys) {
            // The engine keeps the share's history, so the kind switched on again keeps both devices' edits and deletes.
            if (shareOf(id) != null) await _engine('share_remove', {'id': id, 'keep_history': true});
          }
          return;
        }
        await _addKind(k);
      });

  /// Told after a kind was switched on (not awaited): notebook sync makes the notebooks and its folder the same at once. Set by the
  /// helper.
  Future<void> Function(String kind, bool on)? kindSet;

  /// Run before a kind's off list is given to the engine and its folders are shared (notebook sync reads which private notebooks are
  /// left out). Set by the helper; a failure is only logged.
  Future<void> Function(String kind)? beforeKindOn;

  Future<void> _addKind(ShareKind k) async {
    try {
      await beforeKindOn?.call(k.id);
    } catch (e) {
      log?.call('sharing: could not prepare ${k.id}: $e');
    }
    await _applyOff();
    await _addShares(k);
    final told = kindSet;
    if (told != null) unawaited(told(k.id, true));
  }

  Future<void> _addShares(ShareKind k) async {
    for (final e in k.shares.entries) {
      if (shareOf(e.key) != null) continue;
      final dir = Directory(e.value);
      dir.createSync(recursive: true);
      await _engine('share_add', {'id': e.key, 'name': k.shares.length == 1 ? k.label : '${k.label} (${e.key})', 'path': dir.path});
    }
  }

  /// Switches one item ([key] is `<share>/<path>`, [ShareItem.key] on the phone) on or off. Switching one on in a kind that is off
  /// shares the kind with that item alone, which needs [all], the keys of every item of the kind as the browser lists them.
  Future<void> setItem(String kind, String key, bool on, {List<String>? all}) => _locked(() async {
        final k = _kind(kind);
        _needCore();
        if (on && !kindOn(k)) {
          if (all == null) throw const CacheSearchException('bad_args', 'Switching an item on in a kind that is off needs "all": every item of the kind');
          _off[k.id] = {for (final x in all) if (x != key) x};
          _save();
          await _addKind(k);
          return;
        }
        final off = _off.putIfAbsent(k.id, () => <String>{});
        on ? off.remove(key) : off.add(key);
        _save();
        await _applyOff();
        await _refresh();
      });

  /// What the always-shared folder [id] fetches from now on (the engine's patterns); kept, and given at the next open too.
  Future<void> setOnly(String id, List<String> patterns) => _locked(() async {
        final sorted = [...patterns]..sort();
        final before = _only[id];
        if (before != null && _sameList(before, sorted)) return;
        _only[id] = sorted;
        if (_core == null) return;
        await _engine('set_only', {'id': id, 'only': sorted});
      });

  /// What the always-shared folder [id] never fetches, on top of [setOnly].
  Future<void> setNeverFetch(String id, List<String> patterns) => _locked(() async {
        final sorted = [...patterns]..sort();
        if (_sameList(_neverFetch[id] ?? const <String>[], sorted)) return;
        _neverFetch[id] = sorted;
        if (_core == null) return;
        await _engine('set_never_fetch', {'id': id, 'never_fetch': sorted});
      });

  /// The keys for [peer] ({name: key}), held by the engine in memory and sent only to [peer]. Inside the host only: a browser may not
  /// call it (see [invoke]).
  Future<void> setSecrets(String peer, Map<String, String> secrets) async {
    _needCore();
    await _engine('set_secrets', {'peer': peer, 'secrets': secrets});
  }

  /// The keys linked devices sent since the last call, by device, handed over once. Inside the host only.
  Future<Map<String, Map<String, String>>> takeSecrets() async {
    _needCore();
    final r = await _engine('take_secrets');
    final m = r['secrets'];
    if (m is! Map) return const {};
    return {
      for (final e in m.entries)
        if (e.value is Map) '${e.key}': {for (final k in (e.value as Map).entries) if (k.value is String) '${k.key}': k.value as String},
    };
  }

  // ---- linking

  Map<String, dynamic> _link = {'state': 'idle'};

  /// Links with the device that showed [code] without waiting for it: returns at once, and the snapshot's `link` goes
  /// `{state: "linking"}`, then `{state: "done", peer, name}` or `{state: "failed", error}` (until the next `link_start`).
  Future<Map<String, dynamic>> linkStart(String code) async {
    _needCore();
    if (_link['state'] == 'linking') throw const CacheSearchException('busy', 'Already linking with a device');
    _link = {'state': 'linking'};
    unawaited(() async {
      try {
        final r = await _core!.call('link', {'code': code});
        _link = {'state': 'done', 'peer': r['peer'] as String? ?? '', 'name': r['name'] as String? ?? 'the other device'};
      } catch (e) {
        _link = {'state': 'failed', 'error': e is CacheSearchException ? e.message : '$e'};
      }
      await _refresh();
    }());
    return {..._link};
  }

  // ---- the engine

  void _needCore() {
    if (_core == null) throw CacheSearchException('sync', error ?? 'Sharing is not set up');
  }

  Future<Map<String, dynamic>> _engine(String method, [Map<String, Object?> args = const {}]) async {
    _needCore();
    final r = await _core!.call(method, args);
    await _refresh();
    return r;
  }

  /// The engine methods a browser may call through `sharing.call`: the ones that need no more than the device's own say. Everything
  /// else is the host's (shares, off lists and what links they are kept with come from the share table and the person's choices
  /// above; a browser does not name folders) or has its own op (`link`: `sharing.link_start`). `status` is served from the cache.
  ///
  /// `key_names` and `set_key_on` are not the engine's: the host answers them itself, from [keyNames] and [setKeyOn] (the settings
  /// sync's key list and tick). They give a browser the names of the keys that can go to a linked device and which are ticked, and
  /// take a tick; a key's value is in neither.
  static const Set<String> browserMethods = {'link_code', 'unlink', 'set_name', 'set_peer_name', 'set_link', 'sync_now', 'share_items', 'key_names', 'set_key_on'};

  /// The names of keys that can sync and the devices each is ticked for (`[{name, on: [device ids]}]`), set by the helper.
  List<Map<String, Object?>> Function()? keyNames;

  /// Told after a browser's `set_link` went through: the device and its record as it was just before (a copy; null when it was not
  /// there). The settings sync seeds what the link now sends from it. Set by the helper; not called for the host's own calls.
  Future<void> Function(String peer, Map<String, dynamic>? before)? onLinkSet;

  /// Ticks or unticks the key [name] for the device [peer]; answers like [keyNames]. Set by the helper.
  Future<List<Map<String, Object?>>> Function(String peer, String name, bool on)? setKeyOn;

  /// The engine's key methods, which a browser may never reach (the host does them itself).
  static const Set<String> secretMethods = {'set_secrets', 'take_secrets'};

  /// One engine method, as `sharing.call` runs it. [trusted] is true for the host's own code and false for a browser's request.
  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> args, {bool trusted = false}) async {
    if (method == 'status') {
      _needCore();
      return status;
    }
    if (!trusted && !browserMethods.contains(method)) {
      final why = secretMethods.contains(method) ? 'Keys are handled on the server only' : 'Not available from a browser';
      throw CacheSearchException('forbidden', '$why: $method');
    }
    if (method == 'key_names') {
      final f = keyNames;
      if (f == null) throw const CacheSearchException('sync', 'Keys are not kept on this server');
      return {'keys': f()};
    }
    if (method == 'set_key_on') {
      final f = setKeyOn;
      if (f == null) throw const CacheSearchException('sync', 'Keys are not kept on this server');
      final on = args['on'];
      if (on is! bool) throw const CacheSearchException('bad_args', '"on" (true or false) is required');
      return {'keys': await f(_str(args, 'peer'), _str(args, 'name'), on)};
    }
    final hear = !trusted && method == 'set_link' ? onLinkSet : null;
    if (hear == null) return _locked(() => _engine(method, args.cast<String, Object?>()));
    Map<String, dynamic>? before;
    final r = await _locked(() {
      final p = peers.where((p) => p['id'] == args['peer']).firstOrNull;
      before = p == null ? null : (jsonDecode(jsonEncode(p)) as Map).cast<String, dynamic>();
      return _engine(method, args.cast<String, Object?>());
    });
    final peer = args['peer'];
    if (peer is String) {
      try {
        await hear(peer, before);
      } catch (e) {
        log?.call('sharing: a link change could not be seeded: $e');
      }
    }
    return r;
  }

  /// The one dispatch of the host's `sharing.*` ops (see [SharingOps]); the host's own code may use it as well with [trusted].
  Future<Object?> invoke(String op, Map<String, dynamic> a, {bool trusted = false}) async {
    switch (op) {
      case 'sharing.state':
        return snapshot();
      case 'sharing.setup':
        await setUp();
        return snapshot();
      case 'sharing.set_kind':
        await setKind(_str(a, 'kind'), a['on'] == true);
        return snapshot();
      case 'sharing.set_item':
        final all = a['all'];
        await setItem(_str(a, 'kind'), _str(a, 'key'), a['on'] == true, all: all is List ? [for (final x in all) '$x'] : null);
        return snapshot();
      case 'sharing.set_private':
        // A private notebook's "Include in sync and sharing" (the notebooks' own switch, kept by the notebook sync).
        final set = setPrivateIncluded;
        if (set == null) throw const CacheSearchException('sync', 'Notebooks are not synced on this server');
        final on = a['on'];
        if (on is! bool) throw const CacheSearchException('bad_args', '"on" (true or false) is required');
        await set(_str(a, 'notebook'), on);
        return snapshot();
      case 'sharing.link_start':
        return await linkStart(_str(a, 'code'));
      case 'sharing.call':
        final args = a['args'];
        return await call(_str(a, 'method'), args is Map ? args.cast<String, dynamic>() : const {}, trusted: trusted);
    }
    throw CacheSearchException('unsupported', 'No such sharing op: $op');
  }

  static String _str(Map<String, dynamic> a, String k) {
    final v = a[k];
    if (v is! String || v.isEmpty) throw CacheSearchException('bad_args', '"$k" (string) is required');
    return v;
  }

  Future<SyncCoreLike> _openReal(Map<String, Object?> config) async => _RealCore(await SyncCore.open(config, libraryPath: libraryPath));
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The helper's `sharing.*` ops: what a browser (and the Rust server) asks of the host. They reach the host only as untrusted
/// requests; the host's own work calls its methods directly.
class SharingOps implements OpHandler {
  SharingOps(this.host);

  final SharingHost host;

  static const Set<String> ops = {'sharing.state', 'sharing.setup', 'sharing.set_kind', 'sharing.set_item', 'sharing.set_private', 'sharing.link_start', 'sharing.call'};

  @override
  bool handles(String op) => op.startsWith('sharing.');

  @override
  Future<Object?> handle(String op, Map<String, dynamic> args) => host.invoke(op, args);
}

// ---- what the engine needs, and the share table

/// What the host needs from the engine (the real one is [SyncCore]; tests give a fake): the phone's `SyncCoreLike`.
abstract class SyncCoreLike {
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args]);
  Future<void> close();
}

typedef SyncOpener = Future<SyncCoreLike> Function(Map<String, Object?> config);

class _RealCore implements SyncCoreLike {
  _RealCore(this._c);

  final SyncCore _c;

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) => _c.call(method, args);

  @override
  Future<void> close() => _c.close();
}

/// One kind of thing that can be shared (the phone's `DataKind`, as far as sharing goes): its folders by their fixed share ids
/// (the same ids as on a phone, so a kind on two linked devices is one shared folder) and what never syncs in them.
class ShareKind {
  const ShareKind({required this.id, required this.label, required this.shares, this.notShared = const {}, this.gated = const {}});

  final String id;
  final String label;

  /// Share id -> the folder on the server.
  final Map<String, String> shares;
  final Map<String, List<String>> notShared;

  /// Share id -> a folder inside it that every item uses (the notebooks' `photos`), from which the engine sends only the files the
  /// host says may go (the engine's `gate`).
  final Map<String, String> gated;
}

/// A folder shared whatever is ticked once sharing is set up (the search indexes), with its sync rules.
class ShareAlways {
  const ShareAlways({required this.id, required this.name, required this.dir, this.exclude = const [], this.localDeletes = const [], this.last = const [], this.hidden = const []});

  final String id;
  final String name;
  final Directory dir;
  final List<String> exclude, localDeletes, last, hidden;
}

/// A folder kept only with the linked devices whose link is one of [modes] (the phone's `LinkShare`).
class ShareLink {
  const ShareLink({required this.id, required this.name, required this.dir, required this.modes});

  final String id;
  final String name;
  final Directory dir;
  final List<String> modes;
}

/// The server's share table: the phone's kinds (app/lib/main.dart `dataKinds`) on the server's folders, all under `<data>`
/// (`<support>` is `<data>/app/support`, `<docs>` is `<data>/app/docs`).
///
/// | share | folder |
/// |---|---|
/// | `library` | `<docs>/zims` |
/// | `libraries` | `<docs>/libraries` (never `*/index`) |
/// | `maps` | `<support>/layers` |
/// | `regions` | `<support>/regions` |
/// | `models` | `<data>/models` (never a download's `.part`) |
/// | `notebooks` | `<support>/notebook-share` |
/// | `videos` | `<docs>/videos` |
/// | `indexes` (always) | `<support>/shared-indexes` |
/// | `settings` (Match, Send mine) | `<support>/settings-sync` |
/// | `bookshelves` (Match) | `<data>/bookshelves` |
class ShareTable {
  ShareTable({required this.kinds, required this.always, required this.links});

  factory ShareTable.forServer({required Directory dataDir, required Directory supportDir, required Directory docsDir}) {
    final data = dataDir.path, support = supportDir.path, docs = docsDir.path;
    return ShareTable(
      kinds: [
        ShareKind(
          id: 'library',
          label: 'Library',
          shares: {'library': '$docs/zims', 'libraries': '$docs/libraries'},
          notShared: {'library': kZimNotShared, 'libraries': kLibraryNotShared},
        ),
        ShareKind(
          id: 'regions',
          label: 'Regions',
          shares: {'maps': '$support/layers', 'regions': '$support/regions'},
          notShared: {'maps': kMapLayersNotShared, 'regions': kRegionsNotShared},
        ),
        ShareKind(
          id: 'models',
          label: 'Models',
          shares: {'models': '$data/models'},
          // The embedder's download is `<file>.part` in this folder and is not hidden, so the engine would offer it.
          notShared: {'models': kServerModelsNotShared},
        ),
        ShareKind(
          id: 'notebooks',
          label: 'Notebooks',
          shares: {'notebooks': '$support/$kNotebookShareDir'},
          // Every notebook's photos share one folder; a photo goes only when an entry of a shared notebook refers to it.
          gated: {'notebooks': 'photos'},
        ),
        ShareKind(id: 'videos', label: 'Videos and weather', shares: {'videos': '$docs/videos'}),
      ],
      always: [
        ShareAlways(
          id: kIndexesShareId,
          name: 'Search indexes',
          dir: Directory('$support/$kIndexesDirName'),
          exclude: kIndexesNotShared,
          localDeletes: kIndexesLocalDeletes,
          last: kIndexesLast,
          hidden: kIndexesHidden,
        ),
      ],
      links: [
        ShareLink(id: kSettingsShareId, name: 'Settings', dir: Directory('$support/$kSettingsShareDir'), modes: kSettingsShareModes),
        // The server's Bookshelves log is `<data>/bookshelves` (the Rust server is its one writer), not a folder under support.
        ShareLink(id: kBookshelvesShareId, name: 'Bookshelves', dir: Directory('$data/$kBookshelvesDir'), modes: kBookshelvesShareModes),
      ],
    );
  }

  final List<ShareKind> kinds;
  final List<ShareAlways> always;
  final List<ShareLink> links;
}

/// The folder of the Bookshelves log's files inside the share (`<data>/bookshelves/log/<device id>.jsonl`, the Rust `LOG_DIR`).
const String kBookshelvesLogDir = 'log';

/// What never syncs in the server's models folder: a download in progress (`<file>.part`).
const List<String> kServerModelsNotShared = ['*.part', '**/*.part'];
