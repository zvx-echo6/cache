/// One switch on the Weather and alerts page: a short name for what the person gets, and the catalogue sources behind it.
class CuratedRow {
  const CuratedRow({required this.title, required this.detail, required this.ids, this.keyed = false});

  /// The name of the switch.
  final String title;

  /// What it gives, before the provider's name.
  final String detail;

  /// The source ids it switches together (a catalogue's ids; a built-in source stands in for one it is replaced by).
  final List<String> ids;

  /// The sources need the person's own key (this decides the group while the catalogue is not loaded).
  final bool keyed;
}

/// The curated set on the main page, by catalogue id (cache-packs, branch connectors): weather and its alerts from the two sources
/// that cover the most places, the fires and quakes, the rivers, avalanches, and the one key-only source people ask for. Everything
/// else is under All data sources.
const List<CuratedRow> kCurated = [
  CuratedRow(title: 'Weather forecast', detail: '16 days ahead', ids: ['openmeteo-forecast']),
  CuratedRow(title: 'Weather alerts', detail: 'Warnings and watches', ids: ['nws-alerts-point']),
  CuratedRow(title: 'Wildfires', detail: 'Fires and their edges', ids: ['wfigs-incidents-near', 'wfigs-perimeters-near']),
  CuratedRow(title: 'Earthquakes', detail: 'Recent and nearby', ids: ['usgs-quakes-near']),
  CuratedRow(title: 'River levels', detail: 'River gauges and flood stage', ids: ['nwps-gauges-near']),
  CuratedRow(title: 'Avalanche', detail: 'Danger rating and advice', ids: ['avalanche-forecast-zones']),
  CuratedRow(title: 'Satellite fire hotspots', detail: 'New fires, often hours before reports', ids: ['firms-viirs-near'], keyed: true),
];
