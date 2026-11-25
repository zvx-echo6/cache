import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../nav_state.dart';
import 'atv_icon.dart';

/// The mark a segment carries: none, a check mark when chosen (pick-one rows), or a check box (toggles).
enum SegmentMark { none, check, box }

/// One segment of a row of [ScaledSegments].
class TravelSegment {
  const TravelSegment({required this.id, required this.label, required this.selected, this.mark = SegmentMark.none, this.icon, this.semanticsLabel});

  final String id;
  final String label;
  final bool selected;
  final SegmentMark mark;

  /// The segment's own icon, drawn at the given size in the given colour (the first row's ways of travel).
  final Widget Function(double size, Color color)? icon;
  final String? semanticsLabel;
}

/// A row of equal-width segments that always shows on one line: when the labels are too wide for their segments (a narrow phone,
/// large text), every label and icon in the row shrinks by the same factor, so a row never shows two text sizes. Rows are 48 dp.
/// [joined] draws one rounded bar cut into segments (the options rows); otherwise each segment is its own rounded box (the first
/// row).
class ScaledSegments extends StatelessWidget {
  const ScaledSegments({super.key, required this.segments, required this.onTap, required this.joined, required this.keyPrefix});

  final List<TravelSegment> segments;
  final ValueChanged<String> onTap;
  final bool joined;

  /// Each segment's key is `<keyPrefix>-<id>`.
  final String keyPrefix;

  static const double height = 48;
  static const double _fontSize = 16;
  static const double _iconSize = 22;
  static const double _markSize = 18;
  static const double _gap = 6;
  static const double _minFactor = 0.2;

  TextStyle _style(Color c) => TextStyle(fontSize: _fontSize, fontWeight: FontWeight.w600, color: c);

  double _iconW(TravelSegment s) => s.icon != null ? _iconSize : (s.mark != SegmentMark.none ? _markSize : 0);

