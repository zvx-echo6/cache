import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../platform/app_log.dart';

/// The device-only half of the install marker: somewhere that never travels in a phone backup or a phone-to-phone transfer.
/// Android: a file in the app's no-backup folder. iPhone: a Keychain item readable only on this device
/// (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly). Both are answered natively on the `co.cache/install_marker` channel.
abstract class InstallMarkerStore {
  /// The install id kept on this device only, or null when there is none.
  Future<String?> read();

  /// Keeps [id] on this device only.
  Future<void> write(String id);

  /// iPhone: sets NSURLIsExcludedFromBackupKey on [path] (made first if needed). Android does nothing here (its backup rules
  /// are in the manifest).
  Future<void> excludeFromBackup(String path);
}

class ChannelInstallMarkerStore implements InstallMarkerStore {
  const ChannelInstallMarkerStore({this.channel = const MethodChannel('co.cache/install_marker')});

  final MethodChannel channel;

  @override
  Future<String?> read() async => await channel.invokeMethod<String>('read');

  @override
  Future<void> write(String id) => channel.invokeMethod<void>('write', {'id': id});

  @override
  Future<void> excludeFromBackup(String path) => channel.invokeMethod<void>('excludeFromBackup', {'path': path});
}

/// What [checkInstallMarker] found.
enum MarkerState {
  /// The folder's id and the device's are the same: nothing to do.
  normal,

  /// No id in the folder: both were written (an existing phone on its first start of this build, a first set-up, or a restore
  /// from a backup made before the marker existed, which the phone alone cannot tell apart).
  written,

  /// The folder's id is not this device's: the folder is a copy that came in a backup or transfer. It was moved aside (never
  /// deleted) and a new folder, with a new id, took its place.
  restored,
}

class MarkerResult {
  const MarkerResult(this.state, {this.movedTo});
  final MarkerState state;

  /// Where the old folder went when [state] is [MarkerState.restored].
  final String? movedTo;
}

/// The id kept inside the sync folder, next to the device's key.
const String kInstallIdFile = 'install-id';

/// Beside the sync folder: where a restored copy is moved to, one folder per move, named by its UTC time.
const String kRestoredDir = 'sync-restored';

/// iPhone's backup-exclusion flag; a flag that cannot be set is logged and stops nothing.
Future<void> _keepOutOfBackups(InstallMarkerStore store, String path) async {
  try {
    await store.excludeFromBackup(path);
  } catch (e) {
    logError('Sharing: a sync folder could not be kept out of phone backups', error: e, detail: path);
  }
}

String _newId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String _stamp(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
}

/// Run at every start of sharing on a phone, before the sync engine opens [syncDir]. Compares the install id inside the folder
/// with the one only this device keeps:
/// - both there and equal: nothing;
/// - the folder has an id and the device's is missing or different: the folder came from another phone (a restore). It is moved
///   aside as `sync-restored/<UTC time>` (never deleted), a new folder with a new id is made, and the engine then makes a new key
///   in it. The old key is never opened;
/// - no id in the folder: nothing is moved, and both are written (the device's first if it had none, so a stop in between leaves
///   a state this check treats as a first start, never as a restore).
/// A folder that cannot be moved throws, so the engine is not opened on it.
Future<MarkerResult> checkInstallMarker({
  required Directory syncDir,
  required InstallMarkerStore store,
  DateTime Function() now = DateTime.now,
  String Function() makeId = _newId,
}) async {
  String? clean(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  final idFile = File('${syncDir.path}${Platform.pathSeparator}$kInstallIdFile');
  final mark = clean(await store.read());
  final inFolder = idFile.existsSync() ? clean(idFile.readAsStringSync()) : null;

  if (inFolder != null && inFolder == mark) return const MarkerResult(MarkerState.normal);

  if (inFolder != null) {
    // Under one fixed folder that is kept out of backups like the sync folder, so the old key does not travel again.
    final parent = Directory('${syncDir.parent.path}${Platform.pathSeparator}$kRestoredDir')..createSync(recursive: true);
    await _keepOutOfBackups(store, parent.path);
    final aside = '${parent.path}${Platform.pathSeparator}${_stamp(now())}';
    syncDir.renameSync(aside);
    final id = makeId();
    await store.write(id);
    syncDir.createSync(recursive: true);
    idFile.writeAsStringSync(id, flush: true);
    return MarkerResult(MarkerState.restored, movedTo: aside);
  }

  final id = mark ?? makeId();
  if (mark == null) await store.write(id);
  syncDir.createSync(recursive: true);
  idFile.writeAsStringSync(id, flush: true);
  return const MarkerResult(MarkerState.written);
}

/// The whole start-up step for [syncDir]: the check above, then (iPhone) the folder's backup-exclusion flag, set at every start
/// because iOS can drop it when the folder is recreated. A flag that cannot be set is logged and does not stop sharing: the
/// marker still catches a restored copy.
Future<MarkerResult> prepareSyncFolder({required Directory syncDir, required InstallMarkerStore store}) async {
  final result = await checkInstallMarker(syncDir: syncDir, store: store);
  await _keepOutOfBackups(store, syncDir.path);
  final restored = Directory('${syncDir.parent.path}${Platform.pathSeparator}$kRestoredDir');
  if (restored.existsSync()) await _keepOutOfBackups(store, restored.path);
  return result;
}
