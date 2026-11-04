import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// How much Cache writes to its own log (Settings > Storage > Advanced > Log level). Each level writes what the one before
/// it writes, and more:
/// - [minimal]: what failed and when (errors and crashes), with no file names or content;
/// - [standard] (the default): what the app does: indexing steps, downloads, sync, the model loading and unloading with the
///   memory then, the throttle's decisions, library names and sizes. No content;
/// - [detailed]: also file and PDF names, links, device names, step-by-step timings and retries, search timings and counts;
/// - [everything]: also content: what is searched and asked, the answers, notes, places. It goes back to the level before it
///   after 24 hours.
enum LogLevel { minimal, standard, detailed, everything }

/// The words of a level in Settings.
String logLevelTitle(LogLevel l) => switch (l) {
  LogLevel.minimal => 'Minimal',
  LogLevel.standard => 'Standard',
  LogLevel.detailed => 'Detailed',
  LogLevel.everything => 'Everything',
};

String logLevelDetail(LogLevel l) => switch (l) {
  LogLevel.minimal => 'Only what goes wrong',
  LogLevel.standard => 'What Cache does, without names or content',
  LogLevel.detailed => 'Also file names, links and timings',
  LogLevel.everything => 'Also what you search, ask and write. For 24 hours',
};

/// How long [LogLevel.everything] stays on.
const Duration kLogEverythingFor = Duration(hours: 24);

/// The log's files: [kLogFiles] of at most [kLogFileBytes] each (about 10 MB in all), the oldest dropped first; lines older
/// than [kLogKeepDays] days go when a file is turned over.
const int kLogFileBytes = 2 << 20;
const int kLogFiles = 5;
const int kLogKeepDays = 7;

/// The lines a job's Details show.
const int kLogJobLines = 20;

/// Cache's own log: a rolling file on the device (nothing leaves it unless the person shares it), written at the chosen
/// [LogLevel]. Every line also goes to the system log ([debugPrint]), as before.
class AppLog extends ChangeNotifier {
  AppLog({DateTime Function()? clock, this.fileBytes = kLogFileBytes, this.files = kLogFiles, void Function(String)? echo})
      : _clock = clock ?? DateTime.now,
        _echo = echo ?? ((s) => debugPrint(s));

  final DateTime Function() _clock;
  final void Function(String) _echo;
  final int fileBytes;
  final int files;

  Directory? _dir;
  LogLevel _level = LogLevel.standard;
  LogLevel _before = LogLevel.standard;
  DateTime? _everythingUntil;
  IOSink? _sink;
  int _size = 0;
  Future<void> _writing = Future<void>.value();
  bool _turning = false;

  /// Lines written while the file is being turned over: they go into the new file.
  final List<List<int>> _held = [];
  final Map<String, ListQueue<String>> _jobs = {};

  /// The folder of the log files (null until [open]).
  Directory? get dir => _dir;

  /// The level now (Everything goes back by itself after 24 hours).
  LogLevel get level {
    _expire();
    return _level;
  }

  /// When Everything goes back to the level before it (null when it is not on).
  DateTime? get everythingUntil => _level == LogLevel.everything ? _everythingUntil : null;

  File get _levelFile => File('${_dir!.path}/level.json');

  File fileAt(int i) => File('${_dir!.path}/cache${i == 0 ? '' : '.$i'}.log');

  /// The log files there are, newest first.
  List<File> get logFiles => _dir == null ? const [] : [for (var i = 0; i < files; i++) if (fileAt(i).existsSync()) fileAt(i)];

  /// Opens the log in [dir] (made when missing) and reads the level.
  Future<void> open(Directory dir) async {
    await dir.create(recursive: true);
    _dir = dir;
    try {
      final j = jsonDecode(await _levelFile.readAsString()) as Map;
      _level = LogLevel.values.byName(j['level'] as String);
      _before = LogLevel.values.byName((j['before'] as String?) ?? LogLevel.standard.name);
      final until = j['until'] as String?;
      _everythingUntil = until == null ? null : DateTime.tryParse(until);
    } catch (_) {}
    _expire();
    final f = fileAt(0);
    _size = f.existsSync() ? f.lengthSync() : 0;
    _sink = f.openWrite(mode: FileMode.append);
    notifyListeners();
  }

  /// Sets the level. Everything remembers the level before it and goes back to it after [kLogEverythingFor].
  Future<void> setLevel(LogLevel l) async {
    if (l == LogLevel.everything && _level != LogLevel.everything) {
      _before = _level;
      _everythingUntil = _clock().add(kLogEverythingFor);
    } else if (l != LogLevel.everything) {
      _everythingUntil = null;
    }
    _level = l;
    _write('LOG', 'Log level: ${logLevelTitle(l)}');
    await _saveLevel();
    notifyListeners();
  }

  /// Everything ends now: the level before it again.
  Future<void> endEverything() => setLevel(_level == LogLevel.everything ? _before : _level);

