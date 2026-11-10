import '../update/app_update.dart';
import '../update/update_ui.dart';

/// Where the update check reads, when a test or a render sets it (so no request leaves the machine); null reads the release file on
/// cached.info.
AppUpdateSource? debugLinuxUpdateSource;

/// The update check for Cache on Linux: the same release file as the phones (the build the file names for `linux`, else its top-level
/// build), with the banner on Home saying "New version available: update the server" and "How to update" explaining that the update is a
/// new tarball and install.sh on the computer that runs Cache.
AppUpdates linuxAppUpdates({required Future<void> Function(String url) openUrl}) => AppUpdates(
  source: debugLinuxUpdateSource ?? ReleaseFileSource(installedBuild: installedBuild, platform: 'linux'),
  openUrl: openUrl,
  android: false,
  linux: true,
  dismissed: DismissedUpdate(),
);
