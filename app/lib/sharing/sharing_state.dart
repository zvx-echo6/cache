import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../background/background_lock.dart';
import '../background/sync_background.dart' show syncBackgroundDir, writeSyncConfig;
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
///
/// What drives the engine is a [SharingDriver]: on a phone or desktop the app runs the engine itself ([_PhoneDriver]); in a browser
/// Cache Server runs it and the browser asks its sharing host ([_WebDriver], given a [remote]). The read side (status, peers,
/// shares, offers, items) is the same for both.
class SharingState extends ChangeNotifier {
  SharingState({
    required this.policy,
    required this.supportDir,
    required this.kinds,
    this.always = const [],
    this.linkShares = const [],
    this.quiet = const [],
    this.deviceName = 'Cache device',
    SyncOpener? opener,
    int Function(String dir)? reserveBytes,
    bool? phone,
    void Function(String line)? log,
    Timer Function(Duration after, void Function() run)? timer,
    List<String> Function()? drainLog,
    Timer Function(Duration every, void Function() run)? every,
    CoreTransport? remote,
  }) : _log = log ?? ((l) => logInfo(l)),
       _timer = timer ?? Timer.new,
       _drainLog = drainLog ?? drainSyncLog,
       _every = every ?? ((d, run) => Timer.periodic(d, (_) => run())),
       _phone = phone ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS)),
       _reserveBytes = reserveBytes ?? _storageReserve,
       _opener = opener ?? openSyncCore,
       // ignore: prefer_initializing_formals
       _remote = remote;

  /// Folders linked devices keep the same whatever the person ticks (the search indexes), once sharing is set up.
  final List<AlwaysShared> always;

  /// Shares whose files the Activity does not list one by one (the engine's `quiet`): the notebooks, which the notebook sync tells in
  /// its own words ("3 entries arrived from your other devices"); a file line would name the person's notebook files.
  final List<String> quiet;

  /// Folders kept only with some linked devices, by how settings go between them (the device's page): never listed under
  /// Sharing and sync, set up once sharing is (see [LinkShare]).
  final List<LinkShare> linkShares;

  final DataPolicy policy;
  final Future<Directory> Function() supportDir;
  /// The kinds that can be shared (the app's one list of kinds and folders, which Storage measures too). Each folder has a fixed share
  /// id, so the same kind of thing on two linked devices is one shared folder (tick Models on both and their models are kept the same).
  final List<DataKind> kinds;

  /// Ignored in a browser: Cache Server names itself.
  final String deviceName;
  final SyncOpener _opener;

  /// Cache Server's `/api/core` in a browser (a test gives a fake): when set, the engine is the server's and this asks its sharing
  /// host. Null: the app runs the engine itself.
  final CoreTransport? _remote;

  /// A phone (Android or iOS). The Mainline DHT is off there: its socket can fail and spin a CPU, burning the battery on a drive, and
  /// linked devices are still found by mDNS, n0's lookup and the relay. Anywhere else (the server, the desktop) the engine's default (on) stands.
  final bool _phone;

  /// What Cache leaves free on the phone, for the volume holding a folder: the same rule Storage shows ([reserveFor]).
  final int Function(String dir) _reserveBytes;

  static int _storageReserve(String dir) => reserveFor(totalBytesOnDisk(dir));

  /// Where the start's timing lines go (the app's log), and how the one-shot "still starting" timer is made (tests make their own).
  final void Function(String line) _log;
  final Timer Function(Duration after, void Function() run) _timer;

  /// Takes the engine's lines about its start ([SyncCore.takeLog]), and how the 1 s drain while the start runs is made. The engine
  /// never calls into Dart; the lines are asked for.
  final List<String> Function() _drainLog;
  final Timer Function(Duration every, void Function() run) _every;
  /// How often the engine's lines are taken while a start is running (so a start that hangs leaves its last step in the log).
  static const Duration kDrainEvery = Duration(seconds: 1);

  void _drainNow() {
    try {
      for (final l in _drainLog()) {
        _log(l);
      }
    } catch (_) {}
  }

  /// How long a start may take before the log says it is still going.
  static const Duration kSlowStart = Duration(seconds: 60);

  /// Shared folders earlier versions had and this one does not: the Shared folder (1.0). Each stops being shared at start; its
  /// files stay where they are, and nothing is deleted on any device.
  static const List<String> retiredShares = ['shared'];

  late final SharingDriver _driver = _remote != null ? _WebDriver(this, _remote) : _PhoneDriver(this);

  String? error;
  Map<String, dynamic> status = const {};

  /// Whether this is Cache Server seen from a browser (the server's sharing host drives it), not a phone or a desktop.
  bool get onServer => _driver is _WebDriver;

  bool get enabled => _driver.enabled;
  bool get running => _driver.running;
  bool get starting => _driver.starting;

  void _changed() => notifyListeners();

  /// The items switched off, by kind id ([ShareItem.key]s), kept in sharing.json beside "enabled" (the server's, in a browser). A
  /// kind with none listed has every item on: what a kind ticked before items existed shares as it did.
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
  Future<void> init() => _driver.init();

  /// The first time: creates this device's identity and starts sharing.
  Future<void> setUp() => _driver.setUp();

  /// This device's key (its identity for linked devices), once sharing runs.
  String? get myId => status['id'] as String?;

  /// What this device and [peer] keep about their link (how settings go between them), as last set on either; null until set.
  Map<String, dynamic>? linkOf(String peer) => (peerOf(peer)?['link'] as Map?)?.cast<String, dynamic>();

  /// Sets what this device and [peer] keep about their link; [peer] takes it with the next sync.
  Future<void> setLink(String peer, Map<String, Object?> link) => _call('set_link', {'peer': peer, 'link': link});

  /// The keys for [peer] ({secure-storage name: key}): held by the sync engine in memory only and sent only to [peer], over its
  /// own encrypted connection, when it asks. Empty: none.
  Future<void> setSecrets(String peer, Map<String, String> secrets) => _driver.setSecrets(peer, secrets);

  /// The keys linked devices sent since the last call, by device ({device: {name: key}}), handed over once.
  Future<Map<String, Map<String, String>>> takeSecrets() => _driver.takeSecrets();

  /// What this device fetches of the always-shared folder [id] from now on: the paths [patterns] cover (the sync engine's
  /// patterns), as the sources on this device change. Kept, and given to the engine at its next start too.
  Future<void> setOnly(String id, List<String> patterns) => _driver.setOnly(id, patterns);

  /// What this device never fetches of the always-shared folder [id] (on top of [setOnly]): kept, and given to the engine at its
  /// next start too.
  Future<void> setNeverFetch(String id, List<String> patterns) => _driver.setNeverFetch(id, patterns);

  Future<void> refresh() => _driver.refresh();

  /// The kinds under "Shared with linked devices", in their order there.
  List<DataKind> get shareKinds {
    const order = ['library', 'regions', 'models', 'notebooks', 'videos'];
    final list = [for (final k in kinds) if (k.shared().isNotEmpty && _driver.showsKind(k)) k];
    int at(DataKind k) => order.contains(k.id) ? order.indexOf(k.id) : order.length + kinds.indexOf(k);
    return list..sort((a, b) => at(a).compareTo(at(b)));
  }

  /// The kind shares something here (its switch is on).
  bool kindOn(DataKind k) => sharesOfKind(k).isNotEmpty;

  /// What this device and each linked device hold of each shared folder, by share id (the engine's `share_items`), as last read.
  final Map<String, List<Map<String, dynamic>>> _listed = {};

  /// Reads again what each shared folder holds, here and on the linked devices (the items a device has not fetched yet show too).
  Future<void> refreshItems() => _driver.refreshItems();

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

  /// Whether the library folder [folder] (an own library such as My books) is synced with another device: its item in the Library
  /// kind is shared (the kind's switch is on and the item is not switched off) and at least one device is linked. Sync is fully
  /// shared both ways, so every linked device takes it.
  bool libraryTakenByAnotherDevice(String folder) {
    final k = kinds.where((k) => k.id == 'library').firstOrNull;
    if (k == null || !itemOn(k, ShareItem(share: 'libraries', path: folder, name: folder))) return false;
    return peers.isNotEmpty;
  }

  /// Switches one item on or off. Switching one on in a kind that is off shares the kind with that item alone.
  Future<void> setItem(DataKind k, ShareItem it, bool on) => _driver.setItem(k, it, on);

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

  Future<Map<String, dynamic>> _call(String m, [Map<String, Object?> a = const {}]) => _driver.call(m, a);

  String get name => (status['name'] as String?) ?? deviceName;

  final List<Map<String, dynamic>> _extraLog = [];

  /// A line this app adds to the Activity (the notebook sync's: the engine's own log has the file transfers).
  void addActivity(String text) {
    _extraLog.insert(0, {'text': text, 'at': DateTime.now().millisecondsSinceEpoch});
    if (_extraLog.length > 100) _extraLog.removeRange(100, _extraLog.length);
    notifyListeners();
  }

  /// The Activity: the engine's log and this app's own lines, newest first.
  List<Map<String, dynamic>> get activity => [
        for (final e in (status['log'] as List? ?? const [])) (e as Map).cast<String, dynamic>(),
        ..._extraLog,
      ]..sort((a, b) => ((b['at'] as int?) ?? 0).compareTo((a['at'] as int?) ?? 0));

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
  Future<({String peer, String name})> link(String code) => _driver.link(code);

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
  Future<void> setShared(DataKind k, bool on) => _driver.setShared(k, on);

  @override
  void dispose() {
    _driver.dispose();
    super.dispose();
  }
}

