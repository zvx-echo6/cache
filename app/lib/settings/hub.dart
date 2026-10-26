import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_settings.dart';
import 'data_policy.dart';
import '../weather/weather_state.dart';
import 'location_access.dart';
import 'storage_usage.dart';
import 'web_search_setup.dart';

/// Opens a page in the phone's own browser.
typedef UrlOpener = Future<void> Function(String url);

Future<void> openInSystemBrowser(String url) => InAppBrowser.openWithSystemBrowser(url: WebUri(url));

/// What the Settings pages share besides the app's main state objects: the saved choices, the mobile-data rule, the web search
/// service, the live data sources (weather, alerts, fires), the storage measurements, the location permission reader and how to open a link.
class SettingsHub {
  SettingsHub({
    required this.settings,
    required this.policy,
    required this.webSearch,
    required this.storage,
    required this.weather,
    LocationAccessProbe? locationAccess,
    this.openUrl = openInSystemBrowser,
  }) : locationAccess = locationAccess ?? GeolocatorAccessProbe();

  final AppSettings settings;
  final DataPolicy policy;
  final WebSearchSetup webSearch;
  final StorageUsage storage;
  final WeatherState weather;
  final LocationAccessProbe locationAccess;
  final UrlOpener openUrl;

  Listenable get changes => Listenable.merge([settings, webSearch, storage, weather]);
}
