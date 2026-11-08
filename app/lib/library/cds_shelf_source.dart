import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../browse/web/build_api.dart' show BuildBook;
import '../browse/web/build_compression.dart' show compressionOutcomeWords;
import '../sources/libraries_state.dart';
import 'cds.dart';
import 'library_log.dart';
import 'shelf_source.dart';

/// The library's catalogue of books (written by cache-build library and kept at the library's root on install): `doc_id`, `version`,
/// `title`, `source_blake3`, `pieces`, `pages`.
const String kDocumentsFile = 'documents.tsv';

/// The device id this device writes its library log as (sync's identity when sharing is set up, else this install's own id); set
/// at start. Null: books cannot be placed on this device.
Future<String?> Function()? libraryDeviceIdShared;

/// The facts a book's pack holds (PACK-FORMAT.md, revision 4, the header's `book` block), as far as Bookshelves uses them.
class PackFacts {
  const PackFacts({this.suggested = const [], this.compression, this.sourceBytes, this.pages});

  /// The suggested division, then the second best, when known.
  final List<String> suggested;
  final Map<String, dynamic>? compression;
  final int? sourceBytes;
  final int? pages;

  /// The facts in a pack's first line; revision 3's `division` is read as `book.suggested`.
  static PackFacts fromHeader(Map<String, dynamic> h) {
    final book = h['book'] is Map ? (h['book'] as Map).cast<String, dynamic>() : null;
    final s = book?['suggested'] is Map ? (book!['suggested'] as Map).cast<String, dynamic>() : null;
    final old = h['division'] is Map ? (h['division'] as Map).cast<String, dynamic>() : null;
    final first = (s?['div'] ?? old?['division']) as String?;
    final second = (s?['second_div'] ?? old?['second_division']) as String?;
    final source = h['source'] is Map ? (h['source'] as Map).cast<String, dynamic>() : null;
    return PackFacts(
      suggested: [
        for (final d in [first, second])
          if (d != null && cdsDivision(d) != null) d,
      ],
      compression: book?['compression'] is Map ? (book!['compression'] as Map).cast<String, dynamic>() : null,
      sourceBytes: (source?['size'] as num?)?.toInt(),
      pages: (h['page_count'] as num?)?.toInt(),
    );
  }
}

