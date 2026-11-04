import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../files.dart';
import '../settings/data_kinds.dart';
import '../settings/data_policy.dart';
import '../platform/app_log.dart';

/// The sync engine as the Sharing screen sees it: set up or not, its status (polled while anything watches), and the actions.
/// Sharing starts only once the person sets it up; until then nothing is published or listened for.
class SharingState extends ChangeNotifier {
  SharingState({
    required this.policy,
    required this.supportDir,
    required this.kinds,
    this.always = const [],
    this.deviceName = 'Cache device',
    SyncOpener? opener,
  }) : _opener = opener ?? _openReal;

  /// Folders linked devices keep the same whatever the person ticks (the search indexes), once sharing is set up.
  final List<AlwaysShared> always;

  final DataPolicy policy;
  final Future<Directory> Function() supportDir;
  /// The kinds that can be shared (the app's one list of kinds and folders, which Storage measures too). Each folder has a fixed share
  /// id, so the same kind of thing on two linked devices is one shared folder (tick Models on both and their models are kept the same).
  final List<DataKind> kinds;
  final String deviceName;
  final SyncOpener _opener;

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

  /// Starts sharing if it was set up before.
  Future<void> init() async {
    try {
      final f = await _flag();
      if (await f.exists() && (jsonDecode(await f.readAsString()) as Map)['enabled'] == true) {
        _enabled = true;
        await _start();
      }
    } catch (e) {
      error = 'Sharing could not start: $e';
      notifyListeners();
    }
  }

  /// The first time: creates this device's identity and starts sharing.
  Future<void> setUp() async {
    _enabled = true;
    final f = await _flag();
    await f.parent.create(recursive: true);
    await writeStringAtomic(f, jsonEncode({'enabled': true}));
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
        'exclude': {for (final k in kinds) ...k.notShared, for (final a in always) a.id: a.exclude},
        'local_deletes': {for (final a in always) a.id: a.localDeletes},
        'last': {for (final a in always) a.id: a.last},
        'hidden': {for (final a in always) a.id: a.hidden},
        // An always-shared folder fetches nothing until the app says what it may fetch (setOnly).
        'only': {for (final a in always) a.id: _only[a.id] ?? const <String>[]},
        'never_fetch': {for (final e in _neverFetch.entries) e.key: e.value},
      });
      await _applyPolicy();
      await refresh();
      await _addAlways();
      _net = policy.probe.changes.listen((_) async {
        try {
          await _core?.call('network_changed');
          await _applyPolicy();
        } catch (_) {}
      });
      // Switching mobile data for downloads on or off applies at once, mid-transfer too.
      policy.settings.addListener(_onSettings);
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
      await refresh();
    } catch (e) {
      error = 'Sharing could not start: ${e is CacheSearchException ? e.message : e}';
    } finally {
      _starting = false;
      notifyListeners();
    }
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
      final before = status;
      status = await c.call('status');
      logSyncEvents(before, status);
      _noteShareChanges();
      notifyListeners();
    } catch (_) {}
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
  List<Map<String, dynamic>> offersOf(String id) => offers.where((o) => o['id'] == id).toList();

  /// The shares of [k]'s folders that are set up.
  List<Map<String, dynamic>> sharesOfKind(DataKind k) => [for (final id in k.shared().keys) ?shareOf(id)];

  /// What linked devices offer for [k]'s folders.
  List<Map<String, dynamic>> offersOfKind(DataKind k) => [for (final id in k.shared().keys) ...offersOf(id)];

  Future<String> linkCode() async => (await _call('link_code'))['code'] as String;
  Future<String> link(String code) async => (await _call('link', {'code': code}))['name'] as String? ?? 'the other device';
  Future<void> unlink(String peer) => _call('unlink', {'peer': peer});
  Future<void> rename(String name) => _call('set_name', {'name': name});
  Future<void> syncNow() => _call('sync_now');

  /// Ticks or unticks one kind: every folder of it. Unticking stops sharing it; the files stay.
  Future<void> setShared(DataKind k, bool on) async {
    final folders = k.shared();
    if (!on) {
      for (final id in folders.keys) {
        if (shareOf(id) != null) await _call('share_remove', {'id': id});
      }
      return;
    }
    if (folders.values.any((d) => d == null)) throw CacheSearchException('sync', '${k.label} is not ready yet');
    for (final e in folders.entries) {
      await e.value!.create(recursive: true);
      await _call('share_add', {'id': e.key, 'name': folders.length == 1 ? k.label : '${k.label} (${e.key})', 'path': e.value!.path});
    }
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

/// A device id as the log names it: its first 8 characters.
String shortDeviceId(Object? id) {
  final s = '${id ?? ''}';
  return s.length <= 8 ? s : s.substring(0, 8);
}

/// Writes what changed in sync between two status reads (Standard): a linked device connected (directly or through a relay)
/// or became unreachable, and files received into or sent from a shared folder. Devices by short id; their names only from
/// Detailed.
void logSyncEvents(Map<String, dynamic> before, Map<String, dynamic> now) {
  Map<String, Map> byId(Object? list) => {
        for (final p in (list as List?) ?? const [])
          if (p is Map && p['id'] != null) '${p['id']}': p,
      };
  final was = byId(before['peers']), is_ = byId(now['peers']);
  for (final e in is_.entries) {
    final p = e.value, old = was[e.key];
    final up = p['error'] == null && p['last_seen'] != null;
    final upBefore = old != null && old['error'] == null && old['last_seen'] != null;
    final who = 'device ${shortDeviceId(e.key)}';
    if (up && !upBefore) {
      logInfo('Sync: $who connected ${p['via'] == 'relay' ? 'through a relay' : 'directly'}', detail: '${p['name'] ?? ''}');
    } else if (!up && upBefore) {
      logInfo('Sync: $who not reachable', detail: '${p['error'] ?? ''}');
    }
  }
  for (final k in was.keys) {
    if (!is_.containsKey(k)) logInfo('Sync: device ${shortDeviceId(k)} unlinked');
  }
  final sharesBefore = byId(before['shares']);
  for (final e in byId(now['shares']).entries) {
    final sh = e.value, old = sharesBefore[e.key];
    if (old == null) continue;
    final files = ((sh['files'] as num?) ?? 0).toInt() - ((old['files'] as num?) ?? 0).toInt();
    final bytes = ((sh['bytes'] as num?) ?? 0).toInt() - ((old['bytes'] as num?) ?? 0).toInt();
    if (files != 0 || bytes != 0) logInfo('Sync: folder ${e.key}: ${files >= 0 ? '+' : ''}$files files, ${bytes >= 0 ? '+' : ''}${bytes >> 10} KB');
  }
  final t = now['transfer'], tb = before['transfer'];
  if (t is Map && tb is! Map) logInfo('Sync: a transfer starts${t['peer'] == null ? '' : ' with device ${shortDeviceId(t['peer'])}'}');
  if (t is! Map && tb is Map) logInfo('Sync: the transfer ends');
}
