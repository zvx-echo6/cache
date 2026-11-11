import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../app_fs.dart';
import '../library/add_pdf/watch_background.dart';
import '../platform/app_log.dart';
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
