import '../search/index_scheduler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_settings.dart';
import 'data_policy.dart';
import '../regions/regions_state.dart';
import '../sharing/settings_sync.dart';
import '../sharing/sharing_state.dart';
import '../weather/weather_state.dart';
import 'storage_usage.dart';
import 'web_search_setup.dart';

/// Opens a page in the phone's own browser.
typedef UrlOpener = Future<void> Function(String url);

Future<void> openInSystemBrowser(String url) => InAppBrowser.openWithSystemBrowser(url: WebUri(url));

/// What the Settings pages share besides the app's main state objects: the saved choices, the mobile-data rule, the web search
/// service, the live data sources (weather, alerts, fires), the storage measurements and how to open a link.
class SettingsHub {
  SettingsHub({
    required this.settings,
    required this.policy,
    required this.webSearch,
    required this.storage,
    required this.weather,
    this.sharing,
    this.settingsSync,
    this.regions,
    this.indexing,
    this.openUrl = openInSystemBrowser,
  });

  final AppSettings settings;
  final DataPolicy policy;
  final WebSearchSetup webSearch;
  final StorageUsage storage;
  final WeatherState weather;

  /// Sharing and sync between linked devices; null where the app has none (tests).
  final SharingState? sharing;

  /// Settings between linked devices (each linked device's page); null where the app has none (tests).
  final SettingsSync? settingsSync;

  /// Regions and downloads (road routing and map by region); null where the app has none (tests).
  final RegionsState? regions;

  /// The automatic search index work (its one status line); null where the app has none (tests).
  final IndexScheduler? indexing;
  final UrlOpener openUrl;

  Listenable get changes => Listenable.merge([settings, webSearch, storage, weather]);
}
