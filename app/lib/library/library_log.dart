import 'dart:convert';
import 'dart:io';

import 'cds.dart';

/// The library log (server/builder/LIBRARY-LOG.md, pack revision 4): where a book is shelved, its call number, a new title and
/// whether it is hidden are events in a per-device log, `<library>/log/<device_id>.jsonl`, one writer per file. Every device reads
/// every log and resolves them the same way. This is the app's reader, resolver and writer, the same rules as
/// cache_builder::log (resolve, read_logs, LogWriter); its tests check them against the document's examples.

const String kLogDir = 'log';
const String kLogExt = 'jsonl';

/// Who shelved a book: the sorter or a label (auto), or a person (user).
enum LogBy { auto, user }

enum LogEv { place, unsort, assign, retire, title, remove, restore }

/// One event of a log line. Linked-folder events and events of other versions are not read here (they are skipped, as an older
/// reader does).
class LogEvent {
  const LogEvent({required this.at, required this.dev, required this.ev, required this.doc, this.div, this.seq, this.by, this.title});

  final int at;
  final String dev;
  final LogEv ev;
  final String doc;
  final String? div;
  final int? seq;
  final LogBy? by;
  final String? title;

  static LogEvent? fromLine(String line) {
    Object? v;
    try {
      v = jsonDecode(line.trim());
    } catch (_) {
      return null;
    }
    if (v is! Map) return null;
    if (v['v'] != 1) return null;
    final at = v['at'];
    final dev = v['dev'];
    final doc = v['doc'];
    if (at is! int || at < 0 || dev is! String || dev.isEmpty || doc is! String || doc.isEmpty) return null;
    LogBy? by() => switch (v['by']) {
      'auto' => LogBy.auto,
      'user' => LogBy.user,
      _ => null,
    };
    final div = v['div'] is String ? v['div'] as String : null;
    final seq = v['seq'] is int && (v['seq'] as int) >= 0 && (v['seq'] as int) <= 0xFFFFFFFF ? v['seq'] as int : null;
    switch (v['ev']) {
      case 'place':
        final b = by();
        if (div == null || b == null) return null;
        return LogEvent(at: at, dev: dev, ev: LogEv.place, doc: doc, div: div, by: b);
      case 'unsort':
        final b = by();
        if (b == null) return null;
        return LogEvent(at: at, dev: dev, ev: LogEv.unsort, doc: doc, by: b);
      case 'assign' || 'retire':
        if (div == null || seq == null) return null;
        return LogEvent(at: at, dev: dev, ev: v['ev'] == 'assign' ? LogEv.assign : LogEv.retire, doc: doc, div: div, seq: seq);
      case 'title':
        final t = v['title'];
        if (t is! String) return null;
        return LogEvent(at: at, dev: dev, ev: LogEv.title, doc: doc, title: t);
      case 'remove':
        return LogEvent(at: at, dev: dev, ev: LogEv.remove, doc: doc);
      case 'restore':
        return LogEvent(at: at, dev: dev, ev: LogEv.restore, doc: doc);
      default:
        return null;
    }
  }

  /// The line as cache_builder writes it (keys in its order).
  String toLine() {
    final m = <String, Object?>{'v': 1, 'at': at, 'dev': dev, 'ev': ev.name, 'doc': doc};
    switch (ev) {
      case LogEv.place:
        m['div'] = div;
        m['by'] = by!.name;
      case LogEv.unsort:
        m['by'] = by!.name;
      case LogEv.assign || LogEv.retire:
        m['div'] = div;
        m['seq'] = seq;
      case LogEv.title:
        m['title'] = title;
      case LogEv.remove || LogEv.restore:
        break;
    }
    return jsonEncode(m);
  }

  LogEvent withAt(int at) => LogEvent(at: at, dev: dev, ev: ev, doc: doc, div: div, seq: seq, by: by, title: title);
}

/// The events in a log's text; a line that is not a known event (a torn last line, an unknown event or version) is skipped.
List<LogEvent> parseLog(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) ?LogEvent.fromLine(line),
];

