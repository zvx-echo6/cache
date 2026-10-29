import 'package:flutter/material.dart';

/// The keyboard closes the way people expect on a phone, in every screen: a tap outside the text field, or a scroll, closes it.
/// (Flutter's own default keeps it open on a touch outside the field on phones.) Single-line fields close it with their
/// Done or Search key, which is Flutter's default.
final Map<Type, Action<Intent>> keyboardActions = {
  ...WidgetsApp.defaultActions,
  EditableTextTapOutsideIntent: CallbackAction<EditableTextTapOutsideIntent>(
    onInvoke: (intent) {
      intent.focusNode.unfocus();
      return null;
    },
  ),
};

/// Scrolling a list closes the keyboard.
class CacheScrollBehavior extends MaterialScrollBehavior {
  const CacheScrollBehavior();

  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(BuildContext context) => ScrollViewKeyboardDismissBehavior.onDrag;
}
