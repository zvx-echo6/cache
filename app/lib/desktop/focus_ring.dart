import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// The focus ring for keyboard use on the Linux desktop: a 2-pixel ring in the accent colour, 2 pixels outside whatever has the focus.
/// It shows only after a key was pressed (a click or a touch hides it), never around a text field (which draws its own border) and
/// never around a whole page. It is drawn over the page and the dialogs above it, so every control has it in all four themes.
///
/// With [enabled] false nothing is drawn; the widget keeps the same shape either way, so the page below keeps its state when the
/// window crosses the desktop width.
class FocusRingScope extends StatefulWidget {
  const FocusRingScope({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<FocusRingScope> createState() => _FocusRingScopeState();
}

class _FocusRingScopeState extends State<FocusRingScope> {
  bool _keyboard = false;
  Rect? _ring;
  bool _tracking = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_changed);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_changed);
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && !_keyboard) {
      _keyboard = true;
      _changed();
    }
    return false;
  }

  void _changed() {
    if (!mounted || !widget.enabled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Where the ring goes now; checked again after every later frame while it shows (a list may scroll under it).
  void _measure() {
    if (!mounted) return;
    Rect? next;
    final node = FocusManager.instance.primaryFocus;
    final target = node?.context;
    final mine = context.findRenderObject();
    if (widget.enabled && _keyboard && node != null && node is! FocusScopeNode && target != null && target.mounted && mine is RenderBox && mine.attached && mine.hasSize) {
      final box = target.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize && target.findAncestorWidgetOfExactType<EditableText>() == null) {
        final rect = mine.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
        // A scrolling page or a whole pane that took the focus gets no ring around all of it.
        final whole = rect.width > mine.size.width * 0.6 && rect.height > mine.size.height * 0.6;
        if (!whole) next = rect;
      }
    }
    if (next != _ring) setState(() => _ring = next);
    if (next != null && !_tracking) {
      _tracking = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tracking = false;
        _measure();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ring = _ring;
    final theme = Theme.of(context);
    final color = theme.extension<CacheTokens>()?.accent ?? theme.colorScheme.primary;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (_keyboard) {
          _keyboard = false;
          _changed();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (widget.enabled && ring != null)
            Positioned.fromRect(
              rect: ring.inflate(4),
              child: IgnorePointer(
                child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: color, width: 2))),
              ),
            ),
        ],
      ),
    );
  }
}
