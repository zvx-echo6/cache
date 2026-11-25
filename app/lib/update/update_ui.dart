import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../app_fs.dart';
import '../desktop/desktop.dart';
import '../platform/app_log.dart' show logInfo;
import '../theme.dart';
import '../version.dart';
import 'app_update.dart';

/// The installed build number ([kAppBuild], pubspec.yaml's `+<build>`), the same on both phones.
int get installedBuild => kAppBuild;

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

  AppFs get _fs => createAppFs(supportOverride: _dir);

  Future<int?> read() async {
    try {
      final text = await _fs.readString(AppRoot.support, 'update_banner.json');
      if (text == null) return null;
      final j = jsonDecode(text);
      return j is Map && j['dismissed_build'] is num ? (j['dismissed_build'] as num).toInt() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(int build) async {
    try {
      await _fs.writeString(AppRoot.support, 'update_banner.json', jsonEncode({'dismissed_build': build}));
    } catch (_) {}
  }
}

/// A newer Cache, for the banner on Home (iPhone: TestFlight; Android: Cache's page in the Play Store app) and its line in
/// Settings > Credits and licences. Checked once a start (no connection is not an update). A dismissed banner stays dismissed,
/// across restarts too, until a newer build is out; the line in Settings stays.
class AppUpdates extends ChangeNotifier {
  AppUpdates({required this.source, required this.openUrl, required this.android, this.linux = false, DismissedUpdate? dismissed}) : _store = dismissed;

  final AppUpdateSource source;
  final Future<void> Function(String url) openUrl;

  /// Android (the Play Store app) rather than iPhone (TestFlight).
  final bool android;

  /// Cache on Linux: the update is a new tarball and install.sh on the server, so the banner explains it instead of opening a store.
  final bool linux;
  final DismissedUpdate? _store;

  AppUpdate? _available;
  int? _dismissedBuild;

  /// The newer release for this phone, or null.
  AppUpdate? get available => _available;

  /// The banner is showing: a newer build than the one dismissed.
  bool get bannerShown => _available != null && (_dismissedBuild == null || _available!.build > _dismissedBuild!);

  /// The banner's words and its button's.
  String get bannerText => linux
      ? 'New version available: update Cache on this computer'
      : android
      ? 'New version available'
      : 'New version available: open TestFlight';
  String get openLabel => linux
      ? 'How to update'
      : android
      ? 'Open Play Store'
      : 'Open TestFlight';

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
    if (!linux && android) {
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
      // The Linux desktop: a 48-pixel strip with a 3-pixel stripe in the warning colour, the message and the action the same weight.
      final desktop = isLinuxDesktop(context);
      final body = Container(
            height: desktop ? 48 : null,
            padding: desktop ? const EdgeInsets.fromLTRB(14, 0, 6, 0) : const EdgeInsets.fromLTRB(14, 6, 6, 6),
            decoration: desktop
                ? BoxDecoration(color: k.surface, border: Border(left: BorderSide(color: k.warning, width: 3)))
                : BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: k.accent.withValues(alpha: 0.6), width: 1.5)),
            child: Row(
              children: [
                Icon(Icons.system_update_outlined, size: 22, color: k.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(updates.bannerText,
                      key: const ValueKey('update-banner-text'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.text)),
                ),
                TextButton(
                  key: const ValueKey('update-open'),
                  onPressed: updates.linux ? () => showHowToUpdate(context, updates) : updates.open,
                  child: Text(updates.openLabel, style: desktop ? const TextStyle(fontSize: 14, fontWeight: FontWeight.w600) : null),
                ),
                if (updates.linux)
                  IconButton(key: const ValueKey('update-dismiss'), tooltip: 'Dismiss', icon: Icon(Icons.close, size: 20, color: k.secondary), onPressed: updates.dismiss),
              ],
            ),
          );
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Dismissible(
          key: const ValueKey('update-banner'),
          onDismissed: (_) => updates.dismiss(),
          child: desktop ? ClipRRect(borderRadius: BorderRadius.circular(8), child: body) : body,
        ),
      );
    },
  );
}

/// Cache on Linux: what the banner's button says. The browser cannot install anything: the update is a new tarball and install.sh on
/// the computer that runs Cache.
/// What "Update Cache" in a message does: what the update banner's button does (Linux: how to update the server; Android:
/// Cache's page in the Play Store; iPhone: TestFlight at the new build). Null when this build cannot say where the update is
/// (no update source, or on Linux and iPhone no newer release known yet): the words then stay words.
VoidCallback? updateCacheAction(BuildContext context) {
  final u = currentAppUpdates;
  if (u == null) return null;
  if (u.linux) return u.available == null ? null : () => showHowToUpdate(context, u);
  if (u.android) return u.open;
  return u.available?.link == null ? null : u.open;
}

