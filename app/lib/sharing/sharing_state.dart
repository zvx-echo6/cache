import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../files.dart';
import '../settings/data_kinds.dart';
import '../settings/data_policy.dart';
import '../settings/space.dart' show reserveFor, totalBytesOnDisk;
import '../platform/app_log.dart';

/// The sync engine as the Sharing screen sees it: set up or not, its status (polled while anything watches), and the actions.
/// Sharing starts only once the person sets it up; until then nothing is published or listened for.
///
/// What is shared is chosen per kind (the kind's switch) and per item inside it (a library, a map layer, a model, a notebook, a
/// video). Under the hood each kind's folder stays one share, carrying the list of the items switched off on this device (the
/// engine's `off`, see cache_sync's Config): never one share per item. An item switched off is neither fetched nor offered, and
/// a kind switched off is not shared at all; either way the files stay.
class SharingState extends ChangeNotifier {
  SharingState({
    required this.policy,
    required this.supportDir,
    required this.kinds,
    this.always = const [],
    this.linkShares = const [],
    this.deviceName = 'Cache device',
    SyncOpener? opener,
    int Function(String dir)? reserveBytes,
  }) : _reserveBytes = reserveBytes ?? _storageReserve,
       _opener = opener ?? _openReal;

  /// Folders linked devices keep the same whatever the person ticks (the search indexes), once sharing is set up.
  final List<AlwaysShared> always;

  /// Folders kept only with some linked devices, by how settings go between them (the device's page): never listed under
  /// Sharing and sync, set up once sharing is (see [LinkShare]).
  final List<LinkShare> linkShares;

  final DataPolicy policy;
  final Future<Directory> Function() supportDir;
  /// The kinds that can be shared (the app's one list of kinds and folders, which Storage measures too). Each folder has a fixed share
  /// id, so the same kind of thing on two linked devices is one shared folder (tick Models on both and their models are kept the same).
  final List<DataKind> kinds;
  final String deviceName;
  final SyncOpener _opener;

  /// What Cache leaves free on the phone, for the volume holding a folder: the same rule Storage shows ([reserveFor]).
  final int Function(String dir) _reserveBytes;

  static int _storageReserve(String dir) => reserveFor(totalBytesOnDisk(dir));

  SyncCoreLike? _core;
  bool _enabled = false;
  bool _starting = false;
  String? error;
  Map<String, dynamic> status = const {};
  Timer? _poll;
  StreamSubscription<ConnectionKind>? _net;

  bool get enabled => _enabled;
  bool get running => _core != null;
  bool get starting => _starting;

  Future<File> _flag() async => File('${(await supportDir()).path}/sharing.json');

  /// The items switched off, by kind id ([ShareItem.key]s), kept in sharing.json beside "enabled". A kind with none listed has
  /// every item on: what a kind ticked before items existed shares as it did.
  final Map<String, Set<String>> _off = {};

  /// Since when links are new ones (ms, kept in sharing.json as `ask_since`): the time this version first ran, or sharing was
  /// set up. A link made since starts with nothing going between the two until the person answers; one made before keeps
  /// counting as Match (see [linkedSinceAsking]).
  int? _askSince;

  /// [peer] was linked since this version asks how settings go ([_askSince]).
  bool linkedSinceAsking(String peer) {
    final at = peerOf(peer)?['linked'];
    return _askSince != null && at is int && at >= _askSince!;
  }

