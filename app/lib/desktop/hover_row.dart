import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A row whose small action shows only while the pointer is over the row or the keyboard has the focus in it. [builder] is told
/// whether the action shows; it should keep the action in the tree (faded out, not removed) so a key can still reach it.
class HoverRow extends StatefulWidget {
  const HoverRow({super.key, required this.builder});

  final Widget Function(BuildContext context, bool active) builder;

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    // Focus anywhere in the row counts, but only when it came from the keyboard (a click leaves the row as it was).
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focus = f && FocusManager.instance.highlightMode == FocusHighlightMode.traditional),
      child: widget.builder(context, _hover || _focus),
    ),
  );
}

/// [child] faded out (but still in the tree and reachable by key) unless [shown].
class RevealAction extends StatelessWidget {
  const RevealAction({super.key, required this.shown, required this.child});

  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) => Opacity(opacity: shown ? 1 : 0, child: SizedBox(width: 32, height: 32, child: child));
}
