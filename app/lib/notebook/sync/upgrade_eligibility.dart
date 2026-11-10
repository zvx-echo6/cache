import 'dart:convert';
import 'dart:io';

import '../../files.dart';
import '../../platform/app_log.dart';

/// The notebooks that existed when this device first started a version that has format 2 of the notebooks share (the upgrade):
/// the only ones that are matched by exact name with other devices' notebooks, because that is how builds before format 2 told
/// notebooks apart. Every notebook made after that is told apart by its id alone, so two made with one name stay two.
///
/// Kept in a file of its own, with a backup beside it: it is written once at the upgrade and then only added to, and it must not
/// be lost with the share's other state. A file that cannot be read is restored from the backup; if that cannot be read either,
/// the set is empty (nothing is matched by name, the cautious side: notebooks stay separate rather than merge by mistake) and the
/// damaged file is kept beside it.
class UpgradeEligibility {
  UpgradeEligibility(this.file);

  final File file;
  final Set<String> ids = {};
  bool _captured = false;
  bool _loaded = false;
  bool _dirty = false;

  File get _bak => File('${file.path}.bak');

  bool get captured => _captured;

  Future<bool> _read(File f) async {
    try {
      if (!await f.exists()) return false;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['ids'] is! List) return false;
      ids
        ..clear()
        ..addAll([for (final x in j['ids'] as List) '$x']);
      _captured = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (await _read(file)) return;
    if (await _read(_bak)) {
      _dirty = true;
      await save();
      return;
    }
    if (await file.exists() || await _bak.exists()) {
      // Damaged and no good copy: nothing is eligible, and that is remembered (it is not captured again).
      logError('Notebook sync: the upgrade list could not be read; no notebook is matched by name', error: file.path);
      try {
        if (await file.exists()) await file.rename('${file.path}.damaged');
      } catch (_) {}
      ids.clear();
      _captured = true;
      _dirty = true;
      await save();
    }
  }

  /// The first start of this version: [current] are the notebooks from before. Only once.
  Future<void> capture(Iterable<String> current) async {
    await load();
    if (_captured) return;
    ids.addAll(current);
    _captured = true;
    _dirty = true;
    await save();
  }

  void add(String id) {
    if (ids.add(id)) _dirty = true;
  }

  Future<void> save() async {
    if (!_dirty || !_captured) return;
    await file.parent.create(recursive: true);
    final text = jsonEncode({'ids': [...ids]..sort()});
    await writeStringAtomic(file, text);
    await writeStringAtomic(_bak, text);
    _dirty = false;
  }
}
