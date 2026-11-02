import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What the player remembers on this device (never synced; kept beside the app's other files, not in the shared videos folder):
/// where each video was left, and the last captions choice.
class VideoPrefs {
  /// Kept in [file]; null keeps it in memory only (tests).
  VideoPrefs({this.file});

  final File? file;

  /// At most this many videos keep a place; the oldest goes first.
  static const int maxPositions = 300;

  /// A place this close to the end is not kept (the video was watched).
  static const Duration endMargin = Duration(seconds: 10);

  /// A place this close to the start is not worth resuming.
  static const Duration minResume = Duration(seconds: 5);

  final Map<String, ({int ms, String at})> _positions = {};
  String? _captions;
  bool _loaded = false;
  Future<void>? _writing;
  bool _dirty = false;

  /// Reads the file once; a missing or damaged file is an empty record.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = file;
    if (f == null) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final p = (j['positions'] as Map?)?.cast<String, dynamic>() ?? const {};
      for (final e in p.entries) {
        final v = (e.value as Map).cast<String, dynamic>();
        _positions[e.key] = (ms: (v['ms'] as num).toInt(), at: (v['at'] ?? '') as String);
      }
      final c = j['captions'];
      _captions = c is String ? c : null;
    } catch (_) {}
  }

  /// The key of a video: a PeerTube video by its site and id (the saved copy and the stream share it), a ZIM video by its address.
  static String keyOf({String? instance, required String uuid}) => instance == null ? uuid : 'pt:$instance/$uuid';

  /// Where [key] was left, or null.
  Duration? positionOf(String key) {
    final p = _positions[key];
    return p == null ? null : Duration(milliseconds: p.ms);
  }

  /// Keeps [position] for [key]; within [endMargin] of [duration] (or under [minResume]) the place is cleared instead.
  void setPosition(String key, Duration position, Duration duration) {
    if (position < minResume || (duration > Duration.zero && position >= duration - endMargin)) {
      if (_positions.remove(key) != null) _save();
      return;
    }
    final had = _positions.remove(key);
    _positions[key] = (ms: position.inMilliseconds, at: DateTime.now().toUtc().toIso8601String());
    while (_positions.length > maxPositions) {
      _positions.remove(_positions.keys.first);
    }
    if (had?.ms != position.inMilliseconds) _save();
  }

  void clearPosition(String key) {
    if (_positions.remove(key) != null) _save();
  }

  /// The last captions choice: null when never chosen (captions start off), "off", or a language code.
  String? get captions => _captions;

  set captions(String? choice) {
    if (_captions == choice) return;
    _captions = choice;
    _save();
  }

  void _save() {
    if (file == null) return;
    _dirty = true;
    _writing ??= _write();
  }

  Future<void> _write() async {
    try {
      while (_dirty) {
        _dirty = false;
        final body = jsonEncode({
          'version': 1,
          'captions': _captions,
          'positions': {for (final e in _positions.entries) e.key: {'ms': e.value.ms, 'at': e.value.at}},
        });
        final f = file!;
        await f.parent.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(body, flush: true);
        await tmp.rename(f.path);
      }
    } catch (_) {
      // A place not kept is not worth an error.
    } finally {
      _writing = null;
    }
  }

  /// Waits for a pending write (tests).
  Future<void> flush() async => _writing;
}
