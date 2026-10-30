import 'package:package_info_plus/package_info_plus.dart';

/// The app's version (kept equal to pubspec.yaml's by a test) and its licence, shown in Settings > Credits and licences.
const String kAppVersion = '1.0.0';
const String kAppLicenceId = 'AGPL-3.0-or-later';
const String kAppLicenceShort = 'AGPL-3.0';

/// The installed app's version and build, read from the phone ("1.0.0 (build 4)"); [kAppVersion] when it cannot be read.
Future<String> installedVersion() async {
  try {
    final i = await PackageInfo.fromPlatform();
    if (i.version.isEmpty) return kAppVersion;
    return i.buildNumber.isEmpty ? i.version : '${i.version} (build ${i.buildNumber})';
  } catch (_) {
    return kAppVersion;
  }
}