/// Every event of every log in `<library>/log/`, in file-name order, then line order (as read_logs).
List<LogEvent> readLogs(Directory libraryDir) {
  final dir = Directory('${libraryDir.path}${Platform.pathSeparator}$kLogDir');
  if (!dir.existsSync()) return const [];
  final names = <String>[
    for (final e in dir.listSync(followLinks: false))
      if (e is File) e.uri.pathSegments.last,
  ].where((n) => !n.startsWith('.') && n.endsWith('.$kLogExt')).toList()
    ..sort();
  final out = <LogEvent>[];
  for (final n in names) {
    try {
      out.addAll(parseLog(utf8.decode(File('${dir.path}${Platform.pathSeparator}$n').readAsBytesSync(), allowMalformed: true)));
    } catch (_) {}
  }
  return out;
}

/// A resolved call number.
class LogCall {
  const LogCall(this.div, this.seq, this.suffix);
  final String div;
  final int seq;
  final int suffix;
  String get text => cdsCallText(div, seq, suffix);
}

/// What the logs say about one book.
class LogDocState {
  /// Some event placed or unsorted it.
  bool shelved = false;

  /// The division of the latest place; null for Unsorted (or never shelved).
  String? shelf;
  LogBy? by;
  String? title;
  bool removed = false;
  LogCall? call;
}

/// The resolved logs: each book's state, the highest number ever used in each division (assigned or retired), and the retired
/// numbers.
class LogResolved {
  final Map<String, LogDocState> docs = {};
  final Map<String, int> maxSeq = {};
  final Map<String, Set<int>> retired = {};

  /// The next free number in [div]: one past the highest ever assigned or retired there, on any device.
  int nextSeq(String div) => (maxSeq[div] ?? 0) + 1;

  LogDocState? operator [](String doc) => docs[doc];
}

/// (at, dev, position): the order of events, the same on every device whatever order the files were read in.
int _cmp((int, String, int) a, (int, String, int) b) {
  final x = a.$1.compareTo(b.$1);
  if (x != 0) return x;
  final y = a.$2.compareTo(b.$2);
  if (y != 0) return y;
  return a.$3.compareTo(b.$3);
}