  /// Starts sharing if it was set up before.
  Future<void> init() async {
    try {
      final f = await _flag();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
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
        await _save();
      }
      if (j['enabled'] == true) {
        _enabled = true;
        await _start();
      }
    } catch (e) {
      error = 'Sharing could not start: $e';
      notifyListeners();
    }
  }

  Future<void> _save() async {
    final f = await _flag();
    await f.parent.create(recursive: true);
    await writeStringAtomic(
      f,
      jsonEncode({
        'enabled': _enabled,
        'ask_since': ?_askSince,
        if (_off.values.any((v) => v.isNotEmpty)) 'off': {for (final e in _off.entries) if (e.value.isNotEmpty) e.key: [...e.value]..sort()},
      }),
    );
  }

  /// The first time: creates this device's identity and starts sharing.
  Future<void> setUp() async {
    _enabled = true;
    _askSince ??= DateTime.now().millisecondsSinceEpoch;
    await _save();
    await _start();
  }

  Future<void> _start() async {
    if (_core != null || _starting) return;
    _starting = true;
    error = null;
    notifyListeners();
    try {
      final dir = Directory('${(await supportDir()).path}/sync');
      // What each device builds for itself inside a shared folder never syncs (a library's search index).
      _core = await _opener({
        'dir': dir.path,
        'name': deviceName,
        // The engine keeps the same space free as Storage shows, so This device and Storage agree.
        'reserve_bytes': _reserveBytes((await supportDir()).path),
        'exclude': {for (final k in kinds) ...k.notShared, for (final a in always) a.id: a.exclude},
        'local_deletes': {for (final a in always) a.id: a.localDeletes},
        'last': {for (final a in always) a.id: a.last},
        'hidden': {for (final a in always) a.id: a.hidden},
        // An always-shared folder fetches nothing until the app says what it may fetch (setOnly).
        'only': {for (final a in always) a.id: _only[a.id] ?? const <String>[]},
        'never_fetch': {for (final e in _neverFetch.entries) e.key: e.value},
        // The items switched off, from the start, so the first round already leaves them out.
        'off': {for (final k in shareKinds) for (final id in k.shared().keys) id: _sentOff[id] = _offOf(k, id)},
        // Folders kept only with some linked devices (the Bookshelves log with Match devices, the settings log with Match and
        // Send mine).
        'with': {for (final l in linkShares) l.id: l.modes},
      });
      await _applyPolicy();
      await refresh();
      await _retire();
      await _repointAll();
      await _addAlways();
      await _addLinkShares();
      await refreshItems();
      _net = policy.probe.changes.listen((_) async {
        try {
          await _core?.call('network_changed');
          await _applyPolicy();
        } catch (_) {}
      });
      // Switching mobile data for downloads on or off applies at once, mid-transfer too.
      policy.settings.addListener(_onSettings);
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
      await refresh();
    } catch (e) {
      error = 'Sharing could not start: ${e is CacheSearchException ? e.message : e}';
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  /// Every folder this device shares whose engine path is no longer where the app keeps it (the app's container path changes
  /// across iOS installs and updates): the same id is added again with the current path, which the engine re-points (it keeps
  /// the name, and its first scan after the move records no deletes). Run on every start.
  Future<void> _repointAll() async {
    final folders = <String, Directory?>{
      for (final a in always) a.id: a.dir(),
      for (final l in linkShares) l.id: l.dir(),
      for (final k in shareKinds) ...k.shared(),
    };
    for (final e in folders.entries) {
      final d = e.value;
      final sh = shareOf(e.key);
      if (d == null || sh == null || sh['path'] == d.path) continue;
      try {
        await d.create(recursive: true);
        await _call('share_add', {'id': e.key, 'name': sh['name'], 'path': d.path});
      } catch (e2) {
        logError('Could not point a shared folder at its new place', error: e2, detail: '${sh['name']}');
      }
    }
    await refresh();
  }

  /// What each always-shared folder may fetch, as last set (see [setOnly]).
  final Map<String, List<String>> _only = {};

  /// Shares every always-shared folder that is not shared yet (its folder is made if it is missing).
  Future<void> _addAlways() async {
    for (final a in always) {
      final d = a.dir();
      if (d == null || shareOf(a.id) != null) continue;
      try {
        await d.create(recursive: true);
        await _call('share_add', {'id': a.id, 'name': a.name, 'path': d.path});
      } catch (e) {
        logError('Could not share', error: e, detail: a.name);
      }
    }
  }

  /// Shares every folder of [linkShares] that is not shared yet (its folder is made if it is missing).
  Future<void> _addLinkShares() async {
    for (final l in linkShares) {
      final d = l.dir();
      if (d == null || shareOf(l.id) != null) continue;
      try {
        await d.create(recursive: true);
        await _call('share_add', {'id': l.id, 'name': l.name, 'path': d.path});
      } catch (e) {
        logError('Could not share', error: e, detail: l.name);
      }
    }
  }

  /// This device's key (its identity for linked devices), once sharing runs.
  String? get myId => status['id'] as String?;

  /// What this device and [peer] keep about their link (how settings go between them), as last set on either; null until set.
  Map<String, dynamic>? linkOf(String peer) => (peerOf(peer)?['link'] as Map?)?.cast<String, dynamic>();

  /// Sets what this device and [peer] keep about their link; [peer] takes it with the next sync.
  Future<void> setLink(String peer, Map<String, Object?> link) => _call('set_link', {'peer': peer, 'link': link});

  /// The keys for [peer] ({secure-storage name: key}): held by the sync engine in memory only and sent only to [peer], over its
  /// own encrypted connection, when it asks. Empty: none.
  Future<void> setSecrets(String peer, Map<String, String> secrets) async {
    final c = _core;
    if (c == null) return;
    await c.call('set_secrets', {'peer': peer, 'secrets': secrets});
  }

  /// The keys linked devices sent since the last call, by device ({device: {name: key}}), handed over once.
  Future<Map<String, Map<String, String>>> takeSecrets() async {
    final c = _core;
    if (c == null) return const {};
    final r = await c.call('take_secrets');
    final m = r['secrets'];
    if (m is! Map) return const {};
    return {
      for (final e in m.entries)
        if (e.value is Map) '${e.key}': {for (final k in (e.value as Map).entries) if (k.value is String) '${k.key}': k.value as String},
    };
  }

  /// What this device fetches of the always-shared folder [id] from now on: the paths [patterns] cover (the sync engine's
  /// patterns), as the sources on this device change. Kept, and given to the engine at its next start too.
  Future<void> setOnly(String id, List<String> patterns) async {
    final sorted = [...patterns]..sort();
    final before = _only[id];
    if (before != null && listEquals(before, sorted)) return;
    _only[id] = sorted;
    final c = _core;
    if (c == null) return;
    try {
      await c.call('set_only', {'id': id, 'only': sorted});
    } catch (e) {
      logError('Sync: could not set what a device fetches', error: e, detail: _nameOf(id));
    }
  }

  final Map<String, List<String>> _neverFetch = {};

  /// What this device never fetches of the always-shared folder [id] (on top of [setOnly]): kept, and given to the engine at its
  /// next start too.
  Future<void> setNeverFetch(String id, List<String> patterns) async {
    final sorted = [...patterns]..sort();
    if (listEquals(_neverFetch[id] ?? const <String>[], sorted)) return;
    _neverFetch[id] = sorted;
    final c = _core;
    if (c == null) return;
    try {
      await c.call('set_never_fetch', {'id': id, 'never_fetch': sorted});
    } catch (e) {
      logError('Sync: could not set what a device never fetches', error: e, detail: _nameOf(id));
    }
  }

  String _nameOf(String id) => always.where((x) => x.id == id).firstOrNull?.name ?? id;

  bool? _lastMobile;

  void _onSettings() {
    if (_lastMobile == policy.settings.mobileForDownloads) return;
    _lastMobile = policy.settings.mobileForDownloads;
    _applyPolicy().catchError((_) {});
  }

  /// Sync uses the network the way downloads do: Wi-Fi and other connections always, mobile data only when downloads may use it.
  Future<void> _applyPolicy() async {
    final kind = await policy.probe.current();
    final ok = kind != ConnectionKind.none && !(kind == ConnectionKind.mobile && !policy.settings.mobileForDownloads);
    await _core?.call('set_policy', {'network': ok});
  }

  Future<void> refresh() async {
    final c = _core;
    if (c == null) return;
    try {
      status = await c.call('status');
      _noteShareChanges();
      notifyListeners();
    } catch (_) {}
  }

  int _ticks = 0;

  /// Every 2 s the status; every 10 s what each linked device holds, and the items' list given to the engine again if it
  /// changed (a notebook made private, a new library here).
  Future<void> _tick() async {
    await refresh();
    if (++_ticks % 5 == 0) {
      await refreshItems();
      await _applyOff();
    }
  }

  /// Shared folders earlier versions had and this one does not: the Shared folder (1.0). Each stops being shared at start; its
  /// files stay where they are, and nothing is deleted on any device.
  static const List<String> retiredShares = ['shared'];

  Future<void> _retire() async {
    for (final id in retiredShares) {
      if (shareOf(id) == null) continue;
      try {
        await _call('share_remove', {'id': id});
        logInfo('Sync: stopped sharing a folder this version no longer shares; its files stay', detail: id);
      } catch (e) {
        logError('Sync: could not stop sharing a retired folder', error: e, detail: id);
      }
    }
  }

  /// The kinds under "Shared with linked devices", in their order there.
  List<DataKind> get shareKinds {
    const order = ['library', 'regions', 'models', 'notebooks', 'videos'];
    final list = [for (final k in kinds) if (k.shared().isNotEmpty) k];
    int at(DataKind k) => order.contains(k.id) ? order.indexOf(k.id) : order.length + kinds.indexOf(k);
    return list..sort((a, b) => at(a).compareTo(at(b)));
  }

  /// The kind shares something here (its switch is on).
  bool kindOn(DataKind k) => sharesOfKind(k).isNotEmpty;

  /// What this device and each linked device hold of each shared folder, by share id (the engine's `share_items`), as last read.
  final Map<String, List<Map<String, dynamic>>> _listed = {};

  /// Reads again what each shared folder holds, here and on the linked devices (the items a device has not fetched yet show too).
  Future<void> refreshItems() async {
    final c = _core;
    if (c == null) return;
    var changed = false;
    for (final k in shareKinds) {
      for (final id in k.shared().keys) {
        try {
          final r = await c.call('share_items', {'id': id, 'depth': k.itemDepth[id] ?? 1});
          final rows = [for (final i in (r['items'] as List? ?? const [])) (i as Map).cast<String, dynamic>()];
          _listed[id] = rows;
          changed = true;
        } catch (_) {}
      }
    }
    if (changed) notifyListeners();
  }

  /// Every item of [k]: those on this device (as the app lists them), then those only a linked device holds.
  List<SharedItem> itemsOf(DataKind k) {
    final out = <String, SharedItem>{for (final it in k.items?.call() ?? const <ShareItem>[]) it.key: SharedItem(it, here: true)};
    for (final id in k.shared().keys) {
      for (final row in _listed[id] ?? const <Map<String, dynamic>>[]) {
        final path = row['name'];
        if (path is! String || path.isEmpty) continue;
        final peers = [for (final p in (row['peers'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
        final mine = (row['bytes'] as num?)?.toInt() ?? 0;
        final theirs = peers.fold<int>(0, (n, p) => max(n, (p['bytes'] as num?)?.toInt() ?? 0));
        final names = [for (final p in peers) if (p['peer_name'] is String) p['peer_name'] as String];
        final it = k.remoteItem != null ? k.remoteItem!(id, path, theirs) : ShareItem.plain(id, path, theirs);
        if (it == null) continue;
        final had = out[it.key];
        final here = ((row['files'] as num?)?.toInt() ?? 0) > 0;
        out[it.key] = had == null
            ? SharedItem(it, here: here, peers: names, listedBytes: here ? mine : theirs)
            : had.and(peers: names, listedBytes: here ? mine : theirs);
      }
    }
    return out.values.toList();
  }

  /// Whether [it] of [k] is shared: never while the kind is off; a private item only once switched on; any other item unless
  /// switched off.
  bool itemOn(DataKind k, ShareItem it) {
    if (!kindOn(k)) return false;
    if (it.private) return it.on ?? false;
    return !(_off[k.id]?.contains(it.key) ?? false);
  }

  /// Switches one item on or off. Switching one on in a kind that is off shares the kind with that item alone.
  Future<void> setItem(DataKind k, ShareItem it, bool on) async {
    if (on && !kindOn(k)) {
      _off[k.id] = {for (final x in itemsOf(k)) if (!x.item.private && x.item.key != it.key) x.item.key};
      await _save();
      if (it.private) await k.setPrivate?.call(it, true);
      await _addKind(k);
      return;
    }
    if (it.private) {
      await k.setPrivate?.call(it, on);
    } else {
      final off = _off.putIfAbsent(k.id, () => <String>{});
      on ? off.remove(it.key) : off.add(it.key);
      await _save();
    }
    await _applyOff();
    notifyListeners();
  }

  /// The paths switched off in the share [id] of [k], as the engine's patterns: the items switched off, and the private items
  /// not switched on.
  List<String> _offOf(DataKind k, String id) {
    final out = <String>{
      for (final key in _off[k.id] ?? const <String>{})
        if (key.startsWith('$id/')) ...[key.substring(id.length + 1), ...?k.alongside?.call(id, key.substring(id.length + 1))],
      for (final it in k.items?.call() ?? const <ShareItem>[])
        if (it.share == id && it.private && it.on != true) it.path,
    };
    return out.toList()..sort();
  }

  /// The off lists last given to the engine, by share id.
  final Map<String, List<String>> _sentOff = {};

  /// Gives the engine each share's items switched off, where that changed.
  Future<void> _applyOff() async {
    final c = _core;
    if (c == null) return;
    for (final k in shareKinds) {
      for (final id in k.shared().keys) {
        final off = _offOf(k, id);
        if (_sentOff[id] != null && listEquals(_sentOff[id], off)) continue;
        try {
          await c.call('set_off', {'id': id, 'off': off});
          _sentOff[id] = off;
        } catch (e) {
          logError('Sync: could not set the items switched off', error: e, detail: id);
        }
      }
    }
  }

  /// Called with the ids of the shared folders whose files a sync added, changed or removed, once the folder has nothing more to
  /// fetch (a library is never read half-way through). The app reads those folders again (Library's list, for one), so what a
  /// sync brought shows at once instead of after a restart.
  void Function(Set<String> shareIds)? onShareChanged;

  /// Each shared folder's files and bytes as last seen with nothing pending: what a change is measured against.
  final Map<String, (int, int)> _settled = {};

  void _noteShareChanges() {
    final changed = <String>{};
    for (final sh in shares) {
      final id = sh['id'];
      if (id is! String) continue;
      final now = (((sh['files'] as num?) ?? 0).toInt(), ((sh['bytes'] as num?) ?? 0).toInt());
      final before = _settled[id];
      // The first look only notes where the folder stands (what it held at start the app has read already), even mid-sync, so
      // what that sync brings is still a change when it settles.
      if (before == null) {
        _settled[id] = now;
        continue;
      }
      if (((sh['pending_files'] as num?) ?? 0) > 0) continue;
      _settled[id] = now;
      if (before != now) changed.add(id);
    }
    if (changed.isNotEmpty) onShareChanged?.call(changed);
  }

  Future<Map<String, dynamic>> _call(String m, [Map<String, Object?> a = const {}]) async {
    final c = _core;
    if (c == null) throw const CacheSearchException('sync', 'Sharing is not set up');
    final r = await c.call(m, a);
    await refresh();
    return r;
  }

  String get name => (status['name'] as String?) ?? deviceName;

  List<Map<String, dynamic>> get peers => [for (final p in (status['peers'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
  List<Map<String, dynamic>> get shares => [for (final p in (status['shares'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
  List<Map<String, dynamic>> get offers => [for (final p in (status['offers'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
  Map<String, dynamic>? get transfer => (status['transfer'] as Map?)?.cast<String, dynamic>();
  String? get paused => status['paused'] as String?;

  Map<String, dynamic>? shareOf(String id) => shares.where((s) => s['id'] == id).firstOrNull;
  Map<String, dynamic>? peerOf(String id) => peers.where((p) => p['id'] == id).firstOrNull;
  List<Map<String, dynamic>> offersOf(String id) => offers.where((o) => o['id'] == id).toList();

  /// The shares of [k]'s folders that are set up.
  List<Map<String, dynamic>> sharesOfKind(DataKind k) => [for (final id in k.shared().keys) ?shareOf(id)];

  /// What linked devices offer for [k]'s folders.
  List<Map<String, dynamic>> offersOfKind(DataKind k) => [for (final id in k.shared().keys) ...offersOf(id)];

  Future<String> linkCode() async => (await _call('link_code'))['code'] as String;

  /// Links with the device that showed [code]: its key and its name.
  Future<({String peer, String name})> link(String code) async {
    final r = await _call('link', {'code': code});
    return (peer: r['peer'] as String? ?? '', name: r['name'] as String? ?? 'the other device');
  }

  Future<void> unlink(String peer) => _call('unlink', {'peer': peer});
  Future<void> rename(String name) => _call('set_name', {'name': name});

  /// What this device calls the linked device [peer].
  Future<void> renamePeer(String peer, String name) => _call('set_peer_name', {'peer': peer, 'name': name});

  /// Sync now: everything ("Sync all now").
  Future<void> syncNow() => _call('sync_now');

  /// Sync now for one kind ("Sync all" on its page): its shared folders only.
  Future<void> syncKind(DataKind k) async {
    final ids = [for (final id in k.shared().keys) if (shareOf(id) != null) id];
    if (ids.isEmpty) return;
    await _call('sync_now', {'shares': ids});
  }

  /// Sync now for one item: its paths in its shared folder only.
  Future<void> syncItem(ShareItem it) => _call('sync_now', {
    'share': it.share,
    'paths': [it.path, for (final k in kinds) ...?k.alongside?.call(it.share, it.path)],
  });

  /// Sync now with one linked device only.
  Future<void> syncPeer(String peer) => _call('sync_now', {'peer': peer});

  /// Switches one kind on or off: every folder of it. Switching it on shares every item (a private one stays as it is); off
  /// stops sharing it, and the files stay.
  Future<void> setShared(DataKind k, bool on) async {
    final folders = k.shared();
    if (!on) {
      for (final id in folders.keys) {
        if (shareOf(id) != null) await _call('share_remove', {'id': id});
      }
      notifyListeners();
      return;
    }
    if (folders.values.any((d) => d == null)) throw CacheSearchException('sync', '${k.label} is not ready yet');
    if (_off.remove(k.id) != null) await _save();
    await _addKind(k);
  }

  /// Shares [k]'s folders, its items switched off given to the engine first (so the first round already leaves them out).
  Future<void> _addKind(DataKind k) async {
    final folders = k.shared();
    if (folders.values.any((d) => d == null)) throw CacheSearchException('sync', '${k.label} is not ready yet');
    await _applyOff();
    for (final e in folders.entries) {
      if (shareOf(e.key) != null) continue;
      await e.value!.create(recursive: true);
      await _call('share_add', {'id': e.key, 'name': folders.length == 1 ? k.label : '${k.label} (${e.key})', 'path': e.value!.path});
    }
    await refreshItems();
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _net?.cancel();
    if (_core != null) policy.settings.removeListener(_onSettings);
    _core?.close();
    super.dispose();
  }
}

/// A folder linked devices keep the same whatever the person ticks, and its sync rules (the sync engine's patterns, see
/// cache_sync's Config): [exclude] never travels, a delete under [localDeletes] stays on the device that made it, a file under
/// [last] comes after the rest of what arrives with it. What it fetches is set with [SharingState.setOnly].
class AlwaysShared {
  const AlwaysShared({
    required this.id,
    required this.name,
    required this.dir,
    this.exclude = const [],
    this.localDeletes = const [],
    this.last = const [],
    this.hidden = const [],
  });

  final String id;
  final String name;
  final Directory? Function() dir;
  final List<String> exclude;
  final List<String> localDeletes;
  final List<String> last;

  /// Hidden files that do travel (a name starting with "." otherwise never does).
  final List<String> hidden;
}

/// A folder kept only with the linked devices whose link is one of [modes] (`match`, `send`; the engine makes a new link `off`
/// until the person answers, and gave the links made before that `match` once), and never listed under Sharing and sync:
/// the person's Bookshelves log with their own devices (Match), the settings log with the devices settings go to or come from.
class LinkShare {
  const LinkShare({required this.id, required this.name, required this.dir, required this.modes});

  final String id;
  final String name;
  final Directory? Function() dir;
  final List<String> modes;
}

/// One item as the Sharing screens list it: the item, whether this device holds it, and the linked devices that do.
class SharedItem {
  const SharedItem(this.item, {required this.here, this.peers = const [], this.listedBytes});

  final ShareItem item;
  final bool here;
  final List<String> peers;

  /// Its size as the engine lists it (here, or else on a linked device).
  final int? listedBytes;

  /// Its size here as the app knows it, else as listed (for an item only a linked device holds, every file of it added up).
  int get bytes => (here ? (item.bytes ?? listedBytes) : (listedBytes ?? item.bytes)) ?? 0;

  /// The same item listed again (a map layer's database and its -wal): their sizes add up, and their devices.
  SharedItem and({required List<String> peers, int? listedBytes}) => SharedItem(
    item,
    here: here,
    peers: {...this.peers, ...peers}.toList(),
    listedBytes: this.listedBytes == null && listedBytes == null ? null : (this.listedBytes ?? 0) + (listedBytes ?? 0),
  );
}

/// What the state needs from the engine (the real one is [SyncCore]; tests give a fake).
abstract class SyncCoreLike {
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args]);
  Future<void> close();
}

typedef SyncOpener = Future<SyncCoreLike> Function(Map<String, Object?> config);

Future<SyncCoreLike> _openReal(Map<String, Object?> config) async => _RealCore(await SyncCore.open(config));

class _RealCore implements SyncCoreLike {
  _RealCore(this._c);

  final SyncCore _c;

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) => _c.call(method, args);

  @override
  Future<void> close() => _c.close();
}
