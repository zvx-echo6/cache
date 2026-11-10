import 'package:flutter/material.dart';

import '../layout/adaptive.dart' show ReadingWidth;
import 'desktop.dart';

/// Ask's page body on the Linux desktop: the warning line, the conversation and the composer share one column, 70 characters of the
/// 16-pixel reading text wide (and 16 pixels of padding each side), centred in the pane; and what the conversation says can be
/// selected and copied. Anywhere else [child] is returned as it is.
class DesktopReadingColumn extends StatelessWidget {
  const DesktopReadingColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isLinuxDesktop(context)) return child;
    final cap = ReadingWidth.maxWidthOf(context, style: const TextStyle(fontSize: 16));
    return SelectionArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: cap.isFinite ? cap + 32 : double.infinity), child: child),
      ),
    );
  }
}
