import 'package:package_info_plus/package_info_plus.dart';

/// The app's version (kept equal to pubspec.yaml's by a test) and its licence, shown in Settings > Credits and licences.
const String kAppVersion = '1.1.0';
const String kAppLicenceId = 'AGPL-3.0-or-later';
const String kAppLicenceShort = 'AGPL-3.0';

/// The build number (the number after `+` in pubspec.yaml's version, kept equal by a test), the same on both phones. It is its own counter, not the version's
/// last number: every upload to Play or TestFlight needs a higher one, so a test build and the release of a version differ. The
/// update check compares it; it is not shown.
const int kAppBuild = 48;

/// The installed app's version, read from the phone ("1.0.30"); [kAppVersion] when it cannot be read.
Future<String> installedVersion() async {
  try {
    final i = await PackageInfo.fromPlatform();
    return versionLabel(i.version, i.buildNumber);
  } catch (_) {
    return kAppVersion;
  }
}

/// The version as shown: "1.0.30". The build number is not part of it (a test build and the release of 1.0.30 both show 1.0.30).
String versionLabel(String version, String build) => version.isEmpty ? kAppVersion : version;
