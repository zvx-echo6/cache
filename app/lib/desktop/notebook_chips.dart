import 'package:flutter/material.dart';

import 'desktop.dart';

/// Notebooks' "Log again" chips. On the Linux desktop they are one horizontal row (it scrolls sideways when the 300-wide shelf cannot
/// hold them all, and fades out at its right edge while there is more) above the notebooks; anywhere else they wrap, as they always did.
class LogAgainChips extends StatefulWidget {
  const LogAgainChips({super.key, required this.chips});

  final List<Widget> chips;

  @override
  State<LogAgainChips> createState() => _LogAgainChipsState();
}

class _LogAgainChipsState extends State<LogAgainChips> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chips = widget.chips;
    if (!isLinuxDesktop(context)) return Wrap(spacing: 8, runSpacing: 4, children: chips);
    final row = SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            chips[i],
          ],
        ],
      ),
    );
    // More to the right than shows: a 24-pixel fade at the right edge, from the pane's background to transparent. The mask reads the
    // scroll position when it paints (after layout), so the first frame is right and no state has to catch up; it repaints on scroll.
    return AnimatedBuilder(
      animation: _scroll,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) {
          final p = _scroll.hasClients ? _scroll.position : null;
          final more = p != null && p.hasContentDimensions && p.maxScrollExtent - p.pixels > 0.5;
          return LinearGradient(
            colors: [Colors.black, Colors.black, more ? const Color(0x00000000) : Colors.black],
            stops: [0, (1 - 24 / r.width).clamp(0.0, 1.0), 1],
          ).createShader(r);
        },
        child: child,
      ),
      child: row,
    );
  }
}
