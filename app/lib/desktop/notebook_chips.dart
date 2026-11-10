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
  bool _more = false;

  void _measure(ScrollMetrics m) {
    final more = m.extentAfter > 0.5;
    if (more == _more) return;
    // Metrics arrive during layout: set the flag after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && more != _more) setState(() => _more = more);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chips = widget.chips;
    if (!isLinuxDesktop(context)) return Wrap(spacing: 8, runSpacing: 4, children: chips);
    Widget row = SingleChildScrollView(
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
    row = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        _measure(n.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          _measure(n.metrics);
          return false;
        },
        child: row,
      ),
    );
    // More to the right than shows: a 24-pixel fade at the right edge. (The mask is always there, so the row keeps its place when
    // it stops fading.)
    final end = _more ? const Color(0x00000000) : Colors.black;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (r) => LinearGradient(
        colors: [Colors.black, Colors.black, end],
        stops: [0, (1 - 24 / r.width).clamp(0.0, 1.0), 1],
      ).createShader(r),
      child: row,
    );
  }
}
