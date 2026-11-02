import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'notebook_model.dart';

/// Where the Notebooks screens get places from: the phone's fix ("Here"), the saved places and the map's place search.
class PlaceChoices {
  const PlaceChoices({required this.here, required this.saved, this.search});

  /// The phone's position now, or null without a fix. Asking may show the location prompt.
  final Future<({double lat, double lon})?> Function() here;
  final Future<List<NbPlace>> Function() saved;

  /// The map's search box, when the map search is available.
  final Future<List<NbPlace>> Function(String query)? search;

  /// "Here": the fix, named after the nearest saved place within 200 m (else shown as coordinates).
  Future<NbPlace?> herePlace() async {
    final h = await here();
    if (h == null) return null;
    NbPlace? best;
    var bestM = 200.0;
    for (final p in await saved().catchError((_) => <NbPlace>[])) {
      final d = distanceM(h.lat, h.lon, p.lat, p.lon);
      if (d <= bestM) {
        bestM = d;
        best = p;
      }
    }
    return NbPlace(lat: h.lat, lon: h.lon, label: best?.label, key: best?.key);
  }

  /// No places at all (tests).
  static const none = PlaceChoices(here: _noFix, saved: _noSaved);
  static Future<({double lat, double lon})?> _noFix() async => null;
  static Future<List<NbPlace>> _noSaved() async => const [];
}

/// Metres between two points (haversine).
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a.toDouble()));
}

/// "300 ft", "3 mi" (miles and feet; the Places notebooks' "Nearest first" line).
String distanceText(double m) {
  final mi = m / 1609.344;
  if (mi < 0.1) return '${(m * 3.28084).round()} ft';
  if (mi < 10) return '${mi.toStringAsFixed(1)} mi';
  return '${mi.round()} mi';
}

/// What the place picker answers: a place, or "No place" (cleared). Null from the sheet means nothing changed.
class PlacePick {
  const PlacePick(this.place);

  final NbPlace? place;
}

/// The place picker: Here, the saved places, a search, and No place.
Future<PlacePick?> pickPlace(BuildContext context, PlaceChoices choices) => showModalBottomSheet<PlacePick>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _PlaceSheet(choices: choices),
    );

class _PlaceSheet extends StatefulWidget {
  const _PlaceSheet({required this.choices});

  final PlaceChoices choices;

  @override
  State<_PlaceSheet> createState() => _PlaceSheetState();
}

class _PlaceSheetState extends State<_PlaceSheet> {
  List<NbPlace> _saved = const [];
  List<NbPlace> _found = const [];
  bool _searching = false;
  bool _noFix = false;

  @override
  void initState() {
    super.initState();
    widget.choices.saved().then((s) {
      if (mounted) setState(() => _saved = s);
    }).catchError((_) {});
  }

  Future<void> _search(String q) async {
    final s = widget.choices.search;
    if (s == null || q.trim().isEmpty) return;
    setState(() => _searching = true);
    try {
      final r = await s(q.trim());
      if (mounted) setState(() => _found = r);
    } catch (_) {
      if (mounted) setState(() => _found = const []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _here() async {
    final p = await widget.choices.herePlace();
    if (!mounted) return;
    if (p == null) {
      setState(() => _noFix = true);
      return;
    }
    Navigator.pop(context, PlacePick(p));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    Widget row(NbPlace p, {IconData icon = Icons.place_outlined}) => ListTile(
          minTileHeight: 52,
          leading: Icon(icon, color: k.secondary),
          title: Text(p.display, style: const TextStyle(fontSize: 17)),
          onTap: () => Navigator.pop(context, PlacePick(p)),
        );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: [
            ListTile(
              key: const ValueKey('place-here'),
              minTileHeight: 52,
              leading: Icon(Icons.my_location, color: k.accent),
              title: const Text('Here', style: TextStyle(fontSize: 17)),
              subtitle: _noFix ? Text('No position yet', style: TextStyle(color: k.secondary)) : null,
              onTap: _here,
            ),
            if (widget.choices.search != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: TextField(
                  key: const ValueKey('place-search'),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search places',
                    prefixIcon: const Icon(Icons.search),
                    suffix: _searching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null,
                  ),
                  onSubmitted: _search,
                ),
              ),
            for (final p in _found) row(p),
            if (_saved.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('SAVED PLACES', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.secondary)),
              ),
            for (final p in _saved) row(p, icon: Icons.bookmark_outline),
            ListTile(
              key: const ValueKey('place-none'),
              minTileHeight: 52,
              leading: Icon(Icons.location_off_outlined, color: k.secondary),
              title: const Text('No place', style: TextStyle(fontSize: 17)),
              onTap: () => Navigator.pop(context, const PlacePick(null)),
            ),
          ],
        ),
      ),
    );
  }
}
