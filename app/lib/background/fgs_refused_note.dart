import 'package:flutter/material.dart';

import 'fgs_add.dart' show FgsWords;

/// Says [FgsWords.refused] once the person has refused notifications. The question ends just as the Add PDF page hands over to its
/// progress page, so a snackbar shown at that moment was on a screen that was going away: it is shown after the screens settle, on
/// whichever one the person is then on, and stays long enough to read (the Android 15 emulator showed none at 1 s or 3 s).
Future<void> showFgsRefusedNote(BuildContext? Function() context, {Duration after = const Duration(milliseconds: 700)}) async {
  await Future<void>.delayed(after);
  final c = context();
  if (c == null || !c.mounted) return;
  ScaffoldMessenger.maybeOf(c)?.showSnackBar(const SnackBar(content: Text(FgsWords.refused), duration: Duration(seconds: 8)));
}