  /// The width of a segment's content (icon, gap, label) at factor [f].
  double _contentWidth(TravelSegment s, double f, TextScaler scaler, TextStyle base) {
    final tp = TextPainter(
      text: TextSpan(text: s.label, style: base.merge(_style(Colors.black)).copyWith(fontSize: _fontSize * f)),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    final icon = _iconW(s);
    return w + (icon > 0 ? (icon + _gap) * f : 0);
  }

  /// The one factor (at most 1) that makes every segment's content fit its room.
  double _factor(double room, TextScaler scaler, TextStyle base) {
    bool fits(double f) => segments.every((s) => _contentWidth(s, f, scaler, base) <= room);
    if (fits(1)) return 1;
    var lo = _minFactor, hi = 1.0;
    for (var i = 0; i < 14; i++) {
      final mid = (lo + hi) / 2;
      if (fits(mid)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final scaler = MediaQuery.textScalerOf(context);
    // The labels sit in a Material, which sets the text to the theme's body style: measure with the same one.
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return SizedBox(
      height: height,
      child: LayoutBuilder(builder: (context, c) {
        final n = segments.length;
        final inset = joined ? 0.0 : 3.0;
        final seg = (c.maxWidth - (joined ? 0 : inset * 2 * n)) / n;
        // The room for content: the segment less its border and a little breathing room each side (a pixel more to be safe).
        final room = math.max(0.0, seg - (joined ? 14 : 10) - 1);
        final f = _factor(room, scaler, base);
        Widget segment(TravelSegment s) {
          final ink = s.selected ? k.accent : k.text;
          final content = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.icon != null) ...[s.icon!(_iconSize * f, s.selected ? k.accent : k.secondary), SizedBox(width: _gap * f)],
              if (s.icon == null && s.mark != SegmentMark.none) ...[
                if (s.mark == SegmentMark.box)
                  Icon(s.selected ? Icons.check_box : Icons.check_box_outline_blank, size: _markSize * f, color: ink)
                else if (s.selected)
                  Icon(Icons.check, size: _markSize * f, color: ink),
                if (s.mark == SegmentMark.box || s.selected) SizedBox(width: _gap * f),
              ],
              Text(s.label, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: _style(ink).copyWith(fontSize: _fontSize * f)),
            ],
          );
          // Pick-one segments without the mark when not chosen keep their text centred, as the bar shows no empty slot.
          final inner = SizedBox(height: height, child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: content)));
          final tile = Semantics(
            button: true,
            selected: s.selected,
            checked: s.mark == SegmentMark.box ? s.selected : null,
            label: s.semanticsLabel ?? s.label,
            excludeSemantics: true,
            child: InkWell(key: ValueKey('$keyPrefix-${s.id}'), onTap: () => onTap(s.id), child: inner),
          );
          if (joined) {
            return Expanded(child: Material(color: s.selected ? k.accent.withValues(alpha: 0.2) : Colors.transparent, child: tile));
          }
          return Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: Material(
                color: s.selected ? k.accent.withValues(alpha: 0.2) : Colors.transparent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: s.selected ? k.accent : k.secondary.withValues(alpha: 0.5))),
                clipBehavior: Clip.antiAlias,
                child: tile,
              ),
            ),
          );
        }

        final kids = [for (final s in segments) segment(s)];
        if (!joined) return Row(children: kids);
        final line = k.secondary.withValues(alpha: 0.5);
        return DecoratedBox(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(kControlRadius), border: Border.all(color: line)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(kControlRadius - 1),
            child: Row(
              children: [
                for (var i = 0; i < n; i++) ...[
                  if (i > 0) Container(width: 1, color: line),
                  kids[i],
                ],
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// The directions panel's choices: Drive | Walk | Bike | ATV, the chosen way of travel's two options, and (where land rules mean
/// something) Standard | Emergency. What the assistant planned that no choice stands for is said in one line, with nothing
/// highlighted.
class TravelChoicesView extends StatelessWidget {
  const TravelChoicesView({super.key, required this.nav});

  final NavState nav;

  static const String emergencyWarning = 'Emergency routing ignores land-access rules. The route may cross private or closed land.';
  static const String askVehicleLine = "Ask's route: by any vehicle, on foot where none can go.";
  static const String askStrictLine = "Ask's route stays on open land.";

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final travel = nav.travel;
    final mode = nav.mode;
    final first = ScaledSegments(
      key: const ValueKey('travel-row-1'),
      joined: false,
      keyPrefix: 'mode',
      onTap: nav.setTravel,
      segments: [
        TravelSegment(id: 'drive', label: 'Drive', selected: travel == 'drive', icon: (s, c) => Icon(Icons.directions_car, size: s, color: c)),
        TravelSegment(id: 'walk', label: 'Walk', selected: travel == 'walk', icon: (s, c) => Icon(Icons.directions_walk, size: s, color: c)),
        TravelSegment(id: 'bike', label: 'Bike', selected: travel == 'bike', icon: (s, c) => Icon(Icons.directions_bike, size: s, color: c)),
        TravelSegment(id: 'atv', label: 'ATV', selected: travel == 'atv', icon: (s, c) => AtvIcon(size: s, color: c)),
      ],
    );
    Widget? second;
    switch (travel) {
      case 'drive':
        second = ScaledSegments(
          key: const ValueKey('travel-row-2'),
          joined: true,
          keyPrefix: 'opt',
          onTap: (id) => id == 'avoid-highways' ? nav.setAvoid(highways: !nav.avoidHighways) : nav.setAvoid(tolls: !nav.avoidTolls),
          segments: [
            TravelSegment(id: 'avoid-highways', label: 'Avoid highways', selected: nav.avoidHighways, mark: SegmentMark.box),
            TravelSegment(id: 'avoid-tolls', label: 'Avoid tolls', selected: nav.avoidTolls, mark: SegmentMark.box),
          ],
        );
      case 'walk':
        second = _pickOne(const [('walk', 'Pedestrian'), ('offroad_foot', 'Off-road')], mode);
      case 'bike':
        second = _pickOne(const [('bike', 'Bicycle'), ('offroad_moto', 'Dirt bike')], mode);
      case 'atv':
        second = _pickOne(const [('offroad_4w', 'Quad'), ('offroad_sxs', 'Side-by-side')], mode);
    }
    final strict = nav.landAccess == 'strict';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        first,
        if (second != null) ...[const SizedBox(height: 8), second],
        if (travel == null && mode == 'offroad_vehicle')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(askVehicleLine, key: const ValueKey('ask-vehicle-line'), style: TextStyle(fontSize: 14, height: 1.3, color: k.secondary)),
          ),
        if (nav.showsLandRow) ...[
          const SizedBox(height: 12),
          ScaledSegments(
            key: const ValueKey('travel-row-3'),
            joined: true,
            keyPrefix: 'land',
            onTap: nav.setLandAccess,
            segments: [
              TravelSegment(id: 'pragmatic', label: 'Standard', selected: nav.landAccess == 'pragmatic', mark: SegmentMark.check),
              TravelSegment(id: 'emergency', label: 'Emergency', selected: nav.landAccess == 'emergency', mark: SegmentMark.check),
            ],
          ),
          if (nav.landAccess == 'emergency')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(emergencyWarning, key: const ValueKey('land-emergency-warning'), style: TextStyle(fontSize: 14, height: 1.3, color: k.warning)),
            ),
          if (strict)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(askStrictLine, key: const ValueKey('ask-strict-line'), style: TextStyle(fontSize: 14, height: 1.3, color: k.secondary)),
            ),
        ],
      ],
    );
  }

  Widget _pickOne(List<(String, String)> options, String mode) => ScaledSegments(
        key: const ValueKey('travel-row-2'),
        joined: true,
        keyPrefix: 'opt',
        onTap: nav.setMode,
        segments: [for (final o in options) TravelSegment(id: o.$1, label: o.$2, selected: mode == o.$1, mark: SegmentMark.check)],
      );
}
