import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../sharing/settings_files.dart' show kOwnSourcesFolder;
import 'app_log.dart';
import '../platform.dart' as plat;

// What a phone's own backup keeps (Android automatic backup, Android phone-to-phone transfer, iPhone iCloud and device backup):
// Cache's settings only, never user data (owner decision, 2026-11-23). API keys are not here either: they live in the phone's
// secure storage, bound to the phone's hardware key, and could not be restored on another phone.
//
// Android states this in res/xml/data_extraction_rules.xml and full_backup_content.xml (include-only rules); a test keeps those two
// files equal to [kBackupAllowList]. iPhone has no include-only rule, so at every start, when the app goes to the background, and
// after a write that replaced a file, everything that is not on the list gets NSURLIsExcludedFromBackupKey.

/// The only things a phone backup keeps, as paths under the app's support folder (Android files/, iPhone Library/Application
/// Support). A folder covers everything inside it.
final List<String> kBackupAllowList = [
  'settings.json',
  'layout.json',
  'preferences.json',
  'maps.json',
  kOwnSourcesFolder,
];

/// The folder that holds the weather source lists; only its [kOwnSourcesFolder] child is on the allow-list.
const String kCataloguesFolder = 'live-catalogues';

/// True when [relPath] (relative to the support folder, '/' separators) is on the allow-list or inside an allow-listed folder.
bool isBackedUp(String relPath, {List<String>? allow}) {
  final list = allow ?? kBackupAllowList;
  for (final a in list) {
    if (relPath == a || relPath.startsWith('$a/')) return true;
  }
  return false;
}

/// Which paths (relative to the support folder) get the iPhone backup-exclusion flag, given the names directly inside the folder
/// ([topLevel]) and the names directly inside `live-catalogues/` ([catalogueChildren]). Allow-listed names are left alone;
/// `live-catalogues` itself is not flagged (its own-sources child must stay in), each of its other children is; every other name,
/// known or new, is flagged.
List<String> backupExclusions(List<String> topLevel, List<String> catalogueChildren, {List<String>? allow}) {
  final out = <String>[];
  for (final name in topLevel) {
    if (name == kCataloguesFolder) {
      for (final c in catalogueChildren) {
        final p = '$kCataloguesFolder/$c';
        if (!isBackedUp(p, allow: allow)) out.add(p);
      }
    } else if (!isBackedUp(name, allow: allow)) {
      out.add(name);
    }
  }
  return out;
}

/// The iPhone side of the flag. Never creates anything: a path that is not there is left alone.
abstract class BackupFlagger {
  /// Sets NSURLIsExcludedFromBackupKey on [path] when it exists; returns false when it does not.
  Future<bool> flagIfPresent(String path);
}

class ChannelBackupFlagger implements BackupFlagger {
  const ChannelBackupFlagger({this.channel = const MethodChannel('co.cache/install_marker')});

  final MethodChannel channel;

  @override
  Future<bool> flagIfPresent(String path) async =>
      await channel.invokeMethod<bool>('excludeIfPresent', {'path': path}) ?? false;
}

/// iPhone: flags everything in [support] (and [docs]; nothing in the documents folder is on the allow-list) that is not on the
/// allow-list. Creates nothing; a flag that fails is logged and the rest go on. Returns the paths flagged.
Future<List<String>> sweepBackupFlags({required Directory support, Directory? docs, required BackupFlagger flagger}) async {
  final flagged = <String>[];
  Future<void> flag(String full) async {
    try {
      if (await flagger.flagIfPresent(full)) flagged.add(full);
    } catch (e) {
      logError('Backup: a file could not be kept out of phone backups', error: e, detail: full);
    }
  }

  List<String> names(Directory d) {
    try {
      return d.existsSync() ? d.listSync(followLinks: false).map((e) => e.path.split(RegExp(r'[\\/]')).last).toList() : const [];
    } catch (e) {
      logError('Backup: a folder could not be listed', error: e, detail: d.path);
      return const [];
    }
  }

  final sep = Platform.pathSeparator;
  for (final rel in backupExclusions(names(support), names(Directory('${support.path}$sep$kCataloguesFolder')))) {
    await flag('${support.path}$sep$rel');
  }
  if (docs != null) {
    for (final n in names(docs)) {
      await flag('${docs.path}$sep$n');
    }
  }
  return flagged;
}

/// iPhone: runs the sweep at start and each time the app goes to the background. Does nothing elsewhere.
class BackupSweeper with WidgetsBindingObserver {
  BackupSweeper({required this.support, required this.docs, BackupFlagger? flagger})
      : _flagger = flagger ?? (plat.isIOS ? const ChannelBackupFlagger() : null);

  final Future<String> Function() support;
  final Future<String> Function() docs;
  final BackupFlagger? _flagger;
  bool _running = false;

  void start() {
    if (_flagger == null) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(sweep());
  }

  void stop() => WidgetsBinding.instance.removeObserver(this);

  Future<void> sweep() async {
    final f = _flagger;
    if (f == null || _running) return;
    _running = true;
    try {
      await sweepBackupFlags(support: Directory(await support()), docs: Directory(await docs()), flagger: f);
    } catch (e) {
      logError('Backup: the sweep failed', error: e);
    } finally {
      _running = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      unawaited(sweep());
    }
  }
}
