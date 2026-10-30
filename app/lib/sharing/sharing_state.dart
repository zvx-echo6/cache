import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';

import '../files.dart';
import '../settings/data_kinds.dart';
import '../settings/data_policy.dart';

/// The sync engine as the Sharing screen sees it: set up or not, its status (polled while anything watches), and the actions.
/// Sharing starts only once the person sets it up; until then nothing is published or listened for.
class SharingState extends ChangeNotifier {
  SharingState({required this.policy, required this.supportDir, required this.kinds, this.deviceName = 'Cache device', SyncOpener? opener})
    : _opener = opener ?? _openReal;

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
      _core = await _opener({'dir': dir.path, 'name': deviceName});
      await _applyPolicy();
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
      notifyListeners();
    } catch (_) {}
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
