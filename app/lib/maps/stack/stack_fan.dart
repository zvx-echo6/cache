// The fan of stacked icons and the list sheet of a big group: what opens when a group marker is tapped.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'icon_groups.dart';

/// Where a fan is on the screen: the centre, each member's disc and each member's true point (all in the map's points, in the order
/// of the group's members).
class FanLayout {
  const FanLayout({required this.centre, required this.discs, required this.truth});

  final ({double x, double y}) centre;
  final List<({double x, double y})> discs;
  final List<({double x, double y})> truth;
}

/// How much the map is dimmed behind a fan.
const double kFanDim = 0.14;

/// A disc is this many points across to the finger: its picture is [kFanDisc], the target around it is bigger.
const double kFanTarget = 44;

/// The fan: the map dimmed, a thin leader from each disc to its icon's own true point (marked by a small dot; points within 4 of each
/// other share one dot) and the discs. A tap on a disc picks it; a tap anywhere else folds the fan. Put it over the map and under the
/// cards, so they are not dimmed.
class StackFan extends StatelessWidget {
  const StackFan({super.key, required this.group, required this.layout, required this.pictures, required this.onPick, required this.onFold});

  final IconGroup group;
  final FanLayout layout;

  /// The picture of each member's disc, by member id (a member without one shows a plain disc).
  final Map<String, Uint8List?> pictures;
  final void Function(StackIcon member) onPick;
  final VoidCallback onFold;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final dots = sharedDots(layout.truth);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('stack-fan-dim'),
            behavior: HitTestBehavior.opaque,
            onTap: onFold,
            child: Container(color: Colors.black.withValues(alpha: kFanDim)),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _LeaderPainter(layout, dots, ring: k.surface)),
          ),
        ),
        for (var i = 0; i < group.members.length; i++)
          Positioned(
            left: layout.discs[i].x - kFanTarget / 2,
            top: layout.discs[i].y - kFanTarget / 2,
            width: kFanTarget,
            height: kFanTarget,
            child: Semantics(
              button: true,
              label: group.members[i].name,
              child: GestureDetector(
                key: ValueKey('stack-disc-${group.members[i].id}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onPick(group.members[i]),
                child: Center(child: _Disc(picture: pictures[group.members[i].id])),
              ),
            ),
          ),
      ],
    );
  }
}

class _Disc extends StatelessWidget {
  const _Disc({required this.picture});

  final Uint8List? picture;

  @override
  Widget build(BuildContext context) {
    // The picture is a square of kStackMarkerSize points with the disc in the middle: shown at its size, centred on the target.
    if (picture == null) return const SizedBox(width: kFanDisc, height: kFanDisc, child: DecoratedBox(decoration: BoxDecoration(color: Color(0xFF888888), shape: BoxShape.circle)));
    return OverflowBox(
      maxWidth: 54,
      maxHeight: 54,
      child: Image.memory(picture!, width: 54, height: 54, gaplessPlayback: true),
    );
  }
}

class _LeaderPainter extends CustomPainter {
  _LeaderPainter(this.layout, this.dots, {required this.ring});

  final FanLayout layout;
  final List<int> dots;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0xFF22222A)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < layout.discs.length; i++) {
      final t = layout.truth[dots[i]];
      canvas.drawLine(Offset(layout.discs[i].x, layout.discs[i].y), Offset(t.x, t.y), line);
    }
    final drawn = <int>{};
    for (var i = 0; i < layout.truth.length; i++) {
      final d = dots[i];
      if (!drawn.add(d)) continue;
      final t = Offset(layout.truth[d].x, layout.truth[d].y);
      canvas.drawCircle(t, 5, Paint()..color = const Color(0xFFF3E9D2));
      canvas.drawCircle(t, 3.2, Paint()..color = const Color(0xFF22222A));
    }
  }

  @override
  bool shouldRepaint(_LeaderPainter old) => old.layout != layout;
}

/// The list of a group of more than 8: each row shows the icon and its name; a tap picks it (and pops with it).
class StackListSheet extends StatelessWidget {
  const StackListSheet({super.key, required this.group, required this.pictures});

  final IconGroup group;
  final List<Uint8List> pictures;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
        child: ListView(
          key: const ValueKey('stack-list'),
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('${group.count} here', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
            ),
            for (var i = 0; i < group.members.length; i++)
              ListTile(
                key: ValueKey('stack-row-${group.members[i].id}'),
                leading: SizedBox(width: 40, height: 40, child: OverflowBox(maxWidth: 54, maxHeight: 54, child: Image.memory(pictures[i], width: 54, height: 54))),
                title: Text(group.members[i].name.isEmpty ? 'Unnamed' : group.members[i].name),
                onTap: () => Navigator.of(context).pop(group.members[i]),
              ),
          ],
        ),
      ),
    );
  }
}
