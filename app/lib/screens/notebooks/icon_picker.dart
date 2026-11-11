import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../notebook/map_icons.dart';
import '../../notebook/notebook_model.dart' show NbEntry;
import '../../notebook/place_style.dart';
import '../../notebook/pin_image.dart' show glyphOn;
import '../../theme.dart';

/// What the screens need to offer map icons (null leaves the icon controls out, as before): the icons chosen lately, and what to do
/// when the icon of a place that is only being viewed changes (the view saves it at once; the edit screens save with Save).
class MapIconSetup {
  const MapIconSetup({required this.recent, this.onPlaceIcon});

  final RecentIcons recent;
  final void Function(NbEntry place, String? icon)? onPlaceIcon;
}

/// [own] on the light and dark themes; the red of the theme in Tactical (red only).
Color iconTint(BuildContext context, Color own) {
  final k = context.t;
  return k.accent == cacheTokens[CacheThemeId.tactical]!.accent ? k.accent : own;
}

/// What the icon picker answers: an icon, or (id null) the reset: "Use notebook icon" on a place, "Use default icon" on a
/// notebook. Null from the sheet means nothing changed.
class IconPick {
  const IconPick(this.id);

  final String? id;
}

/// The icon picker: a search box, "Use notebook icon" (when opened from a place), the icons last chosen, then every icon, each
/// with a short caption (and its name on press and hold). [current] is the icon chosen now (null: none of its own), [tint] the
/// colour the chosen icon is drawn in.
Future<IconPick?> showIconPicker(
  BuildContext context, {
  required String? current,
  required RecentIcons recent,
  required Color tint,
  String? resetLabel,
  String? resetIcon,
  String? resetFrom,
}) =>
    showModalBottomSheet<IconPick>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (ctx) => IconPicker(current: current, recent: recent, tint: tint, resetLabel: resetLabel, resetIcon: resetIcon, resetFrom: resetFrom),
    );

class IconPicker extends StatefulWidget {
  const IconPicker({super.key, required this.current, required this.recent, required this.tint, this.resetLabel, this.resetIcon, this.resetFrom});

  final String? current;
  final RecentIcons recent;
  final Color tint;

  /// The reset row ("Use notebook icon"), its icon id, and where that icon comes from ("Pin, from Trail places").
  final String? resetLabel;
  final String? resetIcon;
  final String? resetFrom;

  @override
  State<IconPicker> createState() => _IconPickerState();
}

