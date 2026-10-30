import 'package:package_info_plus/package_info_plus.dart';

/// The app's version (kept equal to pubspec.yaml's by a test) and its licence, shown in Settings > Credits and licences.
const String kAppVersion = '1.0.27';
const String kAppLicenceId = 'AGPL-3.0-or-later';
const String kAppLicenceShort = 'AGPL-3.0';

/// The installed app's version, read from the phone ("1.0.27"); [kAppVersion] when it cannot be read.
Future<String> installedVersion() async {
  try {
    final i = await PackageInfo.fromPlatform();
    return versionLabel(i.version, i.buildNumber);
  } catch (_) {
    return kAppVersion;
  }
}

/// The version as shown: the version is `1.0.<build>` on both phones, so "1.0.27" already says the build; a build that is not the
/// version's last number (an older build, a test build) is added: "1.0.0 (build 26)".
String versionLabel(String version, String build) {
  if (version.isEmpty) return kAppVersion;
  if (build.isEmpty || version.split('.').last == build) return version;
  return '$version (build $build)';
}
