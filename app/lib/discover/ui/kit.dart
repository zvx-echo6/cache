import 'package:flutter/material.dart';

import '../../maps/ui/format.dart' show formatBytes;
import '../../theme.dart';

/// The small pieces Discover's screens are made of, drawn as the approved mockups draw them ("Discover mockups", 2026-11-08):
/// tiles, big selectable cards, the step dots, the space line, rows in a stack, store tiles and sheet rows.

/// The tile colour behind an icon, and the track and selection colours, as the mockups give them for the light and dark themes
/// (other themes mix them from their own colours).
Color tileColor(CacheTokens k) => _pick(k, const Color(0xFFEFECE6), const Color(0xFF1F2428), 0.06);
Color trackColor(CacheTokens k) => _pick(k, const Color(0xFFE2DFD6), const Color(0xFF454D55), 0.14);
Color selColor(CacheTokens k) => _pick(k, const Color(0xFFEFE0D2), const Color(0xFF3A3F44), 0.10);
Color lineColor(CacheTokens k) => k.text.withValues(alpha: k.background.computeLuminance() > 0.5 ? 0.16 : 0.22);

Color _pick(CacheTokens k, Color light, Color dark, double mix) {
  if (k.background == const Color(0xFFF3EBD9) && k.surface == const Color(0xFFFFFDF8)) return light;
  if (k.background == const Color(0xFF1A1D1F)) return dark;
  return Color.alphaBlend(k.text.withValues(alpha: mix), k.surface);
}

/// The icon a recipe names.
IconData discoverIcon(String name) => switch (name) {
  'shield' => Icons.shield_outlined,
  'peak' => Icons.landscape_outlined,
  'sprout' => Icons.eco_outlined,
  'radio' => Icons.settings_input_antenna,
  'book' => Icons.menu_book_outlined,
  'map' => Icons.map_outlined,
  'stack' => Icons.collections_bookmark_outlined,
  'globe' => Icons.public,
  'pin' => Icons.place_outlined,
  'sliders' => Icons.tune,
  'link' => Icons.devices_outlined,
  'later' => Icons.schedule,
  'welcome' => Icons.waving_hand_outlined,
  _ => Icons.widgets_outlined,
};

/// An icon on its rounded tile: 40 (rows and store tiles), 52 (big cards) or 64 (a page's header).
class DTile extends StatelessWidget {
  const DTile(this.icon, {super.key, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final radius = size >= 64 ? 18.0 : (size >= 52 ? 14.0 : 12.0);
    final iconSize = size >= 64 ? 32.0 : (size >= 52 ? 28.0 : 24.0);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: tileColor(k), borderRadius: BorderRadius.circular(radius)),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: k.accent),
    );
  }
}

/// A round tick mark: filled when on.
class RoundCheck extends StatelessWidget {
  const RoundCheck({super.key, required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? k.primary : null,
        border: Border.all(color: on ? k.primary : k.secondary, width: 2),
      ),
      child: on ? Icon(Icons.check, size: 16, color: k.onPrimary) : null,
    );
  }
}

/// A big selectable card of the wizard: tile, title, line, size, and the tick.
class BigCard extends StatelessWidget {
  const BigCard({super.key, required this.icon, required this.title, required this.line, this.size, required this.selected, required this.onTap});

  final IconData icon;
  final String title;
  final String line;

  /// "10.0 GB" or "+1.6 GB" (accent); null leaves it out.
  final String? size;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: k.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: selected ? k.primary : Colors.transparent, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                DTile(icon, size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                      const SizedBox(height: 2),
                      Text(line, style: TextStyle(fontSize: 13, color: k.secondary)),
                      if (size != null) ...[
                        const SizedBox(height: 2),
                        Text(size!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: k.accent)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                RoundCheck(on: selected),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The wizard's place: a dot per step (done and current filled) and "N of M".
class StepDots extends StatelessWidget {
  const StepDots({super.key, required this.step, required this.of});

  /// 1-based.
  final int step;
  final int of;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      label: 'Step $step of $of',
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 1; i <= of; i++) ...[
              Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: i <= step ? k.accent : trackColor(k))),
              const SizedBox(width: 6),
            ],
            const SizedBox(width: 2),
            Text('$step of $of', key: const ValueKey('wizard-step'), style: TextStyle(fontSize: 13, color: k.secondary)),
          ],
        ),
      ),
    );
  }
}

/// A thin bar of [fraction].
class SpaceBar extends StatelessWidget {
  const SpaceBar({super.key, required this.fraction, this.color});

  final double fraction;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LayoutBuilder(
        builder: (context, c) => Container(
          height: 6,
          color: trackColor(k),
          alignment: Alignment.centerLeft,
          child: Container(width: c.maxWidth * fraction.clamp(0.0, 1.0), height: 6, color: color ?? k.accent),
        ),
      ),
    );
  }
}

