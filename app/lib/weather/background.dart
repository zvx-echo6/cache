import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../maps/layers/starter_defs.dart' show readLiveSourceAssets;
import '../search/core_config.dart';
import '../settings/app_settings.dart';
import '../settings/data_policy.dart';
import '../video/token_store.dart';
import 'alert_notifier.dart';
import 'alert_watch.dart';
import 'live_core.dart';
import 'places.dart';
import 'weather_state.dart';

/// The background task's name. On iPhone it is also the BGTaskScheduler identifier, so it is listed in Info.plist.
const String kBackgroundTask = 'com.happylittle.cache.live-update';

/// How often Android may run it (Android's minimum is 15 minutes; it picks the moment). iOS decides on its own.
const Duration kBackgroundEvery = Duration(minutes: 30);

/// The plugin's set-up (started in main); scheduling waits for it, since the system refuses a task from a plugin that has
/// not stored the background entry point yet.
Future<void>? backgroundReady;

/// Where the phone was and which regions are downloaded, as the app last knew them, for "Where I am" and the regions in a
/// background run (which has no GPS of its own and no map state).
class LastPlace {
  const LastPlace({this.here, this.regions = const []});

  final Position? here;
  final List<WatchRegion> regions;

  static File fileIn(Directory support) => File('${support.path}/last_place.json');

  Map<String, Object?> toJson() => {
    if (here != null) 'here': {'lat': here!.lat, 'lon': here!.lon},
    'regions': [for (final r in regions) {'name': r.name, 'lat': r.lat, 'lon': r.lon}],
  };

  static LastPlace fromJson(Object? j) {
    if (j is! Map) return const LastPlace();
    final h = j['here'];
    return LastPlace(
      here: h is Map && h['lat'] is num && h['lon'] is num ? (lat: (h['lat'] as num).toDouble(), lon: (h['lon'] as num).toDouble()) : null,
      regions: [
        for (final r in (j['regions'] as List? ?? const []))
          if (r is Map && r['name'] is String && r['lat'] is num && r['lon'] is num)
            WatchRegion(name: r['name'] as String, lat: (r['lat'] as num).toDouble(), lon: (r['lon'] as num).toDouble()),
      ],
    );
  }

  static Future<LastPlace> read(File f) async {
    try {
      return fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return const LastPlace();
    }
  }

  Future<void> write(File f) async {
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }
}

/// The entry point the system starts for a background run.
@pragma('vm:entry-point')
void cacheBackgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await runBackgroundUpdate();
    } catch (e) {
      debugPrint('Background update: $e');
    }
    // Always done: a failed run waits for the next turn rather than being retried at once.
    return true;
  });
}

/// One background run: the same update as Update now, for the sources that are on and the watched places, then the alert check.
/// It opens its own search core with only the saved places and live data (no library, maps or routing), so it is light.
Future<void> runBackgroundUpdate() async {
  final support = await getApplicationSupportDirectory();
  final files = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory();
  final settings = AppSettings();
  await settings.init();
  if (settings.liveSourcesOn.isEmpty) return;
  final last = await LastPlace.read(LastPlace.fileIn(support));
  final extras = buildCoreExtras(filesDir: files, supportDir: support);
  final core = await SearchCore.open(const [], extra: {'user': extras['user'], 'live': extras['live']});
  try {
    await LocalAlertNotifier.instance.init();
    final weather = WeatherState(
      settings: settings,
      policy: DataPolicy(settings: settings),
      core: SearchLiveCore(() async => core),
      secrets: const SecureTokenStore(),
      catalogueDir: () async => Directory('${support.path}/live-catalogues'),
      liveDir: () async => Directory('${files.path}/live-defs'),
      builtIns: readLiveSourceAssets,
      position: () => last.here,
      regions: () => last.regions,
      notifier: LocalAlertNotifier.instance,
      told: ToldStore(File('${support.path}/alerts_told.json')),
    );
    await weather.start();
    await weather.updateNow();
  } finally {
    await core.close();
  }
}

/// Schedules the background run when anything is switched on, and cancels it when nothing is. Safe to call often.
Future<bool> scheduleBackgroundUpdates({required bool anythingOn}) async {
  if (!(Platform.isAndroid || Platform.isIOS)) return false;
  try {
    await backgroundReady;
    if (!anythingOn) {
      await Workmanager().cancelByUniqueName(kBackgroundTask);
      return false;
    }
    await Workmanager().registerPeriodicTask(
      kBackgroundTask,
      kBackgroundTask,
      frequency: kBackgroundEvery,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
    return true;
  } catch (e) {
    debugPrint('Background updates could not be scheduled: $e');
    return false;
  }
}
