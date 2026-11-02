import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../theme.dart';
import '../version.dart';
import 'app_update.dart';

/// The installed build: the version is `1.0.<build>` on both phones.
int get installedBuild => int.tryParse(kAppVersion.split('.').last) ?? 0;

/// The app's update check (the iPhone's; null on Android, where nothing is built yet): what Home's banner and Settings > Credits
/// and licences read.
AppUpdates? currentAppUpdates;

/// Cache's id in Google Play (android/app/build.gradle.kts).
const String kAndroidAppId = 'com.happylittlellc.cache';

/// The build whose banner was dismissed, kept next to the settings so it stays dismissed after a restart (a newer build brings it
/// back).
class DismissedUpdate {
  DismissedUpdate({Directory? dirOverride}) : _dir = dirOverride;

  final Directory? _dir;

  Future<File> _file() async => File('${(_dir ?? await getApplicationSupportDirectory()).path}/update_banner.json');

  Future<int?> read() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync());
      return j is Map && j['dismissed_build'] is num ? (j['dismissed_build'] as num).toInt() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(int build) async {
    try {
      (await _file()).writeAsStringSync(jsonEncode({'dismissed_build': build}));
    } catch (_) {}
  }
}

/// A newer Cache, for the banner on Home (iPhone: TestFlight; Android: Cache's page in the Play Store app) and its line in
/// Settings > Credits and licences. Checked once a start (no connection is not an update). A dismissed banner stays dismissed,
/// across restarts too, until a newer build is out; the line in Settings stays.
class AppUpdates extends ChangeNotifier {
  AppUpdates({required this.source, required this.openUrl, required this.android, DismissedUpdate? dismissed}) : _store = dismissed;

  final AppUpdateSource source;
  final Future<void> Function(String url) openUrl;

  /// Android (the Play Store app) rather than iPhone (TestFlight).
  final bool android;
  final DismissedUpdate? _store;

  AppUpdate? _available;
  int? _dismissedBuild;

  /// The newer release for this phone, or null.
  AppUpdate? get available => _available;

  /// The banner is showing: a newer build than the one dismissed.
  bool get bannerShown => _available != null && (_dismissedBuild == null || _available!.build > _dismissedBuild!);

  /// The banner's words and its button's.
  String get bannerText => android ? 'New version available' : 'New version available: open TestFlight';
  String get openLabel => android ? 'Open Play Store' : 'Open TestFlight';

  Future<void> check() async {
    _dismissedBuild = await _store?.read();
    final u = await source.check();
    if (u == null) return;
    _available = u;
    notifyListeners();
  }

  void dismiss() {
    final b = _available?.build;
    if (b == null) return;
    _dismissedBuild = b;
    _store?.write(b);
    notifyListeners();
  }

  /// iPhone: TestFlight at the new build (the release file's link). Android: Cache's page in the Play Store app, else on the web.
  Future<void> open() async {
    if (android) {
      try {
        await openUrl('market://details?id=$kAndroidAppId');
      } catch (_) {
        await openUrl('https://play.google.com/store/apps/details?id=$kAndroidAppId');
      }
      return;
    }
    final link = _available?.link;
    if (link != null) await openUrl(link.toString());
  }
}