/// "11.6 GB selected · 38.2 GB free" over the bar of what it takes of the free space. Too big for the free space: the left in red,
/// with how much more is needed.
class SpaceLine extends StatelessWidget {
  const SpaceLine({super.key, required this.label, required this.bytes, required this.free});

  /// "selected", "Adds", "to download".
  final String Function(String size) label;
  final int bytes;
  final int? free;

  bool get tooBig => free != null && bytes > free!;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final f = free;
    return Column(
      key: const ValueKey('space-line'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text(label(formatBytes(bytes)), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: tooBig ? k.emergency : k.text))),
            Text(f == null ? 'Free space unknown' : (tooBig ? 'Needs ${formatBytes(bytes - f)} more' : '${formatBytes(f)} free'),
                style: TextStyle(fontSize: 13, color: tooBig ? k.emergency : k.secondary)),
          ],
        ),
        const SizedBox(height: 6),
        SpaceBar(fraction: f == null || f <= 0 ? 0 : bytes / f, color: tooBig ? k.emergency : null),
      ],
    );
  }
}

/// The page's own big pill button.
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, required this.onPressed, this.outlined = false, this.danger = false});

  final String label;
  final VoidCallback? onPressed;
  final bool outlined;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    const shape = StadiumBorder();
    const text = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);
    if (outlined) {
      final c = danger ? k.emergency : k.accent;
      return OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: shape,
          foregroundColor: c,
          side: BorderSide(color: c, width: 2),
          textStyle: text,
        ),
        child: Text(label),
      );
    }
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: shape,
        backgroundColor: k.primary,
        foregroundColor: k.onPrimary,
        textStyle: text,
      ),
      child: Text(label),
    );
  }
}

/// The bar at the foot of a page: a line on top, the space line, the dots and the button.
class Dock extends StatelessWidget {
  const Dock({super.key, required this.children, this.maxWidth});

  final List<Widget> children;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    Widget col = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 10), children[i]],
    ]);
    if (maxWidth != null) col = Center(heightFactor: 1, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth!), child: col));
    return DecoratedBox(
      decoration: BoxDecoration(color: k.background, border: Border(top: BorderSide(color: lineColor(k)))),
      child: SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 20), child: col)),
    );
  }
}

/// A small upper-case label over a group.
class DLabel extends StatelessWidget {
  const DLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
    child: Text(text.toUpperCase(), style: TextStyle(fontSize: 12, letterSpacing: 0.72, fontWeight: FontWeight.w500, color: context.t.secondary)),
  );
}

/// A line of quieter text.
class DHint extends StatelessWidget {
  const DHint(this.text, {super.key, this.top = 6, this.center = false});

  final String text;
  final double top;
  final bool center;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(8, top, 8, 6),
    child: Text(text, textAlign: center ? TextAlign.center : TextAlign.start, style: TextStyle(fontSize: 13, color: context.t.secondary)),
  );
}

/// One row of a [RowStack].
class DRow extends StatelessWidget {
  const DRow({super.key, this.leading, required this.title, this.subtitle, this.subtitleOk = false, this.trailing, this.onTap, this.below});

  final Widget? leading;
  final String title;
  final String? subtitle;

  /// The subtitle in green ("Already on Cache").
  final bool subtitleOk;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Under the subtitle (a download's bar).
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 14)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: subtitleOk ? k.ok : k.secondary)),
                    ],
                    ?below,
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 14), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Rows stacked with a small gap, the first and last rounded.
class RowStack extends StatelessWidget {
  const RowStack({super.key, required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    BorderRadius radius(int i) {
      if (rows.length == 1) return BorderRadius.circular(16);
      if (i == 0) return const BorderRadius.vertical(top: Radius.circular(16), bottom: Radius.circular(4));
      if (i == rows.length - 1) return const BorderRadius.vertical(top: Radius.circular(4), bottom: Radius.circular(16));
      return BorderRadius.circular(4);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 3),
          Material(color: k.surface, borderRadius: radius(i), clipBehavior: Clip.antiAlias, child: rows[i]),
        ],
      ],
    );
  }
}

/// A store tile's action: Get (outlined), Update (filled) or Added (a tick in green).
enum TileAction { get, update, added, adding }

class TileButton extends StatelessWidget {
  const TileButton({super.key, required this.action, this.onPressed});

  final TileAction action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    switch (action) {
      case TileAction.added:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check, size: 16, color: k.ok),
            const SizedBox(width: 4),
            Text('Added', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: k.ok)),
          ]),
        );
      case TileAction.adding:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('Adding…', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: k.secondary)),
        );
      case TileAction.get || TileAction.update:
        final fill = action == TileAction.update;
        return SizedBox(
          height: 32,
          child: TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              minimumSize: const Size(64, 32),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: StadiumBorder(side: BorderSide(color: fill ? k.primary : k.accent, width: 2)),
              backgroundColor: fill ? k.primary : null,
              foregroundColor: fill ? k.onPrimary : k.accent,
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(fill ? 'Update' : 'Get'),
          ),
        );
    }
  }
}