class _IconPickerState extends State<IconPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final found = searchMapIcons(_q);
    final searching = _q.trim().isNotEmpty;
    final recent = [for (final id in widget.recent.ids) mapIconOrTemplate(id)];
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.secondary)),
        );
    SliverGrid grid(List<MapIcon> icons, String keyBase) => SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 84, mainAxisExtent: 76),
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => _Cell(key: ValueKey('$keyBase-${icons[i].id}'), icon: icons[i], selected: icons[i].id == widget.current, tint: widget.tint),
            childCount: icons.length,
          ),
        );
    return SizedBox(
      height: math.min(MediaQuery.sizeOf(context).height * 0.82, 680),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(alignment: Alignment.centerLeft, child: Text('Choose an icon', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: k.text))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: TextField(
              key: const ValueKey('icon-search'),
              decoration: const InputDecoration(hintText: 'Search icons: water, fire, radio', prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          if (widget.resetLabel != null && !searching)
            ListTile(
              key: const ValueKey('icon-reset'),
              minTileHeight: 56,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: _Disc(icon: mapIconOrTemplate(widget.resetIcon).icon, tint: widget.tint, filled: widget.current == null, size: 36),
              title: Text(widget.resetLabel!, style: const TextStyle(fontSize: 17)),
              subtitle: widget.resetFrom == null ? null : Text(widget.resetFrom!, style: TextStyle(color: k.secondary)),
              trailing: widget.current == null ? Icon(Icons.check, color: k.accent) : null,
              onTap: () => Navigator.pop(context, const IconPick(null)),
            ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                if (!searching && recent.isNotEmpty) ...[
                  SliverToBoxAdapter(child: header('RECENT')),
                  SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 8), sliver: grid(recent, 'recent')),
                ],
                SliverToBoxAdapter(child: header(searching ? (found.length == 1 ? '1 ICON' : '${found.length} ICONS') : 'ALL ICONS')),
                if (found.isEmpty)
                  SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), child: Text('No icon has that name. Try a shorter word.', style: TextStyle(color: k.secondary))))
                else
                  SliverPadding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 24), sliver: grid(found, 'icon')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({super.key, required this.icon, required this.selected, required this.tint});

  final MapIcon icon;
  final bool selected;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      button: true,
      selected: selected,
      label: icon.label,
      excludeSemantics: true,
      onTap: () => Navigator.pop(context, IconPick(icon.id)),
      child: Tooltip(
        message: icon.label,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.pop(context, IconPick(icon.id)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
            child: Column(
              children: [
                _Disc(icon: icon.icon, tint: tint, filled: selected, size: 40),
                const SizedBox(height: 4),
                Text(icon.label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: selected ? k.text : k.secondary, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An icon on a disc: filled in [tint] (with the icon in black or white) when [filled], else a plain ring with the icon in the
/// text colour.
class _Disc extends StatelessWidget {
  const _Disc({required this.icon, required this.tint, required this.filled, required this.size});

  final IconData icon;
  final Color tint;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? tint : Colors.transparent,
        border: filled ? null : Border.all(color: k.text.withValues(alpha: 0.6), width: 1.2),
      ),
      child: Icon(icon, size: size * 0.6, fill: filled ? 1 : 0, weight: filled ? 500 : 400, color: filled ? glyphOn(tint) : k.text),
    );
  }
}

/// A place's own icon, small and tappable, on the place's view and edit screens: filled in the place's colour when the place has
/// an icon of its own, a plain ring with the notebook's icon when it does not. A tap opens the picker; "Use notebook icon" there
/// sends [onChanged] null.
class PlaceIconButton extends StatelessWidget {
  const PlaceIconButton({
    super.key,
    required this.overrideId,
    required this.notebookIconId,
    required this.notebookName,
    required this.tint,
    required this.recent,
    required this.onChanged,
  });

  /// The place's own icon, or null.
  final String? overrideId;
  final String notebookIconId;
  final String notebookName;
  final Color tint;
  final RecentIcons recent;
  final ValueChanged<String?> onChanged;

  MapIcon get shown => mapIconOrTemplate(overrideId ?? notebookIconId);

  Future<void> _open(BuildContext context) async {
    final pick = await showIconPicker(
      context,
      current: overrideId,
      recent: recent,
      tint: tint,
      resetLabel: 'Use notebook icon',
      resetIcon: notebookIconId,
      resetFrom: '${mapIconOrTemplate(notebookIconId).label}, from $notebookName',
    );
    if (pick != null) onChanged(pick.id);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      button: true,
      label: 'Place icon: ${shown.label}${overrideId == null ? ', from the notebook' : ''}. Change',
      excludeSemantics: true,
      onTap: () => _open(context),
      child: InkResponse(
        key: const ValueKey('place-icon'),
        radius: 26,
        onTap: () => _open(context),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _Disc(icon: shown.icon, tint: tint, filled: overrideId != null, size: 38),
              Positioned(
                right: 3,
                bottom: 3,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: k.surface, border: Border.all(color: k.secondary, width: 1)),
                  child: Icon(Icons.edit, size: 10, color: k.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The notebook settings' "Map icon" row: the icon in the notebook's colour, its name, and the picker on a tap ("Use default
/// icon" there sends [onChanged] null).
class MapIconRow extends StatelessWidget {
  const MapIconRow({super.key, required this.iconId, required this.defaultId, required this.tint, required this.recent, required this.onChanged});

  final String? iconId;
  final String defaultId;
  final Color tint;
  final RecentIcons recent;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final shown = mapIconOrTemplate(iconId ?? defaultId);
    return ListTile(
      key: const ValueKey('notebook-icon'),
      contentPadding: EdgeInsets.zero,
      minTileHeight: 56,
      leading: _Disc(icon: shown.icon, tint: tint, filled: true, size: 40),
      title: const Text('Map icon'),
      subtitle: Text(iconId == null ? '${shown.label} (default)' : shown.label, style: TextStyle(fontSize: 14, color: k.secondary)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final pick = await showIconPicker(
          context,
          current: iconId,
          recent: recent,
          tint: tint,
          resetLabel: 'Use default icon',
          resetIcon: defaultId,
          resetFrom: mapIconOrTemplate(defaultId).label,
        );
        if (pick != null) onChanged(pick.id);
      },
    );
  }
}

/// The notebook settings' "Pin color" row: the seven marker colours as swatches. A new place of the notebook starts with it; a
/// place can have its own.
class NotebookColorRow extends StatelessWidget {
  const NotebookColorRow({super.key, required this.colorId, required this.onChanged});

  final String? colorId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final chosen = markerColor(colorId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('Pin color', style: TextStyle(fontSize: 16, color: k.text)),
        Text('Its places start with this color. A place can have its own.', style: TextStyle(fontSize: 14, color: k.secondary)),
        Wrap(
          children: [
            for (final c in kMarkerColors)
              Semantics(
                button: true,
                selected: c.id == chosen.id,
                label: c.spoken,
                onTap: () => onChanged(c.id),
                excludeSemantics: true,
                child: InkResponse(
                  key: ValueKey('nb-color-${c.id}'),
                  radius: 22,
                  onTap: () => onChanged(c.id),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: c.color,
                          shape: BoxShape.circle,
                          border: Border.all(color: c.id == chosen.id ? k.text : Colors.transparent, width: 2.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
