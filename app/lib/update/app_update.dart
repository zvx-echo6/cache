import 'dart:convert';
import 'dart:io';

import '../net/fetch.dart';
import '../search/core_config.dart' show kDataBaseUrl;

/// Where Cache's newest release is described: a small file on cached.info that the release workflow writes. The iPhone's
/// "New version available: open TestFlight" banner reads it (TestFlight's own auto-update stays the main path); Android reads
/// it too until Google Play's in-app updates are wired (see [AppUpdateSource]).
final String kAppReleaseUrl = '$kDataBaseUrl/app/latest.json';

/// The format of [kAppReleaseUrl] this build reads.
const int kAppReleaseFormat = 1;

/// A newer Cache than the one installed, and where to get it on this phone.
class AppUpdate {
  const AppUpdate({required this.version, required this.build, this.notes, this.link, this.published});

  /// "1.0.30" and 30.
  final String version;
  final int build;

  /// The release's short notes, as the release file has them.
  final String? notes;

  /// Where this phone gets it: the TestFlight link on iPhone, the Play listing on Android.
  final Uri? link;

  /// "2026-11-02".
  final String? published;
}

/// Asks whether a newer Cache is out. The screens (a banner, a Settings line) drop in later and only read this.
abstract class AppUpdateSource {
  /// The newer release, or null when this is the newest (or nothing could be read: no connection is not an update).
  Future<AppUpdate?> check();
}

/// The release file on cached.info (`app/latest.json`):
///
/// ```json
/// {"format": 1, "version": "1.0.30", "build": 30, "published": "2026-11-02", "notes": "…",
///  "ios": {"build": 30, "link": "https://testflight.apple.com/join/…"},
///  "android": {"build": 30, "link": "https://play.google.com/store/apps/details?id=com.happylittlellc.cache"}}
/// ```
///
/// Each platform names the build that is out for it (a store can lag the other); a platform without its own block uses the
/// top-level build. A file in another format, or one that cannot be read, is no update.
class ReleaseFileSource implements AppUpdateSource {
  ReleaseFileSource({required this.installedBuild, String? platform, Future<String> Function(Uri url)? fetch, Uri? url})
      : platform = platform ?? (Platform.isIOS ? 'ios' : 'android'),
        _fetch = fetch ?? ((u) => fetchText(u, maxBytes: 64 * 1024, timeout: const Duration(seconds: 20))),
        url = url ?? Uri.parse(kAppReleaseUrl);

  /// The installed build number (pubspec's `+<build>`, the same on both phones).
  final int installedBuild;

  /// `ios` or `android`.
  final String platform;
  final Uri url;
  final Future<String> Function(Uri url) _fetch;

  @override
  Future<AppUpdate?> check() async {
    try {
      return parse(await _fetch(url));
    } catch (_) {
      return null;
    }
  }

  /// The update [text] (the release file) offers this phone, or null.
  AppUpdate? parse(String text) {
    final j = jsonDecode(text);
    if (j is! Map || j['format'] != kAppReleaseFormat) return null;
    final mine = j[platform] is Map ? j[platform] as Map : const {};
    final build = (mine['build'] ?? j['build']) as num?;
    final version = j['version'];
    if (build == null || version is! String || build.toInt() <= installedBuild) return null;
    final link = mine['link'];
    return AppUpdate(
      version: version,
      build: build.toInt(),
      notes: j['notes'] is String ? j['notes'] as String : null,
      link: link is String ? Uri.tryParse(link) : null,
      published: j['published'] is String ? j['published'] as String : null,
    );
  }
}
