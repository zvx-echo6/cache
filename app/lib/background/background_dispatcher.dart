import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../app_fs.dart';
import '../library/add_pdf/watch_background.dart';
import '../platform/app_log.dart';
import 'fgs_add.dart';
import '../weather/background.dart';
import 'background_tasks.dart';

/// The jobs of the shared background layer, by task name. A future `sync` task gets its entry here (none yet).
Map<String, BackgroundJob> backgroundJobs() => {
  kWeatherTask: weatherBackgroundJob,
  kWatchDetectTask: (_) async => watchDetectJob(support: await appSupportPath()),
  kWatchAddTask: (_) async => watchAddJob(support: await appSupportPath()),
};

/// The one entry point the system starts for every background run (WorkManager on Android, BGTaskScheduler on iPhone, which
/// only ever runs the weather task). It opens the app's log, so each run's one line lands where the app's lines do.
@pragma('vm:entry-point')
void cacheBackgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await appLog.open(Directory('${await appSupportPath()}${Platform.pathSeparator}logs'));
    } catch (_) {}
    try {
      return await BackgroundTasks(jobs: backgroundJobs()).run(task, input);
    } finally {
      try {
        await appLog.close();
      } catch (_) {}
    }
  });
}

/// The foreground service's Dart entry point (FgsAddService.kt starts an engine on it). It runs the same background add as
/// WorkManager's `watch-folder-add` ([fgsAddJob] and [watchAddJob] share the Add PDF slice, the state over the real core and the
/// `run-pdf-add` lock), with the service's differences. The service talks to it on [kFgsRunChannel]: it sends `progress` (at most
/// once a second) and `finished`; it is told `stop` with a reason ("person" for Pause, "timeout" for Android's time limit).
@pragma('vm:entry-point')
Future<void> cacheFgsAddEntry() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final control = FgsAddControl(onProgress: (p) => unawaited(_say('progress', p.toJson())));
  var resume = false, anyway = false;
  kFgsRunChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'stop':
        control.stop((call.arguments as Map?)?['why'] as String? ?? 'stopped');
    }
    return null;
  });
  String outcome;
  try {
    await appLog.open(Directory('${await appSupportPath()}${Platform.pathSeparator}logs'));
  } catch (_) {}
  // told before the add starts whether this start is Resume
  try {
    final ready = await kFgsRunChannel.invokeMethod<Map>('ready');
    resume = ready?['resume'] == true;
    anyway = ready?['anyway'] == true;
    // a stop that came before this side was listening
    if (ready?['stop'] is String) control.stop(ready!['stop'] as String);
  } catch (_) {}
  try {
    outcome = (await fgsAddJob(support: await appSupportPath(), control: control, resume: resume, anyway: anyway)).words;
  } catch (e, st) {
    logError('Background add (service) failed', error: e, stack: st);
    outcome = 'failed: $e';
  }
  logInfo('Background add (service): $outcome');
  await _say('finished', {'outcome': outcome, ..._finish(control.result, control.failedWords)});
  try {
    await appLog.close();
  } catch (_) {}
}

Future<void> _say(String method, Map<String, Object?> args) async {
  try {
    await kFgsRunChannel.invokeMethod<void>(method, args);
  } catch (_) {}
}

/// What the notification that ends the run says, from how it ended.
Map<String, Object?> _finish(FgsAddResult? r, (String, String, String)? failedWords) {
  if (r == null) return {'kind': 'none'};
  return {
    'kind': r.total == 0 ? 'none' : (r.failedIds.isNotEmpty ? 'failed' : (r.leftIds.isNotEmpty && r.why != 'done' && r.why != 'app' ? 'paused' : (r.leftIds.isNotEmpty ? 'none' : 'added'))),
    'why': r.why,
    'done': r.total - r.leftIds.length,
    'total': r.total,
    'added': r.added,
    'failed': r.failedIds.length,
    'battery': r.batteryPercent,
    'warm': r.warm,
    'library': r.library,
    if (failedWords != null) ...{'failedName': failedWords.$1, 'failedTitle': failedWords.$2, 'failedBody': failedWords.$3},
  };
}