  void _expire() {
    final until = _everythingUntil;
    if (_level == LogLevel.everything && until != null && !_clock().isBefore(until)) {
      _level = _before;
      _everythingUntil = null;
      unawaited(_saveLevel());
      _write('LOG', 'Log level back to ${logLevelTitle(_level)} after 24 hours of Everything');
      notifyListeners();
    }
  }

  Future<void> _saveLevel() async {
    final d = _dir;
    if (d == null) return;
    try {
      await _levelFile.writeAsString(jsonEncode({'level': _level.name, 'before': _before.name, 'until': _everythingUntil?.toIso8601String()}));
    } catch (_) {}
  }

  /// Whether lines of [l] are written now.
  bool writes(LogLevel l) => l.index <= level.index;

  /// A line at [l]: written when the level is at least that, and kept for [job]'s Details (see [jobLines]).
  void add(LogLevel l, String tag, String line, {String? job}) {
    if (job != null) {
      final q = _jobs.putIfAbsent(job, ListQueue<String>.new);
      q.add('${_time(_clock())} $line');
      while (q.length > kLogJobLines) {
        q.removeFirst();
      }
    }
    if (!writes(l)) return;
    _write(tag, line);
  }

  /// The last lines logged for a piece of work (its key: `zim-pdf/<id>`), oldest first: what the queue's Details show.
  List<String> jobLines(String job) => List.of(_jobs[job] ?? const <String>[]);

  void _write(String tag, String line) {
    final text = '${_clock().toIso8601String()} $tag $line';
    _echo(text);
    if (_dir == null) return;
    final bytes = utf8.encode('$text\n');
    final sink = _sink;
    if (sink == null || _turning) {
      _held.add(bytes);
      return;
    }
    _size += bytes.length;
    sink.add(bytes);
    if (_size >= fileBytes) {
      _turning = true;
      _writing = _writing.then((_) => _turnOver());
    }
  }

  static String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  /// The file is full: it becomes .1 (and .1 becomes .2 ...), the oldest goes, files older than [kLogKeepDays] go.
  Future<void> _turnOver() async {
    final old = _sink;
    _sink = null;
    _size = 0;
    try {
      await old?.flush();
      await old?.close();
    } catch (_) {}
    try {
      final last = fileAt(files - 1);
      if (last.existsSync()) last.deleteSync();
      for (var i = files - 2; i >= 0; i--) {
        final f = fileAt(i);
        if (f.existsSync()) f.renameSync(fileAt(i + 1).path);
      }
      final cutoff = _clock().subtract(const Duration(days: kLogKeepDays));
      for (var i = 1; i < files; i++) {
        final f = fileAt(i);
        if (f.existsSync() && f.lastModifiedSync().isBefore(cutoff)) f.deleteSync();
      }
    } catch (_) {}
    final sink = _sink = fileAt(0).openWrite(mode: FileMode.append);
    for (final b in _held) {
      sink.add(b);
      _size += b.length;
    }
    _held.clear();
    _turning = false;
  }

  /// Everything written so far is on disk (before sharing).
  Future<void> flush() async {
    await _writing;
    try {
      await _sink?.flush();
    } catch (_) {}
  }

  /// Removes every log file and starts an empty one.
  Future<void> clear() async {
    await flush();
    final old = _sink;
    _sink = null;
    try {
      await old?.close();
    } catch (_) {}
    for (final f in logFiles) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    _jobs.clear();
    _size = 0;
    if (_dir != null) {
      final sink = _sink = fileAt(0).openWrite(mode: FileMode.append);
      for (final b in _held) {
        sink.add(b);
        _size += b.length;
      }
      _held.clear();
    }
    _write('LOG', 'Log cleared');
    notifyListeners();
  }

  /// The log's size on the device.
  int get bytes => logFiles.fold(0, (a, f) => a + f.lengthSync());
}

/// The app's one log (opened at start; before that, lines go to the system log only).
final AppLog appLog = AppLog();

/// Something failed: written at every level. [error] is named by its type below Detailed (its text can hold file names); its
/// text, and [detail] (a file name, a link), only from Detailed.
void logError(String what, {Object? error, StackTrace? stack, String? detail, String? job}) {
  final d = appLog.writes(LogLevel.detailed);
  final parts = [
    what,
    if (error != null) d ? '$error' : '${error.runtimeType}',
    if (detail != null && d) detail,
  ];
  appLog.add(LogLevel.minimal, 'ERROR', parts.join(': '), job: job);
  if (stack != null && d) appLog.add(LogLevel.detailed, 'ERROR', '$stack');
}

/// What the app does (Standard): no file names or content. [detail] (names, links) is added from Detailed.
void logInfo(String what, {String? detail, String? job}) =>
    appLog.add(LogLevel.standard, 'INFO', detail != null && appLog.writes(LogLevel.detailed) ? '$what: $detail' : what, job: job);

/// Names, links, step timings (Detailed).
void logDetail(String what, {String? job}) => appLog.add(LogLevel.detailed, 'DETAIL', what, job: job);

/// Content (Everything): what is searched and asked, answers, notes, places.
void logContent(String what, {String? job}) => appLog.add(LogLevel.everything, 'CONTENT', what, job: job);
