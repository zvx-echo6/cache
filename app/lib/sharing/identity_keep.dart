import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../platform/app_log.dart';

/// The second copy of this phone's sync identity (the engine's `identity.key`, cache_sync identity.rs), kept where the install
/// marker's device half is (install_marker.dart): somewhere that never travels in a phone backup or a phone-to-phone transfer, and
/// stored together with this device's install id. Android: a file in the app's no-backup folder. iPhone: a Keychain item readable
/// only on this device (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly). Both are answered natively on the install marker's
/// channel (`readIdentity`, `writeIdentity`).
///
/// The value is one text, [encodeKept]: `{"install_id": ..., "key": <the 32 key bytes, base64>}`, so the key and the id it belongs
/// to are always written together.
abstract class IdentityKeepStore {
  /// The kept text, or null when there is none. Throws when the store cannot be read (then nothing may be decided from it).
  Future<String?> read();

  /// Keeps [value] on this device only.
  Future<void> write(String value);
}

class ChannelIdentityKeepStore implements IdentityKeepStore {
  const ChannelIdentityKeepStore({this.channel = const MethodChannel('co.cache/install_marker')});

  final MethodChannel channel;

  @override
  Future<String?> read() async => await channel.invokeMethod<String>('readIdentity');

  @override
  Future<void> write(String value) => channel.invokeMethod<void>('writeIdentity', {'value': value});
}

/// What [keepIdentity] found.
enum KeepState {
  /// The key in the folder reads fine and the copy already holds it with this install id.
  kept,

  /// The key in the folder reads fine; the copy was missing or different and was written (or tried: a store that cannot be
  /// written is logged and tried again at the next start).
  written,

  /// The key in the folder was missing or the wrong length, and was written back from the copy (same install id): the same device.
  restored,

  /// The key in the folder is missing or the wrong length and there is no usable copy for this install id: every copy is gone, so
  /// the engine may make a new key (the next call keeps it).
  missing,

  /// The key in the folder is missing or the wrong length and the copy could not be checked (the store could not be read, or no
  /// install id is known): no new key may be made now. The engine is opened with `make_identity: false`, fails, and the next start
  /// tries again.
  unknown,

  /// The key in the folder is there but cannot be read: nothing is touched, and the engine fails with "Can't read this device's
  /// identity" (cache_sync never replaces such a key).
  unreadable,
}

/// The engine's key file in the sync folder.
const String kKeyFile = 'identity.key';

String encodeKept(String installId, List<int> key) => jsonEncode({'install_id': installId, 'key': base64Encode(key)});

/// The kept copy as (install id, 32 key bytes), or null when the text is not one.
(String, List<int>)? _decode(String? text) {
  if (text == null) return null;
  try {
    final j = jsonDecode(text);
    if (j is! Map) return null;
    final id = j['install_id'], key = j['key'];
    if (id is! String || id.isEmpty || key is! String) return null;
    final b = base64Decode(key);
    return b.length == 32 ? (id, b) : null;
  } catch (_) {
    return null;
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Run at every start of sharing on a phone, after the install marker check ([prepareSyncFolder]) and before the engine opens
/// [syncDir], and again after it opened (so a key the engine has just made is kept). [installId] is this device's install marker
/// (the store's id). See [KeepState] for each outcome. The restore-from-backup rule is the marker's: a folder from another phone
/// was moved aside and the marker given a new id, so a copy (which never travels, and holds the id it was written with) never
/// brings another phone's identity back.
Future<KeepState> keepIdentity({required Directory syncDir, required String? installId, required IdentityKeepStore store}) async {
  final keyFile = File('${syncDir.path}${Platform.pathSeparator}$kKeyFile');
  List<int>? main;
  try {
    final b = keyFile.readAsBytesSync();
    if (b.length == 32) main = b;
  } on PathNotFoundException {
    main = null;
  } on FileSystemException catch (e) {
    logError("Sharing: this device's identity is there but cannot be read; it is left as it is", error: e);
    return KeepState.unreadable;
  }

  if (main != null) {
    if (installId == null) return KeepState.kept;
    (String, List<int>)? kept;
    try {
      kept = _decode(await store.read());
    } catch (e) {
      kept = null; // written again below: the key in the folder wins
    }
    if (kept != null && kept.$1 == installId && _same(kept.$2, main)) return KeepState.kept;
    try {
      await store.write(encodeKept(installId, main));
    } catch (e) {
      logError("Sharing: the second copy of this device's identity could not be written; tried again at the next start", error: e);
    }
    return KeepState.written;
  }

  if (installId == null) return KeepState.unknown;
  final String? text;
  try {
    text = await store.read();
  } catch (e) {
    logError("Sharing: the second copy of this device's identity could not be read; no new identity is made", error: e);
    return KeepState.unknown;
  }
  final kept = _decode(text);
  if (kept == null || kept.$1 != installId) return KeepState.missing;
  syncDir.createSync(recursive: true);
  final tmp = File('${syncDir.path}${Platform.pathSeparator}identity.tmp');
  tmp.writeAsBytesSync(kept.$2, flush: true);
  tmp.renameSync(keyFile.path);
  return KeepState.restored;
}
