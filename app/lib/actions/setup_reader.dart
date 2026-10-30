import '../app_state.dart';
import '../location/location_service.dart';
import '../maps/ui/format.dart';
import '../regions/regions_state.dart';
import '../settings/app_settings.dart';
import '../settings/data_policy.dart';
import '../settings/location_access.dart';
import '../settings/web_search_setup.dart';
import '../sources/libraries_state.dart';
import '../sources/sources_state.dart';
import '../weather/curated.dart';
import '../weather/weather_state.dart';
import 'setup_status.dart';

/// "maps, routing, places": the parts of a region on the phone.
String regionParts(LocalRegion r) => [if (r.hasMap) 'maps', if (r.hasRouting) 'routing', if (r.hasPlaces) 'places'].join(', ');

/// The setup parts read from the app's state, in the words the screens use.
SetupDeps setupDepsFrom({
  required AppSettings settings,
  required DataPolicy policy,
  required RegionsState regions,
  required SourcesState sources,
  required LibrariesState libraries,
  required WeatherState weather,
  required WebSearchSetup webSearch,
  required AppState app,
  required LocationService location,
  LocationAccessProbe access = const _Geolocator(),
  DateTime Function() now = DateTime.now,
}) {
  String? age(DateTime? t) => t == null ? null : setupAge(now().difference(t));
  List<LocalRegion> ready() => [for (final r in regions.local) if (r.phase == RegionPhase.ready) r];
  return SetupDeps(
    connection: () async => [
      SetupItem('Network', switch (await policy.probe.current()) {
        ConnectionKind.wifi => 'Wi-Fi',
        ConnectionKind.mobile => 'mobile data',
        ConnectionKind.none => 'none',
        ConnectionKind.other => 'connected',
      }),
      SetupItem('Mobile data downloads', settings.mobileForDownloads ? 'on' : 'off'),
    ],
    regions: () async => [
      for (final r in ready())
        SetupItem(r.name, [regionParts(r), ?age(r.fetchedAt)].where((s) => s.isNotEmpty).join('; ')),
    ],
    libraries: () async => [
      for (final z in sources.zims) SetupItem(sources.titleOf(z), formatBytes(z.size)),
      for (final l in libraries.libraries) SetupItem(libraries.titleOf(l), formatBytes(l.size)),
    ],
    liveData: () async {
      final out = <SetupItem>[];
      for (final row in kCurated) {
        for (final c in weather.rowSources(row)) {
          final on = weather.isOn(c.id);
          out.add(SetupItem(c.title, liveSourceValue(on: on, age: on ? (await weather.infoFor(c)).age : null)));
        }
      }
      return out;
    },
    webSearch: () async => [SetupItem('Kagi key', webSearch.hasKey ? 'set' : 'not set')],
    places: () async {
      final withPlaces = [for (final r in ready()) if (r.hasPlaces) r];
      if (withPlaces.isEmpty) return const [];
      final names = withPlaces.map((r) => r.name).join(', ');
      final one = withPlaces.length == 1 ? withPlaces.single : null;
      return [
        SetupItem('Opening hours and phone numbers',
            'from the $names region${one == null ? 's' : ''}${one?.fetchedAt == null ? '' : ', ${age(one!.fetchedAt)}'}'),
      ];
    },
    models: () async {
      String model(ModelEntry e) => '${app.displayName(e)} (${formatBytes(e.size)})';
      final active = app.active;
      final others = [for (final e in app.models) if (e.key != active?.key) model(e)];
      return [
        SetupItem('In use', active == null ? 'none' : model(active)),
        SetupItem('Other models downloaded', others.isEmpty ? 'none' : others.join(', ')),
      ];
    },
    location: () async => [
      SetupItem('Permission', switch (await access.read()) {
        LocationAccess.always => 'always',
        LocationAccess.whileUsing => 'while using the app',
        LocationAccess.denied => 'not allowed',
        LocationAccess.blocked => "not allowed (only the phone's settings can change it)",
      }),
      SetupItem('Use my location', location.enabled ? 'on' : 'off'),
      SetupItem('Position', location.fix == null ? 'not known' : 'known now'),
    ],
  );
}

class _Geolocator implements LocationAccessProbe {
  const _Geolocator();

  @override
  Future<LocationAccess> read() => GeolocatorAccessProbe().read();
}
