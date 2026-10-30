import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter/material.dart';

import '../location/location_service.dart';
import '../settings/app_settings.dart' show kWatchHere;
import '../theme.dart';
import '../weather/curated.dart';
import '../weather/places.dart';
import '../weather/weather_state.dart';

/// "Turn on weather" in one step, from the Weather screen and Home: the forecast, alerts and wildfires for where the phone is,
/// or for a place the person chooses when the location cannot be used. Settings > Weather and alerts stays the place for the rest.
class WeatherTurnOn {
  const WeatherTurnOn({required this.weather, this.location, this.searchPlaces, this.savePlace});

  final WeatherState weather;

  /// The phone's location; without it "Turn on weather" goes straight to choosing a place.
  final LocationService? location;

  /// Finds places by name (the map's search); null when there is no place search, and only saved places can be chosen.
  final Future<List<MapPlace>> Function(String query)? searchPlaces;

  /// Saves a found place to the saved places, so it can be watched.
  final Future<void> Function(MapPlace place)? savePlace;

  /// The switches it turns on: Weather forecast, Weather alerts and Wildfires.
  static List<CuratedRow> get rows => [
    for (final title in const ['Weather forecast', 'Weather alerts', 'Wildfires']) kCurated.firstWhere((r) => r.title == title),
  ];

  Future<void> switchOn() async {
    for (final r in rows) {
      if (!weather.rowIsOn(r)) await weather.setRowOn(r, true);
    }
  }
}

/// Switches weather, alerts and wildfires on for "Where I am", asks for the location the usual way, and updates. When the
/// location cannot be used, it offers to choose a place instead.
Future<void> turnOnWeather(BuildContext buttonContext, WeatherTurnOn t) async {
  // The button goes away once weather is on, so the steps after it use the screen's overlay, which stays.
  final context = _lasting(buttonContext);
  await t.switchOn();
  t.weather.settings.setWatched(kWatchHere, true);
  final loc = t.location;
  var located = loc?.fix != null;
  if (!located && loc != null && context.mounted) {
    var explained = false;
    if (!loc.enabled) {
      if (!await _explainLocation(context)) {
        if (context.mounted) await chooseWeatherPlace(context, t, why: 'Location is off. Choose a place instead.');
        return;
      }
      await loc.setEnabled(true);
      explained = true;
    }
    if (!context.mounted) return;
    located = await loc.request(explain: explained ? () async => true : () => _explainLocation(context));
  }
  if (!context.mounted) return;
  if (!located) {
    await chooseWeatherPlace(context, t, why: 'Cache could not use your location. Choose a place instead.');
    return;
  }
  await _update(context, t.weather);
}

/// Lets the person pick a saved place (or a downloaded region), or find one, to watch; then switches weather on and updates.
Future<void> chooseWeatherPlace(BuildContext buttonContext, WeatherTurnOn t, {String? why}) async {
  final context = _lasting(buttonContext);
  final picked = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ChoosePlaceSheet(t: t, why: why),
  );
  if (picked != true || !context.mounted) return;
  await t.switchOn();
  if (context.mounted) await _update(context, t.weather);
}

/// A context that outlives the button that was tapped: the navigator's overlay (under the navigator and the messenger).
BuildContext _lasting(BuildContext context) => Navigator.of(context).overlay?.context ?? context;

Future<bool> _explainLocation(BuildContext context) async => await showDialog<bool>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('Use your location?'),
    content: const Text('Cache uses your location for the weather where you are. You can turn location off in Settings.'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
      TextButton(key: const ValueKey('weather-location-continue'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
    ],
  ),
) == true;

Future<void> _update(BuildContext context, WeatherState w) async {
  final r = await w.updateNow(force: true);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(r.words)));
}

/// The two buttons of the weather's empty states: "Turn on weather" and "Choose a place instead".
class WeatherTurnOnButtons extends StatelessWidget {
  const WeatherTurnOnButtons({super.key, required this.turnOn, this.secondary = true});

