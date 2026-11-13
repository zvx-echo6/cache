import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../library/add_pdf/add_pdf_state.dart';
import '../platform/app_log.dart';
import '../platform/battery.dart';

// The foreground service for adding PDFs in the background (Android only), build 52. Design: renders/fgs/design.md (branch
// design/fgs-background-add); the owner's decisions are in the build's notes:
// - it starts while Cache is still in front, as the person LEAVES (Home or Back) with adds pending: Android 12 and later refuse a
//   start from the background. Kotlin starts it (FgsAddArm, from MainActivity); this file tells Kotlin whether to ([FgsAddCoordinator]);
// - it runs on the battery above the low-battery threshold, not only while charging;
// - the notifications are silent; the in-app notice ([FgsAddNotice]) says on the next open what a background add ended with;
// - no file names on the lock screen (the notification's public version, FgsAddNotifications.kt);
// - the service runs the same Add PDF slice the WorkManager charging run runs, under the same `run-pdf-add` lock.

/// The app's engine <-> MainActivity: `arm` (whether leaving now starts the service), `notificationsAllowed`.
const MethodChannel kFgsAppChannel = MethodChannel('co.cache/fgs_add');

/// The service's own Dart engine <-> the service: `progress` and `finished` out, `stop` in.
const MethodChannel kFgsRunChannel = MethodChannel('co.cache/fgs_add_run');

/// The library's name in the notifications: the default own library is "Bookshelves" (the owner's wording, 2026-11-12); a library
/// the person named keeps its name.
const String kDefaultLibraryTitle = 'My books';
String fgsLibraryWords(AddPdfJob job) => job.libraryTitle == kDefaultLibraryTitle ? 'Bookshelves' : job.libraryTitle;

// ---------------------------------------------------------------------------------------------------------------------
// The words. All of these strings are DRAFTS from wording.md (design/fgs-background-add), kept marked until the owner approves
// them; the ones that are not marked reuse words the app already has.
// ---------------------------------------------------------------------------------------------------------------------
class FgsWords {
  const FgsWords._();

  // WORDING QUESTION (owner): draft, not yet approved
  static const String askTitle = 'Show how adding is going?';
  // WORDING QUESTION (owner): draft, not yet approved
  static const String askText =
      'Cache can keep adding PDFs when you leave it, and show you how it is going. Allow notifications to see it and to pause it.';
  // WORDING QUESTION (owner): draft, not yet approved
  static const String askAllow = 'Allow';
  // WORDING QUESTION (owner): draft, not yet approved
  static const String askNotNow = 'Not now';
  // WORDING QUESTION (owner): draft, not yet approved
  static const String refused = 'Cache still adds PDFs, but shows nothing. You can allow notifications in Settings.';

  // WORDING QUESTION (owner): draft, not yet approved
  static const String limitText = 'Android limits background work. It carries on while charging, or open Cache.';

  // WORDING QUESTION (owner): draft, not yet approved
  static String pausedTitle(int done, int total) => 'Paused · ${pdfsOf(done, total)}';

  // WORDING QUESTION (owner): draft, not yet approved
  static String pdfsOf(int done, int total) => '$done of $total PDFs';

  // WORDING QUESTION (owner): draft, not yet approved
  static String failedSeveralTitle(int n) => '$n PDFs could not be added';

  // WORDING QUESTION (owner): draft, not yet approved
  static String addedSomeTitle(int added, int total, String library) => 'Added $added of $total PDFs to $library';

  // WORDING QUESTION (owner): draft, not yet approved
  static String someFailedText(int failed) => '$failed could not be added · tap to see';

  // WORDING QUESTION (owner): draft, not yet approved
  static const String severalFailedText = 'Tap to see them';

  // WORDING QUESTION (owner): draft, not yet approved
  static const String dismiss = 'Dismiss';