/// [updateCacheAction] as a message's action, labelled "Update Cache"; null when there is nowhere to go.
SnackBarAction? updateCacheSnackAction(BuildContext context) {
  final go = updateCacheAction(context);
  return go == null ? null : SnackBarAction(label: 'Update Cache', onPressed: go);
}

Future<void> showHowToUpdate(BuildContext context, AppUpdates updates, {String installedVersion = kAppVersion}) {
  final u = updates.available;
  if (u == null) return Future.value();
  final notes = u.notes;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('how-to-update'),
      title: const Text('Update Cache on this computer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cache ${u.version} is out (you have $installedVersion).'),
          if (notes != null && notes.isNotEmpty) ...[const SizedBox(height: 10), Text("What's new: $notes")],
          const SizedBox(height: 10),
          const Text(
            'Cache on Linux updates on the computer that runs it, not in the browser. On that computer, download the new tarball, then '
            'run install.sh. Your library, notebooks and settings stay.',
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        if (u.link != null) FilledButton(key: const ValueKey('update-download-page'), onPressed: updates.open, child: const Text('Open the download page')),
      ],
    ),
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

  AppFs get _fs => createAppFs(supportOverride: _dir);

  Future<String?> lastSeen() async {
    try {
      final text = await _fs.readString(AppRoot.support, 'whats_new.json');
      if (text == null) return null;
      final j = jsonDecode(text);
      return j is Map && j['seen'] is String ? j['seen'] as String : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> markSeen(String version) async {
    try {
      await _fs.writeString(AppRoot.support, 'whats_new.json', jsonEncode({'seen': version}));
    } catch (_) {}
  }
}

/// The sheet after an update is on in the app. The tests turn it off (test/flutter_test_config.dart): a test machine has no
/// app folder to remember it was seen, so it would open over Home in every test that starts the app with a model.
bool whatsNewAfterUpdate = true;

/// Shows "What's new in [version]" once, after the first start of a new version, when the owner wrote lines for it. A first install
/// ([firstInstall]) records the version without showing it. Any way it closes (Got it, a swipe down, a tap outside) counts as seen.
///
/// Every decision writes one line to the app log ("whats-new: BRANCH"), so a sheet that did not show says why.
Future<void> maybeShowWhatsNew(BuildContext context, {required WhatsNewSeen seen, required bool firstInstall, String version = kAppVersion, Future<String> Function()? read, void Function(String)? log}) async {
  final say = log ?? logInfo;
  if (!whatsNewAfterUpdate) {
    say('whats-new: off (whatsNewAfterUpdate is false) for $version');
    return;
  }
  final last = await seen.lastSeen();
  if (last == version) {
    say('whats-new: seen equal ($version)');
    return;
  }
  if (last == null && firstInstall) {
    await seen.markSeen(version);
    say('whats-new: first install with no record, recorded $version');
    return;
  }
  String text;
  try {
    text = await (read ?? () => rootBundle.loadString('assets/whats_new.md'))();
  } catch (_) {
    say('whats-new: lines file unreadable for $version');
    return;
  }
  final lines = whatsNewLines(text, version);
  if (lines.isEmpty) {
    say('whats-new: no section for $version (seen ${last ?? 'none'})');
    return;
  }
  if (!context.mounted) {
    say('whats-new: context gone before showing $version');
    return;
  }
  await seen.markSeen(version);
  if (!context.mounted) {
    say('whats-new: context gone before showing $version');
    return;
  }
  say('whats-new: shown $version (seen ${last ?? 'none'}, ${lines.length} lines)');
  await showWhatsNew(context, version: version, lines: lines);
}

/// Why the sheet waits now (it opens on Home only, never over another screen), or null when Home is showing.
String? whatsNewGuard({required bool moduleOpen, required bool onModules, required bool homeIsCurrent}) {
  if (moduleOpen) return 'a module is open';
  if (onModules) return 'on the modules page';
  if (!homeIsCurrent) return 'Home is not the current route';
  return null;
}

/// Completes once [started] is true, as [app] (a listenable) tells. The first-install question ("no model installed") is only
/// true after the models folder was read; before that every phone looks like a first install.
Future<void> whenStarted(Listenable app, bool Function() started) {
  if (started()) return Future<void>.value();
  final done = Completer<void>();
  void check() {
    if (!started() || done.isCompleted) return;
    app.removeListener(check);
    done.complete();
  }

  app.addListener(check);
  return done.future;
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
    // The lines scroll; Got it stays under them, always in view (a phone held sideways has room for a few lines only).
    return SafeArea(
      child: Column(
        key: const ValueKey('whats-new'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
              child: Column(
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
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
            child: FilledButton(key: const ValueKey('whats-new-ok'), onPressed: () => Navigator.pop(ctx), child: const Text('Got it')),
          ),
        ],
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
