
import 'package:workmanager/workmanager.dart';

import '../platform/app_log.dart';
import '../platform/battery.dart';

/// The background layer the app's jobs share: one WorkManager dispatcher (background_dispatcher.dart) that routes each task by
/// its name, the constraint presets, the one lock (background_lock.dart) and one log line per run. The tasks:
/// - weather: the live data update and the alert check (weather/background.dart). Its name is the one it always had, since it is
///   also the iPhone's BGTaskScheduler identifier (Info.plist) and existing phones have it scheduled under that name;
/// - watch-folder-detect: Android, a few times a day, counts new files in the watched folders (no reading, no adding);
/// - watch-folder-add: Android, once, while charging: adds the new PDFs through Add PDF in slices;
/// - sync: a slot kept for a background notebook and library sync. Not built: there is no task under that name yet.
const String kWeatherTask = 'com.happylittle.cache.live-update';
const String kWatchDetectTask = 'com.happylittle.cache.watch-folder-detect';
const String kWatchAddTask = 'com.happylittle.cache.watch-folder-add';

/// The short names the log uses.
const Map<String, String> kBackgroundTaskNames = {
  kWeatherTask: 'weather',
  kWatchDetectTask: 'watch-folder-detect',
  kWatchAddTask: 'watch-folder-add',
};

/// The constraints the jobs are scheduled with.
class BackgroundPresets {
  const BackgroundPresets._();

  /// Weather: a network connection (as it always was).
  static Constraints network() => Constraints(networkType: NetworkType.connected);

  /// A light look (listing folders): only not on a low battery.
  static Constraints light() => Constraints(networkType: NetworkType.notRequired, requiresBatteryNotLow: true);

  /// Heavy work (adding PDFs): only while charging, and not on a low battery. Heat is checked by the job itself (the same rules
  /// as the app's index work), since WorkManager has no constraint for it.
  static Constraints charging() => Constraints(networkType: NetworkType.notRequired, requiresCharging: true, requiresBatteryNotLow: true);
}

/// Where the jobs are scheduled: WorkManager on a phone; tests record the calls.
abstract class BackgroundScheduler {
  /// Every [every] (WorkManager picks the moment), under [constraints]; scheduling again updates it.
  Future<void> periodic(String task, {required Duration every, required Constraints constraints});

  /// Once, under [constraints], after [delay]. [after]: added after a run of it already queued or running (a slice queues the
  /// next one); else a run already queued is kept.
  Future<void> once(String task, {required Constraints constraints, Duration delay = Duration.zero, bool after = false});

  Future<void> cancel(String task);
}

/// [BackgroundScheduler] on WorkManager: each task under its own unique name.
class WorkmanagerScheduler implements BackgroundScheduler {
  const WorkmanagerScheduler();

  @override
  Future<void> periodic(String task, {required Duration every, required Constraints constraints}) => Workmanager().registerPeriodicTask(
    task,
    task,
    frequency: every,
    constraints: constraints,
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );

  @override
  Future<void> once(String task, {required Constraints constraints, Duration delay = Duration.zero, bool after = false}) => Workmanager().registerOneOffTask(
    task,
    task,
    constraints: constraints,
    initialDelay: delay,
    existingWorkPolicy: after ? ExistingWorkPolicy.append : ExistingWorkPolicy.keep,
  );

  @override
  Future<void> cancel(String task) => Workmanager().cancelByUniqueName(task);
}

/// The app's scheduler (tests set their own).
BackgroundScheduler backgroundScheduler = const WorkmanagerScheduler();

/// One background job: does its work and says how it ended, in a few words ("2 new in 1 folder", "added 3, more to do",
/// "skipped: Cache is open").
typedef BackgroundJob = Future<String> Function(Map<String, dynamic>? input);

/// Runs a task the system started: routes it to its job by name and writes one log line for the run (the task, start, end, how
/// it ended, the battery, charging and heat at the start). A job that throws is logged as failed; the run always reports done,
/// so a failed run waits for its next turn rather than being retried at once (as the weather run always did).
class BackgroundTasks {
  BackgroundTasks({required this.jobs, this.battery = readBattery, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Map<String, BackgroundJob> jobs;
  final BatteryReader battery;
  final DateTime Function() _clock;

  /// The log line of the last run (tests read it).
  String? lastLine;

  Future<bool> run(String task, Map<String, dynamic>? input) async {
    final start = _clock();
    BatteryReading? b;
    try {
      b = await battery();
    } catch (_) {}
    final job = jobs[task];
    String outcome;
    if (job == null) {
      outcome = 'no such task';
    } else {
      try {
        outcome = await job(input);
      } catch (e, st) {
        logError('Background ${kBackgroundTaskNames[task] ?? task} failed', error: e, stack: st);
        outcome = 'failed: $e';
      }
    }
    final end = _clock();
    final line = 'Background run: task ${kBackgroundTaskNames[task] ?? task}, start ${start.toIso8601String()}, end ${end.toIso8601String()}, '
        'outcome $outcome, battery ${b == null ? 'unknown' : '${b.percent}%'}, charging ${b == null ? 'unknown' : (b.charging ? 'yes' : 'no')}, '
        'thermal ${b?.thermal.name ?? 'unknown'}';
    lastLine = line;
    logInfo(line);
    return true;
  }
}
