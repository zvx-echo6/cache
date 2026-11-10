import 'package:flutter/material.dart';

import 'desktop.dart';

/// Notebooks' "Log again" chips. On the Linux desktop they are one horizontal row (it scrolls sideways when the 300-wide shelf cannot
/// hold them all) above the notebooks; anywhere else they wrap, as they always did.
class LogAgainChips extends StatelessWidget {
  const LogAgainChips({super.key, required this.chips});

  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    if (!isLinuxDesktop(context)) return Wrap(spacing: 8, runSpacing: 4, children: chips);
    return SingleChildScrollView(
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
  }
}
