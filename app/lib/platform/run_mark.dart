import 'dart:io';

import 'package:flutter/widgets.dart';

/// The "running" mark in the log folder: present while a phone screen of Cache is in front, and the next start reads a mark left
/// behind as "the last run ended while it was open".
///
/// Cache's process outlives its screens (the engine is kept for the life of the process), and Android ends a backgrounded
/// process whenever it likes or an install replaces it. So the mark is taken away as soon as no phone screen shows the app
/// (hidden, paused or detached) and set again when one comes to the front: only a run that ended with a screen in front, where
/// nothing could have asked it to stop, is left with the mark.
class RunMark {
  RunMark(this.file);

  final File file;

  /// Whether a mark from an earlier run is there, and the time written in it.
  bool get left => file.existsSync();

  DateTime? get leftAt {
    try {
      return DateTime.tryParse(file.readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  void set() {
    try {
      file.writeAsStringSync(DateTime.now().toIso8601String());
    } catch (_) {}
  }

  void clear() {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// Keeps the mark as the screen is: set while a phone screen is in front, taken away at hidden, paused and detached.
  /// A run the car started with no phone screen has no mark (an Android engine starts as "detached"; only an activity changes
  /// that), so the system ending that idle process is never taken for a crash. Call once, when the run's mark has been read.
  AppLifecycleListener follow() {
    final listener = AppLifecycleListener(onResume: set, onHide: clear, onPause: clear, onDetach: clear);
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) set();
    return listener;
  }
}
