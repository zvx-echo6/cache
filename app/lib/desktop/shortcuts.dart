import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Counts the times the "/" shortcut asked Home to focus its search box ("Search Cache or ask anything"). Home listens.
final ValueNotifier<int> homeSearchRequests = ValueNotifier<int>(0);

/// A text field has the keyboard focus (so a shortcut must leave its keys alone).
bool _typing() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context != null && context.mounted && context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// The Linux desktop's two global keys, for the page inside the shell. Enter, Tab, Shift+Tab and the arrow keys are Flutter's own
/// (activate the focused control, move the focus). Neither key does anything while a text field has the focus, and a pushed page
/// with its own keys (the PDF reader, the video player) is outside this widget.
///   /     go to Home and focus its search box
///   Esc   step back one page in the pane that has the focus, when it has one to step back to (a dialog or sheet closes on Esc by
///         itself)
/// There is no Alt or Ctrl plus number: a browser on Linux uses them to switch its tabs.
class DesktopKeys extends StatelessWidget {
  const DesktopKeys({super.key, required this.onHome, required this.child});

  final VoidCallback onHome;
  final Widget child;

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _typing()) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed || keys.isShiftPressed) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.slash) {
      onHome();
      homeSearchRequests.value++;
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      final focused = FocusManager.instance.primaryFocus?.context;
      final nav = focused == null || !focused.mounted ? null : Navigator.maybeOf(focused);
      if (nav != null && nav.canPop()) {
        nav.maybePop();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // The Focus is not a stop for Tab; it holds the focus while nothing else has it, so the keys reach this widget from anywhere on
  // the page.
  @override
  Widget build(BuildContext context) => Focus(autofocus: true, skipTraversal: true, onKeyEvent: _key, child: child);
}
