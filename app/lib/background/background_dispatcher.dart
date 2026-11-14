import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../app_fs.dart';
import '../library/add_pdf/watch_background.dart';
import '../platform/app_log.dart';
import '../weather/background.dart';
import 'background_tasks.dart';
import 'sync_background.dart';

/// The jobs of the shared background layer, by task name.
Map<String, BackgroundJob> backgroundJobs() => {
  kWeatherTask: weatherBackgroundJob,
  kWatchDetectTask: (_) async => watchDetectJob(support: await appSupportPath()),
  kWatchAddTask: (_) async => watchAddJob(support: await appSupportPath()),
  kSyncTask: (_) async => syncBackgroundJob(support: await appSupportPath(), budget: kSyncBudgetAndroid),
  kSyncRefreshTask: (_) async => syncBackgroundJob(support: await appSupportPath(), budget: kSyncBudgetRefresh),
  kSyncProcessingTask: (_) async {
    try {
      return await syncBackgroundJob(support: await appSupportPath(), budget: kSyncBudgetProcessing);
    } finally {
      // a processing task runs once: the next is asked for as this one ends
      await scheduleProcessing(kSyncProcessingTask, constraints: BackgroundPresets.syncCharging(), delay: kSyncEvery);
    }
  },
};

/// The one entry point the system starts for every background run (WorkManager on Android, BGTaskScheduler on iPhone, which
/// runs the weather and the sync tasks). It opens the app's log, so each run's one line lands where the app's lines do.
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