/// The banner at the top of Home while a newer Cache is out: one line and its button. A swipe dismisses it until a newer build.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updates});

  final AppUpdates updates;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      if (!updates.bannerShown) return const SizedBox.shrink();
      final k = context.t;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Dismissible(
          key: const ValueKey('update-banner'),
          onDismissed: (_) => updates.dismiss(),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: k.accent.withValues(alpha: 0.6), width: 1.5)),
            child: Row(
              children: [
                Icon(Icons.system_update_outlined, size: 22, color: k.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(updates.bannerText,
                      key: const ValueKey('update-banner-text'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.text)),
                ),
                TextButton(key: const ValueKey('update-open'), onPressed: updates.open, child: Text(updates.openLabel)),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// "What's new in 1.0.N": the owner's lines for this version, from assets/whats_new.md (`## <version>` then one `- ` line each;
/// `**lead words**` are bold). Nothing for a version with no lines: Cache never writes them itself.
List<String> whatsNewLines(String markdown, String version) {
  final out = <String>[];
  var inside = false;
  for (final raw in const LineSplitter().convert(markdown)) {
    final l = raw.trim();
    if (l.startsWith('## ')) {
      inside = l.substring(3).trim() == version;
      continue;
    }
    if (inside && l.startsWith('- ') && l.length > 2) out.add(l.substring(2).trim());
  }
  return out;
}

/// Whether "What's new" was seen for each version: a small file next to the settings.
class WhatsNewSeen {
  WhatsNewSeen({Directory? dirOverride}) : _dir = dirOverride;

  final Directory? _dir;

  Future<File> _file() async => File('${(_dir ?? await getApplicationSupportDirectory()).path}/whats_new.json');

  Future<String?> lastSeen() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync());
      return j is Map && j['seen'] is String ? j['seen'] as String : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> markSeen(String version) async {
    try {
      final f = await _file();
      f.writeAsStringSync(jsonEncode({'seen': version}));
    } catch (_) {}
  }
}

/// The sheet after an update is on in the app. The tests turn it off (test/flutter_test_config.dart): a test machine has no
/// app folder to remember it was seen, so it would open over Home in every test that starts the app with a model.
bool whatsNewAfterUpdate = true;

/// Shows "What's new in [version]" once, after the first start of a new version, when the owner wrote lines for it. A first install
/// ([firstInstall]) records the version without showing it. Any way it closes (Got it, a swipe down, a tap outside) counts as seen.
Future<void> maybeShowWhatsNew(BuildContext context, {required WhatsNewSeen seen, required bool firstInstall, String version = kAppVersion, Future<String> Function()? read}) async {
  if (!whatsNewAfterUpdate) return;
  final last = await seen.lastSeen();
  if (last == version) return;
  if (last == null && firstInstall) {
    await seen.markSeen(version);
    return;
  }
  String text;
  try {
    text = await (read ?? () => rootBundle.loadString('assets/whats_new.md'))();
  } catch (_) {
    return;
  }
  final lines = whatsNewLines(text, version);
  if (lines.isEmpty || !context.mounted) return;
  await seen.markSeen(version);
  if (!context.mounted) return;
  await showWhatsNew(context, version: version, lines: lines);
}

/// This version's lines, or none (no row, no sheet).
Future<List<String>> currentWhatsNew({String version = kAppVersion}) async {
  try {
    return whatsNewLines(await rootBundle.loadString('assets/whats_new.md'), version);
  } catch (_) {
    return const [];
  }
}

/// The sheet itself: the title, the lines (bold lead words) and Got it. 560 wide at most (a tablet shows it as a centred sheet).
Future<void> showWhatsNew(BuildContext context, {required String version, required List<String> lines}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
  builder: (ctx) {
    final k = ctx.t;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          key: const ValueKey('whats-new'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("What's new in $version", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.text)),
            const SizedBox(height: 12),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 7), child: Icon(Icons.circle, size: 6, color: k.accent)),
                    const SizedBox(width: 10),
                    Expanded(child: Text.rich(_bold(l), style: TextStyle(fontSize: 14, height: 1.4, color: k.text))),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton(key: const ValueKey('whats-new-ok'), onPressed: () => Navigator.pop(ctx), child: const Text('Got it')),
            ),
          ],
        ),
      ),
    );
  },
);

/// "**Lead words** the rest" as spans.
TextSpan _bold(String l) {
  final m = RegExp(r'^\*\*(.+?)\*\*\s*(.*)$').firstMatch(l);
  if (m == null) return TextSpan(text: l);
  return TextSpan(children: [TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)), TextSpan(text: ' ${m.group(2)}')]);
}
