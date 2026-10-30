import 'package:flutter/material.dart';

import '../../theme.dart';
import 'map_widgets.dart';

/// Drawn over the map while the user draws an area for a download: drag a rectangle, then use it or cancel.
/// It reports the rectangle in screen points; the map screen turns the corners into a geographic area.
class AreaDrawOverlay extends StatefulWidget {
  const AreaDrawOverlay({super.key, required this.onUse, required this.onCancel});

  final void Function(Rect screenRect) onUse;
  final VoidCallback onCancel;

  @override
  State<AreaDrawOverlay> createState() => _AreaDrawOverlayState();
}

class _AreaDrawOverlayState extends State<AreaDrawOverlay> {
  Offset? _a;
  Offset? _b;

  Rect? get _rect => _a == null || _b == null ? null : Rect.fromPoints(_a!, _b!);

  bool get _big {
    final r = _rect;
    return r != null && r.width > 40 && r.height > 40;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => setState(() {
              _a = d.localPosition;
              _b = d.localPosition;
            }),
            onPanUpdate: (d) => setState(() => _b = d.localPosition),
            child: CustomPaint(painter: _RectPainter(_rect, k.accent)),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: mapPanel(context, radius: 16),
                child: Text(
                  _rect == null ? 'Drag on the map to draw the area to download' : 'Drag again to change it',
                  style: TextStyle(fontSize: 16, color: k.text),
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(child: OutlinedButton(onPressed: widget.onCancel, child: const Text('Cancel'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _big ? () => widget.onUse(_rect!) : null,
                      child: const Text('Use this area'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RectPainter extends CustomPainter {
  _RectPainter(this.rect, this.color);

  final Rect? rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null) return;
    canvas.drawRect(r, Paint()..color = color.withValues(alpha: 0.2));
    canvas.drawRect(
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(_RectPainter old) => old.rect != rect || old.color != color;
}
