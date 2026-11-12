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

/// A region's value in app.setup_status (agreed with cache-llm-training, 2026-10-31): the parts that are ready, in the order
/// maps, routing, places, off-road; then "; " and what is not ready ("places not finished", "places not available yet"); then
/// "; " and the age. "maps, routing; places not finished; 3 weeks old". A region with nothing ready yet is "nothing ready yet":
/// a partly downloaded region never reads as none installed.
String regionSetupValue(LocalRegion r, {String? age}) {
  String name(RegionPartKind k) => switch (k) {
    RegionPartKind.map => 'maps',
    RegionPartKind.directions => 'routing',
    RegionPartKind.places => 'places',
    RegionPartKind.offroad => 'off-road',
  };
  final parts = r.parts;
  // What the assistant reads stays as it was. Road routing with no tile over the area is "not available yet" on the Regions
  // screens now (it read "Ready" with no road data); here it still counts as ready, as it always has, because saying "routing
  // not available yet" would change a tool result, and that waits for its own approval.
  bool isReady(RegionPartStatus p) => p.state == PartState.ready || (p.kind == RegionPartKind.directions && p.state == PartState.notAvailable);
  final ready = [for (final p in parts) if (isReady(p)) name(p.kind)];
  if (ready.isEmpty) return 'nothing ready yet';
  final not = [
    for (final p in parts)
      if (!isReady(p)) p.state == PartState.notAvailable ? '${name(p.kind)} not available yet' : '${name(p.kind)} not finished',
  ];
  return [ready.join(', '), if (not.isNotEmpty) not.join(', '), ?age].join('; ');
}

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
  // Map downloads kept from before regions (listed with the regions on screen since 1.0.28) were never regions to the assistant:
  // what it reads stays as it was.
  // Regions whose every part is ready: what Place details names.
  List<LocalRegion> ready() => [for (final r in regions.local) if (r.phase == RegionPhase.ready && !r.isArea && !r.placesNotAvailable) r];
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
      // every region on the phone, partly downloaded ones too, each with what is ready and what is not
      for (final r in regions.local)
        if (!r.isArea) SetupItem(r.name, regionSetupValue(r, age: age(r.fetchedAt))),
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
