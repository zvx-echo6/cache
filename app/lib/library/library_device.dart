import 'dart:io';
import 'dart:math';

import '../app_fs.dart';

import '../sharing/sharing_state.dart';

Future<Directory> _supportDir() async => Directory(await appSupportPath());

/// The file beside the settings that keeps this install's own Bookshelves log id, used while sharing is not set up.
const String kLibraryDeviceIdFile = 'library-device-id';

/// A device id as a log file name allows it: letters, digits, '.', '_' and '-', at most 64, not starting with a dot.
bool validDeviceId(String id) => id.isNotEmpty && id.length <= 64 && !id.startsWith('.') && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id);

/// This install's own id (kept beside the settings), when it has made one: the id its Bookshelves events were written as before
/// sharing was set up, so its old library logs are imported too. Never made here.
Future<String?> libraryLocalDeviceId({Future<Directory> Function()? supportDir}) async {
  try {
    final dir = await (supportDir ?? _supportDir)();
    final f = File('${dir.path}${Platform.pathSeparator}$kLibraryDeviceIdFile');
    if (!f.existsSync()) return null;
    final t = f.readAsStringSync().trim();
    return validDeviceId(t) ? t : null;
  } catch (_) {
    return null;
  }
}

/// The device id this device writes its Bookshelves log as (server/builder/LIBRARY-LOG.md "The device id"): sync's identity (its EndpointId text)
/// once sharing is set up; before that, an id of this install's own (`local-` and 16 hex digits, kept beside the settings), so
/// two devices that were never linked never write one file. A new id simply starts a new log file; the old one's events still
/// count.
Future<String?> libraryDeviceId({SharingState? sharing, Future<Directory> Function()? supportDir}) async {
  final id = sharing != null && sharing.running ? sharing.status['id'] : null;
  if (id is String && validDeviceId(id)) return id;
  try {
    final dir = await (supportDir ?? _supportDir)();
    final f = File('${dir.path}${Platform.pathSeparator}$kLibraryDeviceIdFile');
    if (f.existsSync()) {
      final t = f.readAsStringSync().trim();
      if (validDeviceId(t)) return t;
    }
    final r = Random.secure();
    final t = 'local-${List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    await f.parent.create(recursive: true);
    await f.writeAsString(t, flush: true);
    return t;
  } catch (_) {
    return null;
  }
}
