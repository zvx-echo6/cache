import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';

/// One wedge of a ring menu: a line icon and a short label.
class RingItem {
  const RingItem({required this.id, required this.label, required this.icon});

  final String id;
  final String label;
  final IconData icon;
}

/// The most wedges a ring shows; with more items, the last wedge is More and pages the same ring.
const int kRingMax = 6;

/// The wedges of page [page] of [items]: all of them when they fit, else [kRingMax] - 1 items and More.
List<RingItem> ringPage(List<RingItem> items, int page) {
  if (items.length <= kRingMax) return items;
  const per = kRingMax - 1;
  final start = page * per;
  return [...items.skip(start).take(per), const RingItem(id: kRingMore, label: 'More', icon: Icons.more_horiz)];
}

/// How many pages [items] need.
int ringPages(List<RingItem> items) => items.length <= kRingMax ? 1 : ((items.length + kRingMax - 2) ~/ (kRingMax - 1));

const String kRingMore = '_more';

/// A ring menu in Cache's style: rounded wedges on dark cards around a centre, line icons, the wedge under the finger in
/// orange. [centre] is drawn in the middle (the place, or a back arrow); tapping the centre calls [onCentre]. Every wedge is
/// also a button for screen readers.
class RingMenu extends StatefulWidget {
  const RingMenu({super.key, required this.items, required this.onPick, required this.centre, this.onCentre, this.size = 232});

  final List<RingItem> items;
  final ValueChanged<RingItem> onPick;
  final Widget centre;
  final VoidCallback? onCentre;
  final double size;

  @override
  State<RingMenu> createState() => _RingMenuState();
}

class _RingMenuState extends State<RingMenu> {
  int? _hot;

  double get _inner => widget.size * 0.27;

  /// The wedge at [p] (in the ring's box), or null in the centre or outside.
  int? _at(Offset p) {
    final c = Offset(widget.size / 2, widget.size / 2);
    final d = p - c;
    final r = d.distance;
    if (r < _inner || r > widget.size / 2 || widget.items.isEmpty) return null;
    // 0 at the top, clockwise.
    var a = math.atan2(d.dx, -d.dy);
    if (a < 0) a += 2 * math.pi;
    final step = 2 * math.pi / widget.items.length;
    return ((a + step / 2) / step).floor() % widget.items.length;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final n = widget.items.length;
    final step = n == 0 ? 0.0 : 2 * math.pi / n;
    final mid = (widget.size / 2 + _inner) / 2;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (e) => setState(() => _hot = _at(e.localPosition)),
        onTapCancel: () => setState(() => _hot = null),
        onTapUp: (e) {
          final i = _at(e.localPosition);
          setState(() => _hot = null);
          if (i != null) {
            HapticFeedback.selectionClick();
            widget.onPick(widget.items[i]);
          } else if ((e.localPosition - Offset(widget.size / 2, widget.size / 2)).distance < _inner) {
            widget.onCentre?.call();
          }
        },
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _RingPainter(n: n, hot: _hot, inner: _inner, card: k.surface, edge: k.background, accent: k.accent))),
            for (var i = 0; i < n; i++)
              Positioned(
                left: widget.size / 2 + mid * math.sin(i * step) - 34,
                top: widget.size / 2 - mid * math.cos(i * step) - 24,
                width: 68,
                height: 48,
                child: Semantics(
                  button: true,
                  label: widget.items[i].label,
                  onTap: () => widget.onPick(widget.items[i]),
                  excludeSemantics: true,
                  child: IgnorePointer(
                    child: Column(
                      key: ValueKey('ring-${widget.items[i].id}'),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(widget.items[i].icon, size: 20, color: _hot == i ? k.onPrimary : k.text),
                        const SizedBox(height: 2),
                        Text(widget.items[i].label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: _hot == i ? k.onPrimary : k.text)),
                      ],
                    ),
                  ),
                ),
              ),
            Center(
              child: Semantics(
                button: widget.onCentre != null,
                onTap: widget.onCentre,
                child: SizedBox(width: _inner * 2 - 8, height: _inner * 2 - 8, child: Center(child: widget.centre)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.n, required this.hot, required this.inner, required this.card, required this.edge, required this.accent});

  final int n;
  final int? hot;
  final double inner;
  final Color card;
  final Color edge;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.width / 2;
    canvas.drawCircle(c, outer, Paint()..color = Colors.black.withValues(alpha: 0.25)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    if (n == 0) return;
    final step = 2 * math.pi / n;
    for (var i = 0; i < n; i++) {
      final start = -math.pi / 2 + i * step - step / 2;
      final path = Path()
        ..arcTo(Rect.fromCircle(center: c, radius: outer), start, step, false)
        ..arcTo(Rect.fromCircle(center: c, radius: inner), start + step, -step, false)
        ..close();
      canvas.drawPath(path, Paint()..color = i == hot ? accent : card);
      canvas.drawPath(path, Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
    }
    canvas.drawCircle(c, inner - 3, Paint()..color = card);
    canvas.drawCircle(c, inner - 3, Paint()
      ..color = accent.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.n != n || old.hot != hot || old.card != card || old.accent != accent;
}
