import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../maps/ui/map_widgets.dart';
import '../../theme.dart';
import '../nav_state.dart';
import '../units.dart';

/// The Maps tab's one search bar. It takes a place name, a kind of place, coordinates in any format, or a few words about what
/// is needed, and lists answers as you type.
class NavSearchBar extends StatefulWidget {
  const NavSearchBar({super.key, required this.nav, required this.fmt});

  final NavState nav;
  final Fmt fmt;

  @override
  State<NavSearchBar> createState() => _NavSearchBarState();
}

class _NavSearchBarState extends State<NavSearchBar> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  NavState get nav => widget.nav;

  @override
  void initState() {
    super.initState();
    nav.addListener(_sync);
    _focus.addListener(() {
      if (_focus.hasFocus) nav.openSearch();
    });
  }

  @override
  void dispose() {
    nav.removeListener(_sync);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The field follows the state when something else changes it (a result was chosen, the search was closed).
  void _sync() {
    if (_text.text != nav.query) {
      _text.value = TextEditingValue(text: nav.query, selection: TextSelection.collapsed(offset: nav.query.length));
    }
    if (!nav.searchOpen && _focus.hasFocus) _focus.unfocus();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final open = nav.searchOpen;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: mapPanel(context, radius: 28, alpha: 0.97),
          child: Row(
            children: [
              if (open || nav.query.isNotEmpty)
                IconButton(
                  tooltip: 'Close search',
                  icon: Icon(Icons.arrow_back, color: k.text),
                  onPressed: () => nav.closeSearch(),
                )
              else
                Padding(padding: const EdgeInsets.only(left: 16, right: 8), child: Icon(Icons.search, color: k.secondary)),
              Expanded(
                child: TextField(
                  key: const ValueKey('map-search-field'),
                  controller: _text,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  onChanged: nav.onQueryChanged,
                  onSubmitted: (_) => nav.submitSearch(),
                  style: TextStyle(fontSize: 18, color: k.text),
                  cursorColor: k.accent,
                  decoration: InputDecoration(
                    hintText: 'Search places or coordinates',
                    hintStyle: TextStyle(fontSize: 18, color: k.secondary),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              if (nav.query.isNotEmpty)
                IconButton(
                  tooltip: 'Clear',
                  icon: Icon(Icons.close, color: k.secondary),
                  onPressed: () {
                    nav.onQueryChanged('');
                    _focus.requestFocus();
                  },
                )
              else
                const SizedBox(width: 8),
            ],
          ),
        ),
        if (open && nav.query.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          // The list takes what the screen has left above the keyboard (the Maps screen leaves room for it).
          Flexible(
            child: Container(
              decoration: mapPanel(context, radius: 16, alpha: 0.97),
              clipBehavior: Clip.antiAlias,
              child: _results(context),
            ),
          ),
        ],
      ],
    );
  }

  Widget _results(BuildContext context) {
    final k = context.t;
    final rows = nav.results;
    final children = <Widget>[
      if (nav.searching) LinearProgressIndicator(minHeight: 2, color: k.accent, backgroundColor: Colors.transparent),
      if (nav.searchError != null)
        Padding(padding: const EdgeInsets.all(16), child: Text(nav.searchError!, style: TextStyle(fontSize: 16, color: k.emergency))),
      if (rows.isEmpty && !nav.searching && nav.searchError == null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Nothing found for "${nav.query.trim()}"', style: TextStyle(fontSize: 16, color: k.secondary)),
        ),
      for (final p in rows) _ResultRow(place: p, nav: nav, fmt: widget.fmt),
      if (nav.searchNote != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(nav.searchNote!, style: TextStyle(fontSize: 13, color: k.secondary)),
        ),
    ];
    return ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: children);
  }
}

IconData iconForPlace(MapPlace p) {
  if (p.isCategory) return Icons.category_outlined;
  if (p.isCoordinates) return Icons.pin_drop_outlined;
  if (p.type == 'town') return Icons.location_city_outlined;
  return switch (p.category) {
    'pharmacy' => Icons.local_pharmacy_outlined,
    'hospital' || 'emergency_room' || 'urgent_care' => Icons.local_hospital_outlined,
    'fuel' => Icons.local_gas_station_outlined,
    'water' => Icons.water_drop_outlined,
    'police' => Icons.local_police_outlined,
    'fire_station' => Icons.fire_truck_outlined,
    'campground' => Icons.cabin_outlined,
    'trailhead' => Icons.hiking,
    'shelter' => Icons.home_work_outlined,
    _ => Icons.place_outlined,
  };
}

/// "0.4 mi NE" from the phone when its position is known, else from where the search was centred.
String? distanceLine(NavState nav, Fmt fmt, MapPlace p) {
  final here = nav.here;
  if (here != null) {
    final d = nav.distanceFromHere(p)!;
    return '${fmt.distance(d)} ${compass8(bearingBetween(here.lat, here.lon, p.lat, p.lon))}';
  }
  if (p.distanceM != null) return '${fmt.distance(p.distanceM!)}${p.direction == null ? '' : ' ${p.direction}'}';
  return null;
}

double bearingBetween(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final dl = rad(lon2 - lon1);
  final y = math.sin(dl) * math.cos(rad(lat2));
  final x = math.cos(rad(lat1)) * math.sin(rad(lat2)) - math.sin(rad(lat1)) * math.cos(rad(lat2)) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

String compass8(double deg) => const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][(((deg % 360) + 22.5) ~/ 45) % 8];

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.place, required this.nav, required this.fmt});

  final MapPlace place;
  final NavState nav;
  final Fmt fmt;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final dist = place.isCategory ? null : distanceLine(nav, fmt, place);
    final sub = place.isCategory
        ? 'All nearby'
        : [place.kind, if (place.address.isNotEmpty) place.address].join(' · ');
    return InkWell(
      onTap: () => nav.select(place),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(iconForPlace(place), color: k.accent, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(place.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                    if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
                  ],
                ),
              ),
              if (dist != null) ...[
                const SizedBox(width: 10),
                Text(dist, style: TextStyle(fontSize: 14, color: k.secondary)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
