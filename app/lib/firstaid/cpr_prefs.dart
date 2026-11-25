import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_fs.dart';

/// What the CPR metronome remembers on the device: whether its tick and its buzz are on (both are, at first).
class CprPrefs extends ChangeNotifier {
  CprPrefs({this.settingsDirOverride});

  final Directory? settingsDirOverride;
  AppFs? _fs;

  bool sound = true;
  bool vibration = true;

  static const String _name = 'first-aid.json';

  bool _disposed = false;

  // The screen that made this can be gone before the file is read: it then ends quietly.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> init() async {
    try {
      final fs = createAppFs(supportOverride: settingsDirOverride);
      await fs.mkdir(AppRoot.support, '');
      _fs = fs;
      final text = await fs.readString(AppRoot.support, _name);
      if (text != null) {
        final j = jsonDecode(text) as Map<String, dynamic>;
        sound = j['sound'] != false;
        vibration = j['vibration'] != false;
      }
    } catch (_) {
      // A damaged file is ignored: both are on.
    }
    notifyListeners();
  }

  void set({bool? sound, bool? vibration}) {
    if (sound != null) this.sound = sound;
    if (vibration != null) this.vibration = vibration;
    notifyListeners();
    try {
      _fs?.writeStringAtomicSync(AppRoot.support, _name, jsonEncode({'sound': this.sound, 'vibration': this.vibration}));
    } catch (_) {}
  }
}