/// What drives the engine behind [SharingState]: it starts and stops it, keeps the state's status and share lists current, and runs
/// the actions that need more than one engine call. Two implementations: [_PhoneDriver] (the app's own engine) and [_WebDriver] (Cache
/// Server's, through its sharing host).
abstract class SharingDriver {
  bool get enabled;
  bool get running;
  bool get starting;

  /// Whether the Sharing page lists [k] under "Shared with linked devices" (the phone lists every kind).
  bool showsKind(DataKind k);

  Future<void> init();
  Future<void> setUp();
  Future<void> refresh();
  Future<void> refreshItems();

  /// One engine method, then the status read again. Throws when sharing is not set up.
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]);
  Future<({String peer, String name})> link(String code);
  Future<void> setShared(DataKind k, bool on);
  Future<void> setItem(DataKind k, ShareItem it, bool on);
  Future<void> setOnly(String id, List<String> patterns);
  Future<void> setNeverFetch(String id, List<String> patterns);
  Future<void> setSecrets(String peer, Map<String, String> secrets);
  Future<Map<String, Map<String, String>>> takeSecrets();
  void dispose();
}

/// The phone's (and the desktop's) driver: the app opens the sync engine itself, keeps `sharing.json`, and does everything the
/// engine needs on its own device.
class _PhoneDriver implements SharingDriver {
  _PhoneDriver(this.s);