  final WeatherTurnOn turnOn;

  /// Shows "Choose a place instead" under the main button.
  final bool secondary;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FilledButton(
        key: const ValueKey('weather-turn-on'),
        onPressed: () => turnOnWeather(context, turnOn),
        child: const Text('Turn on weather'),
      ),
      if (secondary) ...[
        const SizedBox(height: 8),
        OutlinedButton(
          key: const ValueKey('weather-choose-place'),
          onPressed: () => chooseWeatherPlace(context, turnOn),
          child: const Text('Choose a place instead'),
        ),
      ],
    ],
  );
}

class _ChoosePlaceSheet extends StatefulWidget {
  const _ChoosePlaceSheet({required this.t, this.why});

  final WeatherTurnOn t;
  final String? why;

  @override
  State<_ChoosePlaceSheet> createState() => _ChoosePlaceSheetState();
}

class _ChoosePlaceSheetState extends State<_ChoosePlaceSheet> {
  final _query = TextEditingController();
  List<WatchPlace>? _saved;
  List<MapPlace>? _found;
  bool _searching = false;
  String? _error;

  WeatherState get w => widget.t.weather;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final all = await w.placeChoices();
    if (mounted) setState(() => _saved = [for (final p in all) if (p.kind != PlaceKind.here) p]);
  }

  void _watch(WatchPlace p) {
    w.settings.setWatched(p.id, true);
    Navigator.pop(context, true);
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    final search = widget.t.searchPlaces;
    if (q.isEmpty || search == null) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final r = await search(q);
      if (mounted) setState(() => _found = r);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not search for places.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Saves the found place, then watches it.
  Future<void> _pickFound(MapPlace p) async {
    try {
      await widget.t.savePlace!(p);
      final saved = await w.placeChoices();
      final match = saved.where((s) =>
          s.kind == PlaceKind.saved && s.name == p.name && (s.lat! - p.lat).abs() < 1e-5 && (s.lon! - p.lon).abs() < 1e-5);
      if (match.isEmpty) throw StateError('not saved');
      if (mounted) _watch(match.first);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save the place.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final saved = _saved;
    final found = _found;
    final canSearch = widget.t.searchPlaces != null && widget.t.savePlace != null;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text('Choose a place', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: k.text)),
              if (widget.why != null) ...[
                const SizedBox(height: 6),
                Text(widget.why!, key: const ValueKey('weather-place-why'), style: TextStyle(fontSize: 15, color: k.secondary)),
              ],
              const SizedBox(height: 12),
              if (canSearch)
                TextField(
                  key: const ValueKey('weather-place-search'),
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: 'Find a town or place',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searching
                        ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                        : null,
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(fontSize: 15, color: k.emergency)),
                ),
              if (found != null) ...[
                if (found.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('No places match.', style: TextStyle(fontSize: 15, color: k.secondary)),
                  ),
                for (final p in found)
                  ListTile(
                    key: ValueKey('weather-found-${p.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.place_outlined),
                    title: Text(p.name),
                    subtitle: p.address.isEmpty ? null : Text(p.address),
                    onTap: () => _pickFound(p),
                  ),
              ],
              if (saved != null && saved.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Saved places', style: TextStyle(fontSize: 13, letterSpacing: 0.6, color: k.secondary)),
                for (final p in saved)
                  ListTile(
                    key: ValueKey('weather-saved-${p.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(p.kind == PlaceKind.region ? Icons.map_outlined : Icons.bookmark_outline),
                    title: Text(p.name),
                    subtitle: Text(p.subtitle),
                    onTap: () => _watch(p),
                  ),
              ] else if (saved != null && !canSearch)
                Text('No saved places yet. Save one from Maps.', style: TextStyle(fontSize: 15, color: k.secondary)),
            ],
          ),
        ),
      ),
    );
  }
}