/// A tile of a store row: tile, title, line, size, and Get, Update or Added.
class StoreTile extends StatelessWidget {
  const StoreTile({super.key, required this.icon, required this.title, required this.line, required this.size, required this.action, this.onAction, this.onTap, this.width = 158});

  final IconData icon;
  final String title;
  final String line;
  final String size;
  final TileAction action;
  final VoidCallback? onAction;
  final VoidCallback? onTap;

  /// null: as wide as the grid gives it.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return SizedBox(
      width: width,
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DTile(icon),
                const SizedBox(height: 11),
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                const SizedBox(height: 3),
                SizedBox(
                  height: 32,
                  child: Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, height: 1.25, color: k.secondary)),
                ),
                const SizedBox(height: 3),
                Text(size, style: TextStyle(fontSize: 12.5, color: k.secondary)),
                const SizedBox(height: 8),
                TileButton(action: action, onPressed: onAction),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row's heading with See all.
class SectionHead extends StatelessWidget {
  const SectionHead({super.key, required this.title, this.onSeeAll});

  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 0, 4),
      child: Row(
        children: [
          Expanded(child: Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: k.text))),
          if (onSeeAll != null)
            TextButton(
              key: ValueKey('see-all-${title.toLowerCase()}'),
              onPressed: onSeeAll,
              style: TextButton.styleFrom(foregroundColor: k.accent, textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              child: const Text('See all'),
            ),
        ],
      ),
    );
  }
}

/// A horizontal row of store tiles that scrolls sideways.
class TileRow extends StatelessWidget {
  const TileRow({super.key, required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    clipBehavior: Clip.none,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (var i = 0; i < tiles.length; i++) ...[if (i > 0) const SizedBox(width: 10), tiles[i]]],
    ),
  );
}

/// Store tiles in a grid of [columns] (a wide window).
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.tiles, required this.columns});

  final List<Widget> tiles;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += columns) {
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var c = 0; c < columns; c++) ...[
            if (c > 0) const SizedBox(width: 12),
            Expanded(child: i + c < tiles.length ? tiles[i + c] : const SizedBox.shrink()),
          ],
        ],
      ));
    }
    return Column(children: [for (var i = 0; i < rows.length; i++) ...[if (i > 0) const SizedBox(height: 12), rows[i]]]);
  }
}

/// Chips of what an activity includes.
class DChips extends StatelessWidget {
  const DChips({super.key, required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final l in labels)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
              child: Text(l, style: TextStyle(fontSize: 13, color: k.text)),
            ),
        ],
      ),
    );
  }
}

/// "Show everything it adds" with its arrow; turned over when open.
class SeeAllToggle extends StatelessWidget {
  const SeeAllToggle({super.key, required this.label, required this.open, required this.onTap});

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.accent))),
              const SizedBox(width: 4),
              Icon(open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 18, color: k.accent),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A labelled fact of a sheet: "CONNECTS TO" over "National Weather Service".
class FactRow extends StatelessWidget {
  const FactRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: k.secondary)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.text)),
        ],
      ),
    );
  }
}

/// Lines in a small card (the sheet's details).
class MiniList extends StatelessWidget {
  const MiniList({super.key, required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(14)),
      child: Text(lines.join('\n'), style: TextStyle(fontSize: 13.5, height: 1.7, color: k.text)),
    );
  }
}

/// The search box of Discover's pages.
class DSearchBox extends StatelessWidget {
  const DSearchBox({super.key, required this.hint, required this.controller, required this.onChanged});

  final String hint;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return TextField(
      key: const ValueKey('discover-search'),
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: TextStyle(fontSize: 15, color: k.text),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: k.secondary, fontSize: 14),
        prefixIcon: Padding(padding: const EdgeInsets.only(left: 16, right: 12), child: Icon(Icons.search, color: k.secondary)),
        prefixIconConstraints: const BoxConstraints(minWidth: 52, minHeight: 48),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: k.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide(color: k.accent, width: 1.5)),
      ),
    );
  }
}

/// A value worked out from [listenable] (a plan, a size), worked out again whenever it changes; the last value stays on screen
/// while the next is worked out, so nothing flickers while a download moves.
class Computed<T> extends StatefulWidget {
  const Computed({super.key, required this.listenable, required this.compute, required this.builder});

  final Listenable listenable;
  final Future<T> Function() compute;
  final Widget Function(BuildContext context, T? value) builder;

  @override
  State<Computed<T>> createState() => _ComputedState<T>();
}

class _ComputedState<T> extends State<Computed<T>> {
  T? _value;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_run);
    _run();
  }

  @override
  void didUpdateWidget(Computed<T> old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_run);
      widget.listenable.addListener(_run);
    }
    _run();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_run);
    super.dispose();
  }

  void _run() {
    final g = ++_gen;
    widget.compute().then((v) {
      if (mounted && g == _gen) setState(() => _value = v);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
