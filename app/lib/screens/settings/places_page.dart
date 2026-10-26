import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../weather/places.dart';
import 'deps.dart';
import 'widgets.dart';

/// Settings > Weather and alerts > Places: a checklist of where weather, alerts and fires are kept.
class PlacesPage extends StatefulWidget {
  const PlacesPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<PlacesPage> createState() => _PlacesPageState();
}

class _PlacesPageState extends State<PlacesPage> {
  List<WatchPlace>? _places;

  @override
  void initState() {
    super.initState();
    widget.deps.location.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.deps.location.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final p = await widget.deps.hub.weather.placeChoices();
    if (mounted) setState(() => _places = p);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.deps.hub.settings;
    final places = _places;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => SettingsPage(
        title: 'Places',
        children: [
          const NoteText('Weather, alerts and fires are kept for these places.'),
          if (places != null)
            SettingsGroup(
              rows: [
                for (final p in places)
                  SettingsRow(
                    key: ValueKey('place-${p.id}'),
                    title: p.name,
                    status: [Part(p.subtitle)],
                    onTap: () => s.setWatched(p.id, !s.watchedPlaces.contains(p.id)),
                    trailing: CheckSquare(label: p.name, checked: s.watchedPlaces.contains(p.id)),
                  ),
              ],
            ),
          const NoteText('Save a place on the map to add it here.'),
        ],
      ),
    );
  }
}

/// The square tick box at the end of a row. The row is what is tapped.
class CheckSquare extends StatelessWidget {
  const CheckSquare({super.key, required this.label, required this.checked});

  final String label;
  final bool checked;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      label: label,
      checked: checked,
      child: ExcludeSemantics(
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: checked ? k.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: checked ? k.accent : k.secondary, width: 2),
          ),
          child: checked ? Icon(Icons.check, size: 18, color: k.background) : null,
        ),
      ),
    );
  }
}
