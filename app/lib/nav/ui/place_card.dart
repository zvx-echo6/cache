import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../browse/place_about.dart';
import '../../maps/area_tap.dart' show AreaCardInfo;
import '../../maps/map_tap.dart' show kPoiMatched;
import '../../maps/ui/map_widgets.dart';
import '../../screens/settings/places_page.dart' show confirmRemovePlace;
import '../../theme.dart';
import '../hours_text.dart';
import '../nav_state.dart';
import '../point_facts/point_facts.dart';
import '../units.dart';
import 'place_card_facts.dart';
import 'search_panel.dart';

/// What is known about the selected place or dropped pin, and what to do with it: directions, save, add to Home.
class PlaceCard extends StatelessWidget {
  const PlaceCard({super.key, required this.nav, required this.place, required this.fmt, required this.onClose, this.about, this.maxHeight, this.onOpenEntry, this.area, this.facts});

  final NavState nav;
  final MapPlace place;
  final Fmt fmt;
  final VoidCallback onClose;

  /// "Read about it": the place's Wikipedia article in the reader; null leaves the button out.
  final PlaceAbout? about;

  /// The most the card may take (the map's side column); null: 55% of the window, as a bottom card.
  final double? maxHeight;

  /// The place is an entry of a Places notebook: Open, as on the notebook pin's sheet, opens that entry. Null leaves it out.
  final VoidCallback? onOpenEntry;

  /// The place is a tapped town or county of the region catalogue: its facts, and whether it has Directions (a county has none).
  final AreaCardInfo? area;

