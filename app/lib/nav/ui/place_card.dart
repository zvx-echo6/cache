import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../maps/ui/map_widgets.dart';
import '../../theme.dart';
import '../nav_state.dart';
import '../units.dart';
import 'search_panel.dart';

/// What is known about the selected place or dropped pin, and what to do with it: directions, save, add to Home.
class PlaceCard extends StatelessWidget {
  const PlaceCard({super.key, required this.nav, required this.place, required this.fmt, required this.onClose});

  final NavState nav;
  final MapPlace place;
  final Fmt fmt;
  final VoidCallback onClose;

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final dist = distanceLine(nav, fmt, place);
    final isPin = place.matched == 'pin' || place.isCoordinates;
    final detail = <Widget>[
      if (place.address.isNotEmpty)
        _line(context, Icons.place_outlined, place.address),
      if (place.phone != null) _line(context, Icons.phone_outlined, place.phone!, copy: place.phone),
      if (place.hours != null) _line(context, Icons.schedule, place.hours!),
      if (place.website != null) _line(context, Icons.public, place.website!, copy: place.website),
    ];
    return Container(
      decoration: mapPanel(context, radius: 20, alpha: 0.98),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55),
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
                            [place.kind, ?dist].join(' · '),
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
                if (detail.isNotEmpty) ...[const SizedBox(height: 6), ...detail],
                if (place.summary != null) ...[
                  const SizedBox(height: 8),
                  Text(place.summary!, key: const ValueKey('place-card-summary'), style: TextStyle(fontSize: 15, height: 1.35, color: k.text)),
                  if (place.wikipediaTitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Wikipedia: ${place.wikipediaTitle}', style: TextStyle(fontSize: 13, color: k.secondary)),
                    ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: FilledButton.icon(
                        key: const ValueKey('place-directions'),
                        onPressed: nav.available ? () => nav.openDirections(place) : null,
                        icon: const Icon(Icons.directions),
                        label: const Text('Directions'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: OutlinedButton(
                        key: const ValueKey('place-save'),
                        onPressed: () => nav.savePlace(place),
                        child: const Text('Save place'),
                      ),
                    ),
                  ],
                ),
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

  Widget _line(BuildContext context, IconData icon, String text, {String? copy}) {
    final k = context.t;
    final row = Padding(
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
    return copy == null ? row : InkWell(onTap: () => _copy(context, copy), child: row);
  }

  /// The formats of a point, in the order a person reaches for them.
  static List<(String, String)> _pinFormats(MapPlace p) {
    const labels = [('decimal', 'Decimal'), ('dms', 'DMS'), ('usng', 'USNG'), ('plus_code', 'Plus Code')];
    return [for (final l in labels) if (p.formats[l.$1] != null) (l.$2, p.formats[l.$1]!)];
  }
}