  final SharingState s;

  SyncCoreLike? _core;
  bool _enabled = false;
  bool _starting = false;
  Timer? _poll;
  Timer? _slowStart;
  Timer? _drain;
  StreamSubscription<ConnectionKind>? _net;

  @override
  bool get enabled => _enabled;
  @override
  bool get running => _core != null;
  @override
  bool get starting => _starting;
  @override
  bool showsKind(DataKind k) => true;

  List<AlwaysShared> get always => s.always;
  List<LinkShare> get linkShares => s.linkShares;
  List<DataKind> get kinds => s.kinds;
  DataPolicy get policy => s.policy;
  List<DataKind> get shareKinds => s.shareKinds;
  Map<String, Set<String>> get _off => s._off;

  Future<File> _flag() async => File('${(await s.supportDir()).path}/sharing.json');

  /// Starts sharing if it was set up before.
  @override
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
      // Everything _save writes (enabled, off, ask_since) is loaded before any save, or a save would overwrite the file with defaults.
      final enabled = j['enabled'] == true;
      _enabled = enabled;
      final since = j['ask_since'];
      if (since is int) {
        s._askSince = since;
      } else {
        // The first run of this version: every link there is now was made before it.
        s._askSince = DateTime.now().millisecondsSinceEpoch;
        await _save();
      }
      if (enabled) {
        await _start();
      }
    } catch (e) {
      s.error = 'Sharing could not start: $e';
      s._changed();
    }
  }

  Future<void> _save() async {
    final f = await _flag();
    await f.parent.create(recursive: true);
    await writeStringAtomic(
      f,
      jsonEncode({
        'enabled': _enabled,
        'ask_since': ?s._askSince,
        if (_off.values.any((v) => v.isNotEmpty)) 'off': {for (final e in _off.entries) if (e.value.isNotEmpty) e.key: [...e.value]..sort()},
      }),
    );
  }

  /// The first time: creates this device's identity and starts sharing.
  @override
  Future<void> setUp() async {
    _enabled = true;
    s._askSince ??= DateTime.now().millisecondsSinceEpoch;
    await _save();
    await _start();
  }

  Future<void> _start() async {
    if (_core != null || _starting) return;
    _starting = true;
    s.error = null;
    s._changed();
    final took = Stopwatch()..start();
    s._log('Sharing: starting');
    // Only says so: a start that hangs leaves this line as the trace of where it stopped. Cancelled when the start ends.
    _slowStart = s._timer(SharingState.kSlowStart, () => s._log('Sharing: still starting after ${SharingState.kSlowStart.inSeconds} s'));
    // the engine's own lines about its start, taken (it never calls into Dart) while the start runs
    _drain = s._every(SharingState.kDrainEvery, s._drainNow);
    try {
      final dir = Directory('${(await s.supportDir()).path}/sync');
      // A background round (background/sync_background.dart) has the engine's folder while it runs: it is asked to stop, and
      // given time to close its engine, before this one opens (two engines on one folder made "Sharing could not start").
      final lock = _lock = BackgroundLock(Directory(syncBackgroundDir((await s.supportDir()).path)));
      if (lock.runs(kSyncWork)) {
        logInfo('Sync: a background round is running; asking it to stop');
        if (!await lock.takeOver(kSyncWork)) logInfo('Sync: the background round is still stopping; opening anyway');
      }
      // What each device builds for itself inside a shared folder never syncs (a library's search index).
      final config = <String, Object?>{
        'dir': dir.path,
        'name': s.deviceName,
        if (s._phone) 'dht': false,
        // The engine keeps the same space free as Storage shows, so This device and Storage agree.
        'reserve_bytes': s._reserveBytes((await s.supportDir()).path),
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
        'quiet': s.quiet,
      };
      _lastConfig = config;
      _core = await s._opener(config);
      lock.engineStarted(kSyncWork);
      await _writeSnapshot();
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
      s._log('Sharing: started in ${(took.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
    } catch (e) {
      s.error = 'Sharing could not start: ${e is CacheSearchException ? e.message : e}';
      // The kind of failure only: the text can carry paths, and this log is shared.
      s._log('Sharing: start failed after ${(took.elapsedMilliseconds / 1000).toStringAsFixed(1)} s (${e is CacheSearchException ? e.code : e.runtimeType})');
    } finally {
      _slowStart?.cancel();
      _slowStart = null;
      _drain?.cancel();
      _drain = null;
      s._drainNow();
      _starting = false;
      s._changed();
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
      final sh = s.shareOf(e.key);
      if (d == null || sh == null || sh['path'] == d.path) continue;
      try {
        await d.create(recursive: true);
        await call('share_add', {'id': e.key, 'name': sh['name'], 'path': d.path});
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
      if (d == null || s.shareOf(a.id) != null) continue;
      try {
        await d.create(recursive: true);
        await call('share_add', {'id': a.id, 'name': a.name, 'path': d.path});
      } catch (e) {
        logError('Could not share', error: e, detail: a.name);
      }
    }
  }

  /// Shares every folder of [linkShares] that is not shared yet (its folder is made if it is missing).
  Future<void> _addLinkShares() async {
    for (final l in linkShares) {
      final d = l.dir();
      if (d == null || s.shareOf(l.id) != null) continue;
      try {
        await d.create(recursive: true);
        await call('share_add', {'id': l.id, 'name': l.name, 'path': d.path});
      } catch (e) {
        logError('Could not share', error: e, detail: l.name);
      }
    }
  }

  @override
  Future<void> setSecrets(String peer, Map<String, String> secrets) async {
    final c = _core;
    if (c == null) return;
    await c.call('set_secrets', {'peer': peer, 'secrets': secrets});
  }

  @override
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

  @override
  Future<void> setOnly(String id, List<String> patterns) async {
    final sorted = [...patterns]..sort();
    final before = _only[id];
    if (before != null && listEquals(before, sorted)) return;
    _only[id] = sorted;
    final c = _core;
    if (c == null) return;
    try {
      await c.call('set_only', {'id': id, 'only': sorted});
      unawaited(_writeSnapshot());
    } catch (e) {
      logError('Sync: could not set what a device fetches', error: e, detail: _nameOf(id));
    }
  }

  final Map<String, List<String>> _neverFetch = {};

  @override
  Future<void> setNeverFetch(String id, List<String> patterns) async {
    final sorted = [...patterns]..sort();
    if (listEquals(_neverFetch[id] ?? const <String>[], sorted)) return;
    _neverFetch[id] = sorted;
    final c = _core;
    if (c == null) return;
    try {
      await c.call('set_never_fetch', {'id': id, 'never_fetch': sorted});
      unawaited(_writeSnapshot());
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

  @override
  Future<void> refresh() async {
    final c = _core;
    if (c == null) return;
    try {
      s.status = await c.call('status');
      s._noteShareChanges();
      s._changed();
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
      await _writeSnapshot();
    }
    // The mark that this app's engine runs (a background round never opens a second one), written again every 30 s.
    if (_ticks % 15 == 0) _lock?.engineStarted(kSyncWork);
  }

  BackgroundLock? _lock;
  Map<String, Object?>? _lastConfig;
  String? _snapshot;

  /// The settings the engine runs with now, kept for the background round (which opens the same engine with the app closed): the
  /// open call's settings, with what was set since (`only`, `never_fetch`, the items switched off).
  Future<void> _writeSnapshot() async {
    // One write at a time (two would share the temp file); one asked while another is under way is done after it, from the
    // state as it is then.
    if (_writingNow) {
      _writeAgain = true;
      return;
    }
    _writingNow = true;
    try {
      do {
        _writeAgain = false;
        await _writeSnapshotNow();
      } while (_writeAgain);
    } finally {
      _writingNow = false;
    }
  }

  bool _writingNow = false, _writeAgain = false;

  Future<void> _writeSnapshotNow() async {
    final c = _lastConfig;
    if (c == null) return;
    final snap = jsonEncode({
      ...c,
      'only': {for (final a in always) a.id: _only[a.id] ?? const <String>[]},
      'never_fetch': {for (final e in _neverFetch.entries) e.key: e.value},
      'off': {for (final e in _sentOff.entries) e.key: e.value},
    });
    if (snap == _snapshot) return;
    _snapshot = snap;
    await writeSyncConfig((await s.supportDir()).path, jsonDecode(snap) as Map<String, Object?>);
  }

  Future<void> _retire() async {
    for (final id in SharingState.retiredShares) {
      if (s.shareOf(id) == null) continue;
      try {
        await call('share_remove', {'id': id});
        logInfo('Sync: stopped sharing a folder this version no longer shares; its files stay', detail: id);
      } catch (e) {
        logError('Sync: could not stop sharing a retired folder', error: e, detail: id);
      }
    }
  }

  @override
  Future<void> refreshItems() async {
    final c = _core;
    if (c == null) return;
    var changed = false;
    for (final k in shareKinds) {
      for (final id in k.shared().keys) {
        try {
          final r = await c.call('share_items', {'id': id, 'depth': k.itemDepth[id] ?? 1});
          final rows = [for (final i in (r['items'] as List? ?? const [])) (i as Map).cast<String, dynamic>()];
          s._listed[id] = rows;
          changed = true;
        } catch (_) {}
      }
    }
    if (changed) s._changed();
  }

  @override
  Future<void> setItem(DataKind k, ShareItem it, bool on) async {
    if (on && !s.kindOn(k)) {
      _off[k.id] = {for (final x in s.itemsOf(k)) if (!x.item.private && x.item.key != it.key) x.item.key};
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
    s._changed();
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

  @override
  Future<Map<String, dynamic>> call(String m, [Map<String, Object?> a = const {}]) async {
    final c = _core;
    if (c == null) throw const CacheSearchException('sync', 'Sharing is not set up');
    final r = await c.call(m, a);
    await refresh();
    return r;
  }

  @override
  Future<({String peer, String name})> link(String code) async {
    final r = await call('link', {'code': code});
    return (peer: r['peer'] as String? ?? '', name: r['name'] as String? ?? 'the other device');
  }

  @override
  Future<void> setShared(DataKind k, bool on) async {
    final folders = k.shared();
    if (!on) {
      for (final id in folders.keys) {
        if (s.shareOf(id) != null) await call('share_remove', {'id': id});
      }
      s._changed();
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
      if (s.shareOf(e.key) != null) continue;
      await e.value!.create(recursive: true);
      await call('share_add', {'id': e.key, 'name': folders.length == 1 ? k.label : '${k.label} (${e.key})', 'path': e.value!.path});
    }
    await refreshItems();
    s._changed();
  }

  @override
  void dispose() {
    _slowStart?.cancel();
    _drain?.cancel();
    _poll?.cancel();
    _net?.cancel();
    if (_core != null) policy.settings.removeListener(_onSettings);
    _lock?.engineStopped(kSyncWork);
    _core?.close();
  }
}

/// The browser's driver: the engine runs on Cache Server, in its helper's sharing host, which keeps sharing set up, starts it with
/// the server and polls its status once for every tab. This reads the host's cached state every 2 s (`sharing.state`) and sends the
/// person's choices as `sharing.*` ops; nothing here opens an engine, reads a folder or keeps `sharing.json`. Only the kinds the
/// host can share fully so far are listed (Library and Models); the others come with later slices.
class _WebDriver implements SharingDriver {
  _WebDriver(this.s, this.t);

  final SharingState s;
  final CoreTransport t;

  /// The kinds listed in a browser for now.
  static const Set<String> kindIds = {'library', 'models'};

  /// How long a link may take (the engine waits for the other device) before the browser gives up waiting.
  static const Duration kLinkWait = Duration(minutes: 3);

  bool _enabled = false, _running = false, _starting = false;
  Timer? _poll;
  int _ticks = 0;
  bool _reading = false, _disposed = false;

  @override
  bool get enabled => _enabled;
  @override
  bool get running => _running;
  @override
  bool get starting => _starting;
  @override
  bool showsKind(DataKind k) => kindIds.contains(k.id);

  Future<Map<String, dynamic>> _op(String op, [Map<String, dynamic> args = const {}]) async {
    final r = await t.call(op, args);
    return r is Map ? r.cast<String, dynamic>() : const {};
  }

  /// Takes what the host says as the state: whether sharing is set up and running, the engine's status, the items switched off.
  void _apply(Map<String, dynamic> snap) {
    if (_disposed) return;
    _enabled = snap['enabled'] == true;
    _running = snap['running'] == true;
    _starting = snap['starting'] == true;
    final err = snap['error'];
    s.error = err is String && err.isNotEmpty ? err : null;
    final since = snap['ask_since'];
    s._askSince = since is int ? since : null;
    final off = snap['off'];
    s._off
      ..clear()
      ..addAll({if (off is Map) for (final o in off.entries) if (o.value is List) '${o.key}': {for (final k in o.value as List) '$k'}});
    final st = snap['status'];
    s.status = st is Map ? st.cast<String, dynamic>() : const {};
    s._noteShareChanges();
    s._changed();
  }

  Future<Map<String, dynamic>> _state() async {
    final snap = await _op('sharing.state');
    _apply(snap);
    return snap;
  }

  @override
  Future<void> init() async {
    try {
      await _state();
      if (_enabled) _startPoll();
    } catch (e) {
      s.error = 'Sharing could not start: ${e is CacheSearchException ? e.message : e}';
      s._changed();
    }
  }

  @override
  Future<void> setUp() async {
    _apply(await _op('sharing.setup'));
    _startPoll();
    await refreshItems();
  }

  void _startPoll() {
    _poll?.cancel();
    _ticks = 0;
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    unawaited(refreshItems());
  }

  /// Every 2 s the state; every 10 s what each linked device holds.
  Future<void> _tick() async {
    if (_reading) return;
    _reading = true;
    try {
      await refresh();
      if (++_ticks % 5 == 0) await refreshItems();
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> refresh() async {
    try {
      await _state();
    } catch (_) {}
  }

  @override
  Future<void> refreshItems() async {
    if (!_running) return;
    var changed = false;
    for (final k in s.shareKinds) {
      for (final id in k.shared().keys) {
        try {
          final r = await _op('sharing.call', {'method': 'share_items', 'args': {'id': id, 'depth': k.itemDepth[id] ?? 1}});
          s._listed[id] = [for (final i in (r['items'] as List? ?? const [])) (i as Map).cast<String, dynamic>()];
          changed = true;
        } catch (_) {}
      }
    }
    if (changed && !_disposed) s._changed();
  }

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async {
    if (!_running) throw const CacheSearchException('sync', 'Sharing is not set up');
    final r = await _op('sharing.call', {'method': method, 'args': args});
    await refresh();
    return r;
  }

  /// Starts the link on the server (which returns at once) and reads its progress until it is done or has failed.
  @override
  Future<({String peer, String name})> link(String code) async {
    if (!_running) throw const CacheSearchException('sync', 'Sharing is not set up');
    await _op('sharing.link_start', {'code': code});
    final waited = Stopwatch()..start();
    while (waited.elapsed < kLinkWait && !_disposed) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final l = (await _state())['link'];
      if (l is! Map) continue;
      if (l['state'] == 'done') return (peer: l['peer'] as String? ?? '', name: l['name'] as String? ?? 'the other device');
      if (l['state'] == 'failed') throw CacheSearchException('sync', l['error'] as String? ?? 'Could not link');
    }
    throw const CacheSearchException('sync', 'Could not link');
  }

  @override
  Future<void> setShared(DataKind k, bool on) async {
    _apply(await _op('sharing.set_kind', {'kind': k.id, 'on': on}));
    if (on) await refreshItems();
  }

  @override
  Future<void> setItem(DataKind k, ShareItem it, bool on) async {
    // Switching one on in a kind that is off shares the kind with that item alone, which needs every item of the kind.
    final all = on && !s.kindOn(k) ? [for (final x in s.itemsOf(k)) if (!x.item.private) x.item.key] : null;
    _apply(await _op('sharing.set_item', {'kind': k.id, 'key': it.key, 'on': on, 'all': ?all}));
    if (all != null) await refreshItems();
  }

  // What each folder fetches and the keys are the server's own work, not the browser's.
  @override
  Future<void> setOnly(String id, List<String> patterns) async {}
  @override
  Future<void> setNeverFetch(String id, List<String> patterns) async {}
  @override
  Future<void> setSecrets(String peer, Map<String, String> secrets) async {}
  @override
  Future<Map<String, Map<String, String>>> takeSecrets() async => const {};

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
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

/// The real engine ([SyncCore]) as the state and the background run use it.
Future<SyncCoreLike> openSyncCore(Map<String, Object?> config) async {
  try {
    return _RealCore(await SyncCore.open(config));
  } finally {
    // the engine's lines about this open (it never calls into Dart): this isolate's log gets them, the background run's too
    drainSyncLogToLog();
  }
}

/// The engine's lines about its start ([SyncCore.takeLog]), taken now.
List<String> drainSyncLog() => SyncCore.takeLog();

/// Takes the engine's lines about its start and writes each to the app's log.
void drainSyncLogToLog() {
  for (final l in SyncCore.takeLog()) {
    logInfo(l);
  }
}

class _RealCore implements SyncCoreLike {
  _RealCore(this._c);

  final SyncCore _c;

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) => _c.call(method, args);

  @override
  Future<void> close() => _c.close();
}