  /// Where the card looks up the elevation and the land manager of its point; null leaves those rows out.
  final PointFacts? facts;

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final a = area;
    // A tapped area is a place of the whole map, not a point: no distance from the phone.
    final dist = a == null ? distanceLine(nav, fmt, place) : null;
    final isPin = place.matched == 'pin' || place.isCoordinates;
    final saved = nav.savedFor(place);
    final hours = hoursViewFor(place, use24h: MediaQuery.alwaysUse24HourFormatOf(context));
    final detail = <Widget>[
      if (place.address.isNotEmpty)
        _line(context, Icons.place_outlined, place.address),
      if (a?.people != null) _line(context, Icons.groups_outlined, a!.people!),
      if (a?.squareArea != null) _line(context, Icons.square_foot, a!.squareArea!),
      if (a?.largestTowns != null) _line(context, Icons.location_city, a!.largestTowns!),
      if (place.phone != null)
        ActionLine(key: const ValueKey('place-phone'), icon: Icons.phone_outlined, text: place.phone!, hint: 'Call', onTap: () => callPhone(context, place.phone!), copyText: place.phone!, copyLabel: 'Copy number'),
      if (hours != null) _hoursLine(context, hours),
      if (place.website != null)
        ActionLine(key: const ValueKey('place-website'), icon: Icons.public, text: place.website!, hint: 'Open website', onTap: () => openWebsite(context, place.website!), copyText: place.website!, copyLabel: 'Copy link'),
    ];
    return Container(
      // Fully solid: at 0.98 the map's labels and chips showed faintly through the title.
      decoration: mapPanel(context, radius: 20),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight == null ? MediaQuery.sizeOf(context).height * 0.55 : (maxHeight! - 26).clamp(120.0, double.infinity)),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(place.name, key: const ValueKey('place-card-name'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: k.text)),
                          const SizedBox(height: 2),
                          Text(
                            [if (place.kind.isNotEmpty) place.kind, ?dist].join(' · '),
                            style: TextStyle(fontSize: 16, color: k.secondary),
                          ),
                        ],
                      ),
                    ),
                    IconButton(tooltip: 'Close', icon: Icon(Icons.close, color: k.secondary), onPressed: onClose),
                  ],
                ),
                if (isPin) ...[
                  const SizedBox(height: 8),
                  for (final e in _pinFormats(place))
                    Semantics(
                      button: true,
                      label: '${e.$1} ${e.$2}, tap to copy',
                      child: InkWell(
                        onTap: () => _copy(context, e.$2),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(width: 78, child: Text(e.$1, style: TextStyle(fontSize: 14, color: k.secondary))),
                              Expanded(child: Text(e.$2, style: TextStyle(fontSize: 16, color: k.text))),
                              Icon(Icons.copy, size: 16, color: k.secondary),
                              const SizedBox(width: 8),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
                // A point or a place (not a whole town or county): its elevation, and who manages the land there.
                if (a == null && facts != null) ...[
                  const SizedBox(height: 6),
                  PointFactRows(key: ValueKey('point-facts-${place.lat}-${place.lon}'), facts: facts!, lat: place.lat, lon: place.lon, fmt: fmt),
                ],
                if (detail.isNotEmpty) ...[const SizedBox(height: 6), ...detail],
                if (place.matched == kPoiMatched && detail.isEmpty && place.summary == null) ...[
                  const SizedBox(height: 8),
                  Text('No other details for this place.', key: const ValueKey('place-card-no-details'), style: TextStyle(fontSize: 14, color: k.secondary)),
                ],
                if (place.summary != null) ...[
                  const SizedBox(height: 8),
                  // Three lines; "Read about it" is the way to the whole text, so the card never outgrows its height.
                  Text(aboutSummary(place.summary!), key: const ValueKey('place-card-summary'), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, height: 1.35, color: k.text)),
                  if (place.wikipediaTitle != null && about != null)
                    ReadAbout(key: ValueKey('read-about-${place.id}'), about: about!, title: place.wikipediaTitle!)
                  else if (place.wikipediaTitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Wikipedia: ${place.wikipediaTitle}', style: TextStyle(fontSize: 13, color: k.secondary)),
                    ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    // A county has no Directions: it is an area, not somewhere to drive to.
                    if (a?.directions ?? true)
                      Expanded(
                        flex: 5,
                        child: FilledButton.icon(
                          key: const ValueKey('place-directions'),
                          onPressed: nav.available ? () => nav.openDirections(place) : null,
                          icon: const Icon(Icons.directions),
                          label: const Text('Directions'),
                        ),
                      ),
                    // A place from a Places notebook is in that notebook already: no Save for it.
                    if (!place.isNotebookPlace) ...[
                    if (a?.directions ?? true) const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: saved == null
                          ? OutlinedButton(
                              key: const ValueKey('place-save'),
                              onPressed: () => nav.savePlace(place),
                              child: const Text('Save place'),
                            )
                          : OutlinedButton(
                              key: const ValueKey('place-remove'),
                              onPressed: () async {
                                if (await confirmRemovePlace(context, saved.name)) await nav.removePlace(saved);
                              },
                              child: const Text('Remove place'),
                            ),
                    ),
                    ],
                  ],
                ),
                if (onOpenEntry != null) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      key: const ValueKey('place-open-entry'),
                      onPressed: onOpenEntry,
                      child: const Text('Open'),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const ValueKey('place-add-home'),
                    onPressed: () => nav.addToHome(place),
                    icon: const Icon(Icons.add_home_outlined),
                    label: const Text('Add to Home'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, String text) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: k.secondary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(fontSize: 16, color: k.text))),
        ],
      ),
    );
  }

  /// The opening hours: "Open now" or "Closed now" first, only when it is known for sure, then the hours in plain words (or the
  /// value as the places data has it, when it is more than a weekly pattern).
  Widget _hoursLine(BuildContext context, HoursView h) {
    final k = context.t;
    final open = h.openNow;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.schedule, size: 20, color: k.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              key: const ValueKey('place-card-hours'),
              TextSpan(
                style: TextStyle(fontSize: 16, color: k.text),
                children: [
                  if (open != null) TextSpan(text: open ? 'Open now' : 'Closed now', style: TextStyle(fontWeight: FontWeight.w700, color: open ? k.ok : k.secondary)),
                  if (open != null) const TextSpan(text: ' · '),
                  TextSpan(text: h.text),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The formats of a point, in the order a person reaches for them.
  static List<(String, String)> _pinFormats(MapPlace p) {
    const labels = [('decimal', 'Decimal'), ('dms', 'DMS'), ('usng', 'USNG'), ('plus_code', 'Plus Code')];
    return [for (final l in labels) if (p.formats[l.$1] != null) (l.$2, p.formats[l.$1]!)];
  }
}

/// A place's summary as the card shows it: at most 400 characters (the places data keeps only summaries that fit, S14), cut at a word
/// with an ellipsis if one ever is longer.
String aboutSummary(String s, {int max = 400}) {
  final t = s.trim();
  if (t.length <= max) return t;
  final cut = t.lastIndexOf(' ', max - 1);
  return '${t.substring(0, cut > max ~/ 2 ? cut : max - 1).trimRight()}…';
}

/// "Read about it" under a place's summary. The article is looked up when the card opens: in the phone's Wikipedia, the button;
/// no Wikipedia on the phone, "Get Wikipedia" with a line saying so; a Wikipedia without the article, nothing (the card is just
/// shorter). A press says "Opening…" until the reader is up; an article gone since the lookup says so, with Open Library.
class ReadAbout extends StatefulWidget {
  const ReadAbout({super.key, required this.about, required this.title});

  final PlaceAbout about;
  final String title;

  @override
  State<ReadAbout> createState() => _ReadAboutState();
}

class _ReadAboutState extends State<ReadAbout> {
  ({AboutState state, String? address})? _found;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    widget.about.lookUp(widget.title).then((f) {
      if (mounted) setState(() => _found = f);
    }).catchError((_) {});
  }

  Future<void> _open(String address) async {
    final m = ScaffoldMessenger.of(context);
    setState(() => _opening = true);
    try {
      await widget.about.open(address);
    } catch (_) {
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(
        content: const Text('That article is not in your Wikipedia. Update Wikipedia in Library.'),
        action: SnackBarAction(label: 'Open Library', onPressed: widget.about.openLibrary),
      ));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _found;
    if (f == null || f.state == AboutState.missing) return const SizedBox.shrink();
    final k = context.t;
    if (f.state == AboutState.noWikipedia) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, right: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('place-get-wikipedia'),
              onPressed: widget.about.getWikipedia,
              icon: const Icon(Icons.download),
              label: const Text('Get Wikipedia'),
            ),
            const SizedBox(height: 4),
            Text('Wikipedia is not on this device.', key: const ValueKey('place-no-wikipedia'), style: TextStyle(fontSize: 13, color: k.secondary)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 8),
      child: OutlinedButton.icon(
        key: const ValueKey('place-read-about'),
        onPressed: _opening ? null : () => _open(f.address!),
        icon: _opening
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.menu_book_outlined),
        label: Text(_opening ? 'Opening…' : 'Read about it'),
      ),
    );
  }
}
