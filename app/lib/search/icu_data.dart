import 'dart:io';

import 'core_config.dart';
import 'icu_setenv.dart';
import '../platform.dart' as plat;

/// The ICU data file libzim needs (the ICU inside libzim.so has no data of its own).
const String kIcuDataFile = 'icudt73l.dat';

/// How the build ships it: the plugin's Gradle task puts the file in the app's native library folder as this name (a data file
/// that only looks like a library, so that Android unpacks it to a real file on disk).
const String kIcuDataLibraryName = 'libcache_icu_data.so';

typedef SetEnv = void Function(String name, String value);

/// Makes the ICU data a plain file in app storage (`<supportDir>/icu/icudt73l.dat`, copied again only when it is missing or a
/// different size) and sets `ICU_DATA` to that folder in this process, which libzim reads when it first works. Call it before the
/// first cs_open. Returns the folder, or null when this build has no ICU data (no libzim in it) or this is not Android.
Future<String?> installIcuData({required Directory supportDir, String? libDir, SetEnv? setEnv}) async {
  final dir = libDir ?? (plat.isAndroid ? nativeLibraryDir() : null);
  if (dir == null) return null;
  final src = File('$dir/$kIcuDataLibraryName');
  if (!src.existsSync()) return null;
  final folder = Directory('${supportDir.path}/icu');
  await folder.create(recursive: true);
  final dest = File('${folder.path}/$kIcuDataFile');
  if (!dest.existsSync() || dest.lengthSync() != src.lengthSync()) {
    final tmp = File('${dest.path}.part');
    await src.copy(tmp.path);
    await tmp.rename(dest.path);
  }
  (setEnv ?? libcSetenv)('ICU_DATA', folder.path);
  return folder.path;
}