/// Reads the first line of a pack (gzip-compressed JSON Lines) without reading the rest: the compressed file is read a piece at
/// a time and inflated until the header's line ends (a pack is mostly its vectors, after the header).
PackFacts? readPackFacts(File pack) {
  RandomAccessFile? f;
  try {
    f = pack.openSync();
    final filter = RawZLibFilter.inflateFilter(gzip: true);
    final out = <int>[];
    var read = 0;
    while (read < (8 << 20)) {
      final chunk = f.readSync(64 << 10);
      if (chunk.isEmpty) break;
      read += chunk.length;
      filter.process(chunk, 0, chunk.length);
      List<int>? part;
      while ((part = filter.processed(flush: false)) != null) {
        out.addAll(part!);
      }
      final nl = out.indexOf(0x0A);
      if (nl >= 0) {
        final h = jsonDecode(utf8.decode(out.sublist(0, nl)));
        return h is Map ? PackFacts.fromHeader(h.cast<String, dynamic>()) : null;
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    f?.closeSync();
  }
}

/// One library's books as read from its folder.
class _LibraryBooks {
  _LibraryBooks(this.item);

  final LibraryItem item;

  /// doc id -> (title, pages), in catalogue order.
  final Map<String, (String, int?)> docs = {};
  final Map<String, PackFacts> facts = {};
  LogResolved log = LogResolved();
}

/// Bookshelves by the Cache Decimal System, from the libraries on this device: each library that holds books (a `documents.tsv`)
/// gives its books; where each one is shelved, its call number and its title come from the library's log (`log/*.jsonl`,
/// resolved as LIBRARY-LOG.md says); what Cache suggested comes from the book's pack, when the pack is on this device. Placing a
/// book appends to this device's own log in that library.
class CdsShelfSource extends ChangeNotifier implements ShelfSource, ShelfPlacer {
  CdsShelfSource(this.libraries, {Future<String?> Function()? deviceId, int Function()? clock})
    // ignore: prefer_initializing_formals
    : _deviceId = deviceId,
      _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    libraries?.addListener(_onLibraries);
    _onLibraries();
  }

  /// Null: no libraries on this device (the shelves show, empty).
  final LibrariesState? libraries;
  final Future<String?> Function()? _deviceId;
  final int Function() _clock;

  List<_LibraryBooks> _libs = const [];
  final Map<String, ShelfBook> _books = {};
  bool _loading = true;
  bool _disposed = false;
  String _signature = '';
  Future<void>? _reading;
  bool _again = false;

  /// Ends when the books have been read again after the last change (tests).
  Future<void> whenRead() async {
    while (_reading != null) {
      await _reading;
    }
  }

  static final List<Shelf> _tree = [
    for (final c in kCdsClasses)
      Shelf(
        id: c.number,
        number: c.number,
        name: c.name,
        children: [for (final d in c.assigned) Shelf(id: d.number, number: d.number, name: d.name)],
      ),
  ];

  @override
  String get scheme => 'Shelved by the Cache Decimal System';

  @override
  String? get shortName => 'CDS';

  @override
  List<Shelf> get shelves => _tree;

  @override
  Shelf? shelf(String id) {
    for (final c in _tree) {
      if (c.id == id) return c;
      for (final d in c.children) {
        if (d.id == id) return d;
      }
    }
    return null;
  }

  @override
  List<Shelf> pathTo(String id) {
    final s = shelf(id);
    if (s == null) return const [];
    if (s.children.isNotEmpty) return [s];
    return [shelf('${id[0]}00')!, s];
  }

  static int _seqOf(ShelfBook b) => int.tryParse(RegExp(r'-(\d+)').firstMatch(b.callNumber ?? '')?.group(1) ?? '') ?? 0;
  static int _suffixOf(ShelfBook b) => int.tryParse(RegExp(r'\.(\d+)$').firstMatch(b.callNumber ?? '')?.group(1) ?? '') ?? 0;

  @override
  List<ShelfBook> booksOn(String id) {
    final out = [for (final b in _books.values) if (b.shelf == id) b];
    out.sort((a, b) {
      final x = _seqOf(a).compareTo(_seqOf(b));
      if (x != 0) return x;
      final y = _suffixOf(a).compareTo(_suffixOf(b));
      if (y != 0) return y;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return out;
  }

  @override
  int countUnder(Shelf shelf) {
    if (shelf.children.isEmpty) return _books.values.where((b) => b.shelf == shelf.id).length;
    final ids = {for (final c in shelf.children) c.id};
    return _books.values.where((b) => ids.contains(b.shelf)).length;
  }

  @override
  List<ShelfBook> get unsorted => [for (final b in _books.values) if (b.shelf == null) b];

  @override
  int get bookCount => _books.length;

  @override
  ShelfBook? book(String id) => _books[id];

  @override
  bool get loading => _loading;

  @override
  String? get goToHint => 'Go to a number, such as 530';

  @override
  ShelfTarget? goTo(String text) {
    final a = parseCdsAddress(text);
    if (a == null) return null;
    if (a.call != null) {
      final want = 'CDS ${a.call}';
      final b = _books.values.where((b) => b.callNumber == want).firstOrNull;
      return b == null ? ShelfTarget.shelf(a.division!) : ShelfTarget.book(b.id, shelfId: a.division);
    }
    return ShelfTarget.shelf(a.division ?? a.classNumber);
  }

  @override
  ShelfPlacer? get placer => _deviceId == null && libraryDeviceIdShared == null ? null : this;

  // ---- reading

  /// The libraries that hold books: every one but the guide with a catalogue of documents.
  List<LibraryItem> get _bookLibraries {
    final libs = libraries;
    if (libs == null) return const [];
    return [
      for (final l in libs.libraries)
        if (!libs.isGuide(l) && File('${l.path}${Platform.pathSeparator}$kDocumentsFile').existsSync()) l,
    ];
  }

  /// Whether [l] is a library of books (its rows go to Bookshelves).
  bool holdsBooks(LibraryItem l) => _libs.any((x) => x.item.path == l.path);

  /// What changes when the books do: the libraries, their catalogues and their logs (name, size, time).
  String _sign() {
    final b = StringBuffer();
    for (final l in _bookLibraries) {
      b.write('${l.path}|');
      for (final f in [File('${l.path}${Platform.pathSeparator}$kDocumentsFile')]) {
        try {
          final s = f.statSync();
          b.write('${s.size}:${s.modified.millisecondsSinceEpoch}|');
        } catch (_) {}
      }
      final logs = Directory('${l.path}${Platform.pathSeparator}$kLogDir');
      if (logs.existsSync()) {
        final names = [for (final e in logs.listSync()) if (e is File) e];
        names.sort((a, c) => a.path.compareTo(c.path));
        for (final f in names) {
          try {
            final s = f.statSync();
            b.write('${f.uri.pathSegments.last}:${s.size}:${s.modified.millisecondsSinceEpoch}|');
          } catch (_) {}
        }
      }
      b.write(';');
    }
    return b.toString();
  }

  void _onLibraries() {
    if (_disposed) return;
    String sig;
    try {
      sig = _sign();
    } catch (_) {
      sig = '';
    }
    if (sig == _signature && !_loading) return;
    _signature = sig;
    _read();
  }

  /// Reads the books again (after a change), one read at a time.
  Future<void> _read() {
    final running = _reading;
    if (running != null) {
      _again = true;
      return running;
    }
    return _reading = () async {
      try {
        do {
          _again = false;
          await _readOnce();
        } while (_again && !_disposed);
      } finally {
        _reading = null;
      }
    }();
  }

  Future<void> _readOnce() async {
    final out = <_LibraryBooks>[];
    for (final l in _bookLibraries) {
      final lb = _LibraryBooks(l);
      try {
        final lines = File('${l.path}${Platform.pathSeparator}$kDocumentsFile').readAsLinesSync();
        for (final line in lines.skip(1)) {
          final f = line.split('\t');
          if (f.isEmpty || f[0].isEmpty) continue;
          lb.docs[f[0]] = (f.length > 2 && f[2].isNotEmpty ? f[2] : f[0], f.length > 5 ? int.tryParse(f[5]) : null);
        }
      } catch (_) {
        continue;
      }
      lb.log = resolveLog(readLogs(l.dir));
      // The pack of each book, the newest version, when the packs came with the library (sync); not in a downloaded archive.
      final packs = Directory('${l.path}${Platform.pathSeparator}packs');
      if (packs.existsSync()) {
        final newest = <String, (int, File)>{};
        for (final e in packs.listSync()) {
          if (e is! File) continue;
          final m = RegExp(r'^(.+)@(\d+)\.cdoc$').firstMatch(e.uri.pathSegments.last);
          if (m == null || !lb.docs.containsKey(m.group(1))) continue;
          final v = int.parse(m.group(2)!);
          final cur = newest[m.group(1)!];
          if (cur == null || cur.$1 < v) newest[m.group(1)!] = (v, e);
        }
        for (final e in newest.entries) {
          final f = readPackFacts(e.value.$2);
          if (f != null) lb.facts[e.key] = f;
        }
      }
      out.add(lb);
    }
    if (_disposed) return;
    _libs = out;
    _books
      ..clear()
      ..addAll(_bookMap(out));
    _loading = false;
    notifyListeners();
  }

  static Map<String, ShelfBook> _bookMap(List<_LibraryBooks> libs) {
    final m = <String, ShelfBook>{};
    for (final lb in libs) {
      for (final d in lb.docs.entries) {
        final st = lb.log[d.key];
        if (st?.removed ?? false) continue;
        final facts = lb.facts[d.key];
        final shelf = st?.shelf;
        final stored = facts?.compression == null && facts?.sourceBytes == null
            ? null
            : compressionOutcomeWords(BuildBook(id: d.key, title: d.value.$1, compression: facts?.compression, size: facts?.sourceBytes ?? 0));
        final id = '${lb.item.folderName}/${d.key}';
        m[id] = ShelfBook(
          id: id,
          docId: d.key,
          sourceKey: lb.item.path,
          title: st?.title ?? d.value.$1,
          shelf: shelf != null && cdsDivision(shelf) != null ? shelf : null,
          callNumber: shelf == null ? null : st?.call?.text,
          shelvedBy: st?.by == null ? null : (st!.by == LogBy.user ? ShelvedBy.person : ShelvedBy.cache),
          suggestions: facts?.suggested ?? const [],
          pages: facts?.pages ?? d.value.$2,
          bytes: (facts?.compression?['stored_size'] as num?)?.toInt() ?? facts?.sourceBytes,
          stored: stored,
        );
      }
    }
    return m;
  }

  @override
  BookSearch searchOf(ShelfBook book) {
    final l = libraryOf(book);
    final libs = libraries;
    if (l == null || libs == null) return const BookSearch(BookSearchState.waiting);
    return switch (libs.phaseOf(l)) {
      LibraryPhase.ready => const BookSearch(BookSearchState.searchable),
      LibraryPhase.indexing => BookSearch(BookSearchState.making, libs.indexFraction(l)),
      LibraryPhase.opening => const BookSearch(BookSearchState.gettingReady),
      LibraryPhase.failed => const BookSearch(BookSearchState.failed),
      LibraryPhase.waiting => const BookSearch(BookSearchState.waiting),
    };
  }

  /// The library that holds [book].
  LibraryItem? libraryOf(ShelfBook book) => _libs.where((x) => x.item.path == book.sourceKey).firstOrNull?.item;

  // ---- placing

  _LibraryBooks? _libOf(ShelfBook b) => _libs.where((x) => x.item.path == b.sourceKey).firstOrNull;

  @override
  String? nextNumber(String shelfId) {
    if (cdsDivision(shelfId) == null) return null;
    // Every book library numbers its own shelves; the first is the one a new book from this device goes into.
    final lb = _libs.firstOrNull;
    return cdsCallText(shelfId, lb == null ? 1 : lb.log.nextSeq(shelfId));
  }

  /// The number [book] would get on [shelfId] (in its own library).
  String? nextNumberFor(ShelfBook book, String shelfId) {
    final lb = _libOf(book);
    if (lb == null || cdsDivision(shelfId) == null) return null;
    return cdsCallText(shelfId, lb.log.nextSeq(shelfId));
  }

  Future<String> _dev() async {
    final f = _deviceId ?? libraryDeviceIdShared;
    final id = f == null ? null : await f();
    if (id == null || !validDeviceId(id)) throw StateError('no device id to write the library log as');
    return id;
  }

  /// Writes the events of a set of moves (each book: to a division, or back to Unsorted with null), library by library, and
  /// reads the books again. Returns what each book got.
  Future<List<PlacedBook>> _write(List<(ShelfBook, String?)> moves, {required LogBy by}) async {
    final dev = await _dev();
    final at = _clock();
    final byLib = <String, List<LogEvent>>{};
    final next = <(String, String), int>{};
    final placed = <PlacedBook>[];
    for (final (b, to) in moves) {
      final lb = _libOf(b);
      if (lb == null || b.docId == null) continue;
      final doc = b.docId!;
      final call = lb.log[doc]?.call;
      final evs = byLib.putIfAbsent(lb.item.path, () => []);
      if (to == null) {
        evs.add(LogEvent(at: at, dev: dev, ev: LogEv.unsort, doc: doc, by: by));
        if (call != null) evs.add(LogEvent(at: at, dev: dev, ev: LogEv.retire, doc: doc, div: call.div, seq: call.seq));
        continue;
      }
      final seq = next[(lb.item.path, to)] ?? lb.log.nextSeq(to);
      next[(lb.item.path, to)] = seq + 1;
      evs.add(LogEvent(at: at, dev: dev, ev: LogEv.place, doc: doc, div: to, by: by));
      if (call != null) evs.add(LogEvent(at: at, dev: dev, ev: LogEv.retire, doc: doc, div: call.div, seq: call.seq));
      evs.add(LogEvent(at: at, dev: dev, ev: LogEv.assign, doc: doc, div: to, seq: seq));
      placed.add(PlacedBook(before: b, shelf: to, callNumber: cdsCallText(to, seq)));
    }
    for (final e in byLib.entries) {
      final lb = _libs.firstWhere((x) => x.item.path == e.key);
      LogWriter(lb.item.dir, dev).append(e.value);
    }
    _signature = '';
    await _read();
    // The numbers as the logs now resolve them (a clash with another device's claim shows its suffix).
    return [
      for (final p in placed) PlacedBook(before: p.before, shelf: p.shelf, callNumber: _books[p.before.id]?.callNumber ?? p.callNumber),
    ];
  }

  @override
  Future<Placement> place(List<(ShelfBook, String)> moves) async => Placement(await _write([for (final m in moves) (m.$1, m.$2)], by: LogBy.user));

  @override
  Future<void> undo(Placement placement) async {
    await _write([
      for (final p in placement.books)
        if (_books[p.before.id] case final now?) (now, p.before.shelf),
    ], by: LogBy.user);
  }

  @override
  void dispose() {
    _disposed = true;
    libraries?.removeListener(_onLibraries);
    super.dispose();
  }
}
