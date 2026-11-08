import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../sharing/sharing_state.dart';
import 'library_log.dart';

/// The file beside the settings that keeps this install's own library-log id, used while sharing is not set up.
const String kLibraryDeviceIdFile = 'library-device-id';

/// The device id this device writes its library log as (LIBRARY-LOG.md "The device id"): sync's identity (its EndpointId text)
/// once sharing is set up; before that, an id of this install's own (`local-` and 16 hex digits, kept beside the settings), so
/// two devices that were never linked never write one file. A new id simply starts a new log file; the old one's events still
/// count.
Future<String?> libraryDeviceId({SharingState? sharing, Future<Directory> Function()? supportDir}) async {
  final id = sharing != null && sharing.running ? sharing.status['id'] : null;
  if (id is String && validDeviceId(id)) return id;
  try {
    final dir = await (supportDir ?? getApplicationSupportDirectory)();
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
