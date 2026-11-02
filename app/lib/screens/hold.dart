import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A row or card that can be tapped and pressed and held. Press and hold always feels the same everywhere: a short vibration and a
/// visible lift. The hold action is also in the accessibility actions menu under [holdLabel], so it never needs the gesture.
class Holdable extends StatefulWidget {
  const Holdable({
    super.key,
    required this.child,
    this.onTap,
    this.onHold,
    this.holdLabel = 'Options',
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onHold;

  /// What the hold does, as the accessibility actions menu names it.
  final String holdLabel;
  final Color? color;
  final BorderRadius borderRadius;

  @override
  State<Holdable> createState() => _HoldableState();
}

class _HoldableState extends State<Holdable> {
  bool _lifted = false;

  void _hold() {
    final h = widget.onHold;
    if (h == null) return;
    HapticFeedback.mediumImpact();
    setState(() => _lifted = true);
    // The lift shows while the menu opens, then settles.
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (mounted) setState(() => _lifted = false);
    });
    h();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final hold = widget.onHold;
    return Semantics(
      customSemanticsActions: hold == null ? null : {CustomSemanticsAction(label: widget.holdLabel): _hold},
      child: AnimatedScale(
        scale: _lifted ? 1.02 : 1,
        duration: const Duration(milliseconds: 120),
        child: Material(
          color: widget.color ?? k.surface,
          elevation: _lifted ? 6 : 0,
          borderRadius: widget.borderRadius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: widget.onTap, onLongPress: hold == null ? null : _hold, child: widget.child),
        ),
      ),
    );
  }
}

/// A small badge for an exception on a row ("Update ready", "On this phone"): an outline and words, never a colour alone.
class RowBadge extends StatelessWidget {
  const RowBadge(this.text, {super.key, this.color, this.onTap});

  final String text;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.t.ok;
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: c)),
      child: Text(text, maxLines: 1, style: TextStyle(fontSize: 12, color: c)),
    );
    if (onTap == null) return badge;
    // The badge stays small; its hit area is at least 44 points.
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 44, minWidth: 44), child: Center(widthFactor: 1, child: badge)),
      ),
    );
  }
}