/// The same pure function as cache_builder::log::resolve: the shelf is the latest place or unsort; the title the latest title;
/// removed when the latest of remove and restore is remove; a book holds its latest assign that no retire (same book, division and
/// number) cancels, when that division is its shelf's; a clash is ranked among every claim ever made on the number by (at, doc).
LogResolved resolveLog(List<LogEvent> events) {
  final r = LogResolved();
  final shelf = <String, ((int, String, int), String?, LogBy)>{};
  final title = <String, ((int, String, int), String)>{};
  final removed = <String, ((int, String, int), bool)>{};
  // every assign: (div, seq) -> sorted (at, doc)
  final claims = <(String, int), List<(int, String)>>{};
  final assigns = <String, List<((int, String, int), String, int)>>{};
  final retires = <(String, String, int)>{};
  void bump(String div, int seq) {
    if (seq > (r.maxSeq[div] ?? 0)) r.maxSeq[div] = seq;
  }

  for (var i = 0; i < events.length; i++) {
    final e = events[i];
    final stamp = (e.at, e.dev, i);
    r.docs.putIfAbsent(e.doc, LogDocState.new);
    switch (e.ev) {
      case LogEv.place || LogEv.unsort:
        final cur = shelf[e.doc];
        if (cur == null || _cmp(cur.$1, stamp) < 0) shelf[e.doc] = (stamp, e.ev == LogEv.place ? e.div : null, e.by!);
      case LogEv.assign:
        bump(e.div!, e.seq!);
        final c = claims.putIfAbsent((e.div!, e.seq!), () => []);
        if (!c.contains((e.at, e.doc))) c.add((e.at, e.doc));
        assigns.putIfAbsent(e.doc, () => []).add((stamp, e.div!, e.seq!));
      case LogEv.retire:
        bump(e.div!, e.seq!);
        r.retired.putIfAbsent(e.div!, () => {}).add(e.seq!);
        retires.add((e.doc, e.div!, e.seq!));
      case LogEv.title:
        final cur = title[e.doc];
        if (cur == null || _cmp(cur.$1, stamp) < 0) title[e.doc] = (stamp, e.title!);
      case LogEv.remove || LogEv.restore:
        final cur = removed[e.doc];
        if (cur == null || _cmp(cur.$1, stamp) < 0) removed[e.doc] = (stamp, e.ev == LogEv.remove);
    }
  }
  for (final c in claims.values) {
    c.sort((a, b) {
      final x = a.$1.compareTo(b.$1);
      return x != 0 ? x : a.$2.compareTo(b.$2);
    });
  }
  for (final entry in r.docs.entries) {
    final doc = entry.key;
    final st = entry.value;
    final s = shelf[doc];
    if (s != null) {
      st.shelved = true;
      st.shelf = s.$2;
      st.by = s.$3;
    }
    st.title = title[doc]?.$2;
    st.removed = removed[doc]?.$2 ?? false;
    final div = st.shelf;
    if (div == null) continue;
    ((int, String, int), String, int)? held;
    for (final a in assigns[doc] ?? const <((int, String, int), String, int)>[]) {
      if (retires.contains((doc, a.$2, a.$3))) continue;
      if (held == null || _cmp(held.$1, a.$1) < 0) held = a;
    }
    if (held != null && held.$2 == div) {
      final c = claims[(div, held.$3)] ?? const [];
      final rank = c.indexWhere((x) => x.$2 == doc);
      st.call = LogCall(div, held.$3, rank < 0 ? 0 : rank);
    }
  }
  return r;
}

/// A device id as a log file name allows it: letters, digits, '.', '_' and '-', at most 64, not starting with a dot.
bool validDeviceId(String id) => id.isNotEmpty && id.length <= 64 && !id.startsWith('.') && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id);

/// The writer of this device's log in one library. One writer per file: it refuses events of another device. Every append is
/// built first and written in one write to the file opened for append, then flushed to disk; a torn last line is closed first.
/// The clock never goes back: an event earlier than the last one written takes the last one's time.
class LogWriter {
  LogWriter(Directory libraryDir, this.dev) : file = File('${libraryDir.path}${Platform.pathSeparator}$kLogDir${Platform.pathSeparator}$dev.$kLogExt') {
    if (!validDeviceId(dev)) throw ArgumentError.value(dev, 'dev', 'not a device id');
  }

  final String dev;
  final File file;

  int _lastAt() {
    if (!file.existsSync()) return 0;
    var last = 0;
    for (final e in parseLog(file.readAsStringSync())) {
      if (e.at > last) last = e.at;
    }
    return last;
  }

  /// Appends [events] (all of this device), each at least as late as the last written. Synchronous: a few short lines.
  List<LogEvent> append(List<LogEvent> events) {
    if (events.isEmpty) return events;
    for (final e in events) {
      if (e.dev != dev) throw StateError('the log of $dev takes no events from ${e.dev}');
    }
    file.parent.createSync(recursive: true);
    var floor = _lastAt();
    final out = <LogEvent>[];
    for (final e in events) {
      final at = e.at < floor ? floor : e.at;
      floor = at;
      out.add(e.withAt(at));
    }
    final buf = StringBuffer();
    if (file.existsSync() && file.lengthSync() > 0) {
      final raf = file.openSync();
      try {
        raf.setPositionSync(file.lengthSync() - 1);
        if (raf.readByteSync() != 0x0A) buf.write('\n');
      } finally {
        raf.closeSync();
      }
    }
    for (final e in out) {
      buf
        ..write(e.toLine())
        ..write('\n');
    }
    final raf = file.openSync(mode: FileMode.append);
    try {
      raf.writeStringSync(buf.toString());
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    return out;
  }
}
