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

  Future<void> _remove(WatchPlace p) async {
    if (!await confirmRemovePlace(context, p.name)) return;
    try {
      await widget.deps.hub.weather.removePlace(p);
    } catch (_) {
      if (mounted) say(context, 'Could not remove the place');
    }
    await _load();
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
                    trailing: p.kind == PlaceKind.saved
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                key: ValueKey('remove-${p.id}'),
                                tooltip: 'Remove place',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _remove(p),
                              ),
                              CheckSquare(label: p.name, checked: s.watchedPlaces.contains(p.id)),
                            ],
                          )
                        : CheckSquare(label: p.name, checked: s.watchedPlaces.contains(p.id)),
                  ),
              ],
            ),
          const NoteText('Save a place on the map to add it here.'),
        ],
      ),
    );
  }
}

/// Asks before a saved place is removed. True when the person said Remove.
Future<bool> confirmRemovePlace(BuildContext context, String name) async => await showDialog<bool>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text('Remove $name?'),
    content: const Text('It is taken off your saved places, and its weather and alerts are no longer kept.'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
      TextButton(key: const ValueKey('confirm-remove-place'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
    ],
  ),
) == true;

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