  /// Why it paused, in the indexing rules' own words after the middle dot ("Paused by you", "Battery low (12%) · plug in to
  /// continue", "Device is warm"): existing words from `indexWaitWords`, lower-cased after the dot as wording.md says.
  static String? pausedText(FgsAddResult r) => switch (r.why) {
    'person' => 'Paused by you',
    'battery' => r.batteryPercent == null ? 'Battery low · plug in to continue' : 'Battery low (${r.batteryPercent}%) · plug in to continue',
    'heat' => r.warm ? 'Device is warm' : 'Keeping the device cool',
    'timeout' || 'time' => limitText,
    _ => null,
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// Whether leaving starts the service
// ---------------------------------------------------------------------------------------------------------------------

/// Why leaving does or does not start the service.
enum FgsStart { start, notAndroid, nothingToAdd, waitsForCharging, batteryLow, alreadyRunning }

/// A PDF the service would add now: not paused by the person, and not one that waits (a long PDF unplugged at 50% or less waits for
/// charging, the indexing rules' own: "Waits for charging (long job)"; the person's Start now or Resume anyway lifts that). A low
/// battery (under 20% unplugged) holds it too, except for "Resume anyway".
bool fgsJobMayRun(AddPdfJob job, BatteryReading? battery) {
  if (job.status != AddPdfStatus.active || job.pausedByPerson) return false;
  if (battery == null) return true;
  if (battery.low && !job.anyway) return false;
  final long = !(job.startNow || job.anyway);
  if (long && !battery.charging && battery.percent <= 50) return false;
  return true;
}

/// The decision made as the person leaves (Back at the root, Home): start the service when there are adds pending that may run now.
/// A pure function of what the app knows; the battery rule is "above the low-battery threshold, on battery or charging".
FgsStart fgsStartOnLeave({required bool android, required Iterable<AddPdfJob> jobs, required BatteryReading? battery, bool running = false}) {
  if (!android) return FgsStart.notAndroid;
  if (running) return FgsStart.alreadyRunning;
  final pending = [for (final j in jobs) if (j.status == AddPdfStatus.active && !j.pausedByPerson) j];
  if (pending.isEmpty) return FgsStart.nothingToAdd;
  if (pending.any((j) => fgsJobMayRun(j, battery))) return FgsStart.start;
  return battery != null && battery.low ? FgsStart.batteryLow : FgsStart.waitsForCharging;
}

/// The Android side: whether leaving starts the service, and whether notifications are allowed.
abstract class FgsPlatform {
  Future<void> arm(bool on);
  Future<bool> notificationsAllowed();
  Future<bool> requestNotifications();
}

class MethodChannelFgsPlatform implements FgsPlatform {
  const MethodChannelFgsPlatform();

  @override
  Future<void> arm(bool on) async {
    try {
      await kFgsAppChannel.invokeMethod<void>('arm', {'on': on});
    } on MissingPluginException {
      // not Android
    }
  }

  @override
  Future<bool> notificationsAllowed() async {
    try {
      return await kFgsAppChannel.invokeMethod<bool>('notificationsAllowed') ?? true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<bool> requestNotifications() async {
    try {
      return await const MethodChannel('co.cache/network_access').invokeMethod<bool>('notifications') ?? true;
    } on MissingPluginException {
      return true;
    }
  }
}

/// Keeps Kotlin told whether leaving now starts the service, and asks once for notifications at the first background add.
///
/// The question (Android 13 and later): at the first time adds are pending and the person could leave (the first background add),
/// once, before Android's own prompt: Allow goes on to Android's prompt, Not now does not. When notifications end up not allowed,
/// [onRefused] says what that means (the service still runs; its notification is hidden by the system; the in-app notice covers
/// it). If notifications were already allowed (weather alerts), nothing is asked.
class FgsAddCoordinator {
  FgsAddCoordinator({
    required this.platform,
    required this.jobs,
    required this.battery,
    required this.askedFile,
    this.android = true,
    this.sdk,
    this.ask,
    this.onRefused,
  });

  final FgsPlatform platform;
  final Iterable<AddPdfJob> Function() jobs;
  final BatteryReader battery;

  /// Remembers that the question was asked (it is asked once, ever).
  final File Function() askedFile;
  final bool android;

  /// Android's API level, when known (the question is for 33 and later; null: asked, the platform says when it is not needed).
  final int? sdk;

  /// The "Show how adding is going?" question: true for Allow. Null: not asked.
  final Future<bool> Function()? ask;

  /// Notifications are not allowed after the question (or were refused before it).
  final void Function()? onRefused;

  bool _armed = false;
  bool get armed => _armed;
  bool _asking = false;

  /// Called whenever the adds change, and as Cache comes to the front: decides, and tells Kotlin when it changed.
  Future<FgsStart> update() async {
    final b = android ? await battery() : null;
    final d = fgsStartOnLeave(android: android, jobs: jobs(), battery: b);
    final on = d == FgsStart.start;
    if (on != _armed) {
      _armed = on;
      await platform.arm(on);
    }
    if (on) await _maybeAsk();
    return d;
  }

  Future<void> _maybeAsk() async {
    if (_asking || (sdk != null && sdk! < 33)) return;
    final f = askedFile();
    if (f.existsSync()) return;
    _asking = true;
    try {
      if (await platform.notificationsAllowed()) {
        _remember(f);
        return;
      }
      if (ask == null) return;
      final allow = await ask!();
      _remember(f);
      final granted = allow && await platform.requestNotifications();
      if (!granted) onRefused?.call();
    } finally {
      _asking = false;
    }
  }

  void _remember(File f) {
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(DateTime.now().toIso8601String());
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// What the run says while it goes, and how it ended
// ---------------------------------------------------------------------------------------------------------------------

/// What the notification shows while PDFs are added: "2 of 5 PDFs · Radio field manual", the bar, the time left.
class FgsProgress {
  const FgsProgress({
    required this.done,
    required this.total,
    required this.current,
    required this.fraction,
    required this.library,
    this.left,
    this.more,
  });

  /// PDFs finished (added or stopped) of the [total] this run took on, the name of the one it is on, its own share (0 to 1), the
  /// library's words, the time left ("About 12 min left") and the line for the ones waiting ("Garden notes and 2 more waiting").
  final int done;
  final int total;
  final String current;
  final double fraction;
  final String library;
  final String? left;
  final String? more;

  /// The bar, 0 to 1: (PDFs done + the current one's share) / PDFs. Null (indeterminate) until the first estimate: nothing is known
  /// of the current PDF's pages yet.
  double? get bar => fraction <= 0 && done == 0 ? null : ((done + fraction) / total).clamp(0.0, 1.0);

  Map<String, Object?> toJson() => {
    'done': done,
    'total': total,
    'current': current,
    'bar': bar,
    'library': library,
    'left': left,
    'more': more,
  };

  /// The progress of the jobs [ids] (the PDFs this run took on) as they stand now; null when there are none.
  static FgsProgress? of(Set<String> ids, Iterable<AddPdfJob> jobs) {
    final mine = [for (final j in jobs.toList().reversed) if (ids.contains(j.id)) j];
    if (mine.isEmpty) return null;
    final open = [for (final j in mine) if (j.status == AddPdfStatus.active && !j.pausedByPerson) j];
    final done = mine.length - mine.where((j) => j.status == AddPdfStatus.active).length;
    final cur = open.isEmpty ? mine.last : open.first;
    final waiting = open.length > 1 ? open.skip(1).toList() : const <AddPdfJob>[];
    var left = Duration.zero;
    for (final j in open) {
      left += addPdfTimeLeft(j);
    }
    return FgsProgress(
      done: done,
      total: mine.length,
      current: cur.title,
      fraction: cur.fraction,
      library: fgsLibraryWords(mine.first),
      left: open.isEmpty ? null : '${aboutMinutes(left)} left',
      // WORDING QUESTION (owner): draft, not yet approved
      more: waiting.isEmpty ? null : (waiting.length == 1 ? '${waiting.first.title} waiting' : '${waiting.first.title} and ${waiting.length - 1} more waiting'),
    );
  }
}

/// How a background add ended, kept in `<support>/background/fgs-add-result.json` for the in-app notice (next open). [why]:
/// "done" (nothing left), "person" (Pause in the notification), "battery", "heat", "timeout" (Android's time limit), "app" (Cache
/// came to the front: it carries on itself, so nothing is said), "stopped".
class FgsAddResult {
  const FgsAddResult({required this.at, required this.why, required this.total, required this.added, required this.failedIds, required this.leftIds, this.batteryPercent, this.warm = false, this.library = 'Bookshelves'});

  final DateTime at;
  final String why;
  final int total;
  final int added;
  final List<String> failedIds;
  final List<String> leftIds;
  final int? batteryPercent;
  final bool warm;
  final String library;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'why': why,
    'total': total,
    'added': added,
    'failed': failedIds,
    'left': leftIds,
    'battery': batteryPercent,
    'warm': warm,
    'library': library,
  };

  static FgsAddResult? fromJson(Object? o) {
    if (o is! Map) return null;
    try {
      return FgsAddResult(
        at: DateTime.parse(o['at'] as String),
        why: o['why'] as String,
        total: (o['total'] as num).toInt(),
        added: (o['added'] as num).toInt(),
        failedIds: [for (final x in (o['failed'] as List)) x as String],
        leftIds: [for (final x in (o['left'] as List)) x as String],
        batteryPercent: (o['battery'] as num?)?.toInt(),
        warm: o['warm'] == true,
        library: (o['library'] as String?) ?? 'Bookshelves',
      );
    } catch (_) {
      return null;
    }
  }
}

File fgsResultFile(String backgroundDirPath) => File('$backgroundDirPath${Platform.pathSeparator}fgs-add-result.json');

Future<void> writeFgsResult(String backgroundDirPath, FgsAddResult r) async {
  try {
    final f = fgsResultFile(backgroundDirPath);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(r.toJson()), flush: true);
    await tmp.rename(f.path);
  } catch (e) {
    logError('Background add: how it ended could not be written', error: e);
  }
}

FgsAddResult? readFgsResult(String backgroundDirPath) {
  try {
    final f = fgsResultFile(backgroundDirPath);
    if (!f.existsSync()) return null;
    return FgsAddResult.fromJson(jsonDecode(f.readAsStringSync()));
  } catch (_) {
    return null;
  }
}

void clearFgsResult(String backgroundDirPath) {
  try {
    final f = fgsResultFile(backgroundDirPath);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

// ---------------------------------------------------------------------------------------------------------------------
// The in-app notice
// ---------------------------------------------------------------------------------------------------------------------

/// What Cache says in the app, when it is next opened, of a background add that failed or ended before it was done.
class FgsAddNotice {
  const FgsAddNotice({required this.title, required this.text, required this.failed, this.alsoTitle, this.alsoText});

  final String title;
  final String text;

  /// Some PDF could not be added: the card is drawn in the error tone.
  final bool failed;

  /// When some failed and the run also stopped early, the second line says so.
  final String? alsoTitle;
  final String? alsoText;

  /// The notice for [r] over the jobs as they stand now; null when there is nothing to say (all added; Cache took over; or the
  /// stopped PDFs were dealt with since).
  static FgsAddNotice? of(FgsAddResult r, Iterable<AddPdfJob> jobs) {
    final byId = {for (final j in jobs) j.id: j};
    final failed = [for (final id in r.failedIds) if (byId[id] case final j? when j.status == AddPdfStatus.failed) j];
    final left = [for (final id in r.leftIds) if (byId[id] case final j? when j.status == AddPdfStatus.active) j];
    final stoppedEarly = left.isNotEmpty && r.why != 'done' && r.why != 'app';
    final pausedTitle = FgsWords.pausedTitle(r.total - left.length, r.total);
    final pausedText = FgsWords.pausedText(r);
    if (failed.isNotEmpty) {
      final String title;
      final String text;
      if (failed.length == 1) {
        // the Add PDF page's own words for the error, with the file's name (wording.md: "Failed")
        final w = addPdfErrorWords(failed.first);
        title = w.title;
        text = '${failed.first.title} · ${w.body}';
      } else if (r.added > 0) {
        title = FgsWords.addedSomeTitle(r.added, r.total, r.library);
        text = FgsWords.someFailedText(failed.length);
      } else {
        title = FgsWords.failedSeveralTitle(failed.length);
        text = FgsWords.severalFailedText;
      }
      return FgsAddNotice(title: title, text: text, failed: true, alsoTitle: stoppedEarly ? pausedTitle : null, alsoText: stoppedEarly ? pausedText : null);
    }
    if (stoppedEarly) return FgsAddNotice(title: pausedTitle, text: pausedText ?? '', failed: false);
    return null;
  }
}

/// The in-app notice's state: read when Cache opens, shown on the Library, put away with Dismiss.
class FgsAddNoticeState extends ChangeNotifier {
  FgsAddNoticeState({required this.backgroundDir, required this.jobs});

  final String Function() backgroundDir;
  final Iterable<AddPdfJob> Function() jobs;

  FgsAddNotice? _notice;
  FgsAddNotice? get notice => _notice;

  /// Reads how the last background add ended, once the jobs are read; call as Cache opens and comes to the front.
  void load() {
    final r = readFgsResult(backgroundDir());
    final n = r == null ? null : FgsAddNotice.of(r, jobs());
    // a result with nothing to say is put away
    if (r != null && n == null) clearFgsResult(backgroundDir());
    if (n?.title == _notice?.title && n?.text == _notice?.text) return;
    _notice = n;
    notifyListeners();
  }

  void dismiss() {
    clearFgsResult(backgroundDir());
    _notice = null;
    notifyListeners();
  }
}

/// The app's notice (null on the web and in tests that do not need it).
FgsAddNoticeState? fgsNoticeShared;
