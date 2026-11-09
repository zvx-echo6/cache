import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../app_fs.dart';

import '../browse/web/build_api.dart' show BuildBook;
import '../browse/web/build_compression.dart' show compressionOutcomeWords;
import '../sharing/settings_sync.dart' show kBookshelvesDir;
import '../sources/libraries_state.dart';
import 'cds.dart';
import 'library_device.dart';
import 'shelf_source.dart';
import 'shelves_calls.dart';

/// The library's catalogue of books (written by cache-build library and kept at the library's root on install): `doc_id`, `version`,
/// `title`, `source_blake3`, `pieces`, `pages`.
const String kDocumentsFile = 'documents.tsv';

/// A library's folder of old per-device logs and its seed log (`log/*.jsonl`).
const String kLogDir = 'log';

/// The device id this device writes its Bookshelves log as (sync's identity when sharing is set up, else this install's own id); set
/// at start. Null: books cannot be placed on this device.
Future<String?> Function()? libraryDeviceIdShared;

/// The facts a book's pack holds (PACK-FORMAT.md, revision 4, the header's `book` and `samebook` blocks), as far as Bookshelves uses
/// them.
class PackFacts {
  const PackFacts({
    this.suggested = const [],
    this.compression,
    this.sourceBytes,
    this.pages,
    this.sourceTitle,
    this.author,
    this.edition,
    this.year,
    this.originalBlake3,
    this.blake3,
    this.samebook,
  });

  /// The title the book had before a caller's title or a titles file replaced it (`book.source_title`).
  final String? sourceTitle;

  /// Read when the pack has them (`book.author`, `book.edition`, `book.year`), never guessed.
  final String? author;
  final String? edition;
  final String? year;

  /// The suggested division, then the second best, when known.
  final List<String> suggested;
  final Map<String, dynamic>? compression;
  final int? sourceBytes;
  final int? pages;

  /// `book.original_blake3`: the copy's key in the Bookshelves log (else the doc id).
  final String? originalBlake3;

  /// The content hash same-book detection compares: `book.original_blake3`, else `source.blake3`.
  final String? blake3;

  /// The pack's `samebook` block as written (its `minhash` and `mean_vector` go to detection untouched).
  final Map<String, dynamic>? samebook;

  /// The facts in a pack's first line; revision 3's `division` is read as `book.suggested`.
  static PackFacts fromHeader(Map<String, dynamic> h) {
    final book = h['book'] is Map ? (h['book'] as Map).cast<String, dynamic>() : null;
    final s = book?['suggested'] is Map ? (book!['suggested'] as Map).cast<String, dynamic>() : null;
    final old = h['division'] is Map ? (h['division'] as Map).cast<String, dynamic>() : null;
    final first = (s?['div'] ?? old?['division']) as String?;
    final second = (s?['second_div'] ?? old?['second_division']) as String?;
    final source = h['source'] is Map ? (h['source'] as Map).cast<String, dynamic>() : null;
    final original = _text(book?['original_blake3']);
    return PackFacts(
      suggested: [
        for (final d in [first, second])
          if (d != null && cdsDivision(d) != null) d,
      ],
      compression: book?['compression'] is Map ? (book!['compression'] as Map).cast<String, dynamic>() : null,
      sourceBytes: (source?['size'] as num?)?.toInt(),
      pages: (h['page_count'] as num?)?.toInt(),
      sourceTitle: _text(book?['source_title']),
      author: _text(book?['author']),
      edition: _text(book?['edition']),
      year: _text(book?['year']),
      originalBlake3: original,
      blake3: original ?? _text(source?['blake3']),
      samebook: h['samebook'] is Map ? (h['samebook'] as Map).cast<String, dynamic>() : null,
    );
  }

  static String? _text(Object? v) {
    if (v is num) return '$v';
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
}

/// The first line of a pack (gzip-compressed JSON Lines), read without the rest: the compressed file is read a piece at a time and
/// inflated until the header's line ends (a pack is mostly its vectors, after the header).
String? readPackHeaderLine(File pack) {
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
      if (nl >= 0) return utf8.decode(out.sublist(0, nl));
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    f?.closeSync();
  }
}

/// A pack's facts (its first line).
PackFacts? readPackFacts(File pack) {
  final line = readPackHeaderLine(pack);
  if (line == null) return null;
  try {
    final h = jsonDecode(line);
    return h is Map ? PackFacts.fromHeader(h.cast<String, dynamic>()) : null;
  } catch (_) {
    return null;
  }
}

/// One book of a library's catalogue: its title, version, pages and the stored PDF's BLAKE3.
typedef _Doc = ({String title, int version, int? pages, String? hash});

/// One library's books as read from its folder.
class _LibraryBooks {
  _LibraryBooks(this.item);

  final LibraryItem item;

  /// The id the Bookshelves log knows the library by (in `loc`, `<library_id>/<doc_id>`); unique on this device.
  String id = '';

  /// doc id -> the catalogue's row, in catalogue order.
  final Map<String, _Doc> docs = {};

  /// doc id -> the newest pack's file.
  final Map<String, File> packs = {};
  final Map<String, PackFacts> facts = {};


}

/// One book of the resolved view (`books.<id>`), as far as the app reads it.
class _ViewBook {
  _ViewBook(this.id, this.j);

  final String id;
  final Map<String, dynamic> j;

  String get title => j['title'] as String? ?? id;
  String get reading => j['reading'] as String? ?? id;
  List<Map<String, dynamic>> get copies => [for (final c in (j['copies'] as List? ?? const [])) (c as Map).cast<String, dynamic>()];
  String? get shelf => j['shelf'] as String?;
  bool get shelved => j['shelved'] == true;
  bool get removed => j['removed'] == true;
  Map<String, dynamic>? get call => (j['call'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get suggested => (j['suggested'] as Map?)?.cast<String, dynamic>();

  /// The copy that holds the book's number (its own number is the book's), else the book's id.
  String get numbered {
    final c = call;
    if (c != null) {
      for (final cp in copies) {
        final o = (cp['own_call'] as Map?)?.cast<String, dynamic>();
        if (o != null && o['div'] == c['div'] && o['seq'] == c['seq'] && o['suffix'] == c['suffix']) return cp['copy'] as String;
      }
    }
    return id;
  }
}

/// Bookshelves by the Cache Decimal System, from the libraries on this device and the person's Bookshelves log
/// (`<app support>/bookshelves/`, server/builder/LIBRARY-LOG.md): which files are one book, the shelf, the call number, the title
/// and whether it is hidden all come from the view the core resolves from every one of the person's device logs; what was stored
/// comes from the book's pack, when the pack is on this device. Placing, moving, titles, hiding and the person's same-book
/// corrections are appended to this device's own log through the core.
///
/// Each read: this device's own old per-library logs are imported (once per library; the core keeps the record), the view is
/// resolved, every copy seen for the first time is checked against the others once and a match is written as the same book,
/// and a new book that matches nothing is shelved in its suggested division with the next free number.
class CdsShelfSource extends ChangeNotifier implements ShelfSource, ShelfPlacer, ShelfCopies, ShelfUnsorter {
  CdsShelfSource(
    this.libraries, {
    ShelvesCalls? calls,
    Future<String?> Function()? deviceId,
    Future<List<String>> Function()? ownIds,
    Future<Directory?> Function()? bookshelvesDir,
    Duration? pollEvery,
    int Function()? clock,
  })  : _calls = calls ?? (libraries == null ? null : CoreShelvesCalls(libraries.sources.whenCoreReady)),
        // ignore: prefer_initializing_formals
        _deviceId = deviceId,
        // ignore: prefer_initializing_formals
        _ownIds = ownIds,
        _dirOf = bookshelvesDir ?? _defaultDir,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    libraries?.addListener(_onLibraries);
    if (pollEvery != null) _poll = Timer.periodic(pollEvery, (_) => _onLibraries());
    _onLibraries();
  }

  /// Null: no libraries on this device (the shelves show, empty).
  final LibrariesState? libraries;
  final ShelvesCalls? _calls;
  final Future<String?> Function()? _deviceId;
  final Future<List<String>> Function()? _ownIds;
  final Future<Directory?> Function() _dirOf;
  final int Function() _clock;
  Timer? _poll;

  static Future<Directory?> _defaultDir() async {
    try {
      return Directory('${await appSupportPath()}${Platform.pathSeparator}$kBookshelvesDir');
    } catch (_) {
      return null;
    }
  }

  List<_LibraryBooks> _libs = const [];
  final Map<String, ShelfBook> _books = {};

  /// The books the view has as removed (hidden from Bookshelves), by id.
  final Map<String, ShelfBook> _hidden = {};

  /// Every copy key of a shown book -> the book's id, so a page opened on a book finds it after a merge or a split.
  final Map<String, String> _byCopy = {};
  final Map<String, _ViewBook> _view = {};
  Map<String, int> _next = const {};
  bool _loading = true;
  bool _disposed = false;

  /// True when the view could not be made (no core): the books show from their catalogues, in Unsorted, and nothing can be placed.
  bool _readOnly = false;
  String _signature = '';
  Future<void>? _reading;
  bool _again = false;
  Directory? _dir;
  final Set<String> _imported = {};

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
  List<ShelfBook> get unsorted {
    final out = [for (final b in _books.values) if (b.shelf == null) b];
    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return out;
  }

  @override
  int get bookCount => _books.length;

  @override
  List<ShelfBook> get hidden {
    final out = _hidden.values.toList();
    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return out;
  }

  @override
  ShelfBook? book(String id) => _books[id] ?? _books[_byCopy[id]];

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

  bool get _canWrite => !_readOnly && (_deviceId != null || libraryDeviceIdShared != null);

  @override
  ShelfPlacer? get placer => _canWrite ? this : null;

  @override
  ShelfCopies? get copies => _canWrite ? this : null;

  List<ShelfGap> _gaps = const [];

  @override
  List<ShelfGap> get notShelved => _gaps;

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

  static void _signFiles(StringBuffer b, Directory dir) {
    if (!dir.existsSync()) return;
    final files = [for (final e in dir.listSync()) if (e is File) e]..sort((a, c) => a.path.compareTo(c.path));
    for (final f in files) {
      try {
        final s = f.statSync();
        b.write('${f.uri.pathSegments.last}:${s.size}:${s.modified.millisecondsSinceEpoch}|');
      } catch (_) {}
    }
  }

  /// What changes when the books do: the libraries, their catalogues, packs and logs, and the Bookshelves log (a linked device's
  /// file arriving by sync).
  String _sign() {
    final sep = Platform.pathSeparator;
    final b = StringBuffer();
    for (final l in _bookLibraries) {
      b.write('${l.path}|');
      try {
        final s = File('${l.path}$sep$kDocumentsFile').statSync();
        b.write('${s.size}:${s.modified.millisecondsSinceEpoch}|');
      } catch (_) {}
      try {
        final s = Directory('${l.path}${sep}packs').statSync();
        b.write('${s.modified.millisecondsSinceEpoch}|');
      } catch (_) {}
      _signFiles(b, Directory('${l.path}$sep$kLogDir'));
      b.write(';');
    }
    final d = _dir;
    if (d != null) _signFiles(b, Directory('${d.path}$sep$kLogDir'));
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

  /// Each library's catalogue and the facts of its packs.
  List<_LibraryBooks> _readLibraries() {
    final sep = Platform.pathSeparator;
    final out = <_LibraryBooks>[];
    final ids = <String>{};
    for (final l in _bookLibraries) {
      final lb = _LibraryBooks(l);
      try {
        final lines = File('${l.path}$sep$kDocumentsFile').readAsLinesSync();
        for (final line in lines.skip(1)) {
          final f = line.split('\t');
          if (f.isEmpty || f[0].isEmpty) continue;
          final hash = f.length > 3 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(f[3]) ? f[3].toLowerCase() : null;
          lb.docs[f[0]] = (
            title: f.length > 2 && f[2].isNotEmpty ? f[2] : f[0],
            version: f.length > 1 ? int.tryParse(f[1]) ?? 1 : 1,
            pages: f.length > 5 ? int.tryParse(f[5]) : null,
            hash: hash,
          );
        }
      } catch (_) {
        continue;
      }
      var id = libraries?.idOf(l) ?? l.folderName;
      if (!ids.add(id)) {
        id = l.folderName;
        ids.add(id);
      }
      lb.id = id;
      // The pack of each book, the newest version, when the packs came with the library (sync); not in a downloaded archive.
      final packs = Directory('${l.path}${sep}packs');
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
          lb.packs[e.key] = e.value.$2;
          final f = readPackFacts(e.value.$2);
          if (f != null) lb.facts[e.key] = f;
        }
      }
      out.add(lb);
    }
    return out;
  }

  List<Map<String, dynamic>> _refs(List<_LibraryBooks> libs) => [
        for (final lb in libs) {'library_id': lb.id, 'dir': lb.item.path},
      ];

  Future<String?> _devOrNull() async {
    final f = _deviceId ?? libraryDeviceIdShared;
    try {
      final id = f == null ? null : await f();
      return id != null && validDeviceId(id) ? id : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _readOnce() async {
    final libs = _readLibraries();
    _libs = libs;
    final calls = _calls;
    final dir = _dir ??= await _dirOf();
    if (_disposed) return;
    if (calls == null || dir == null) {
      _apply(libs, null);
      return;
    }
    try {
      _dropOldStubs(dir);
      final refs = _refs(libs);
      final dev = await _devOrNull();
      // this device's own old per-library logs, once per library (the core records what it imported)
      if (dev != null) {
        final fresh = [for (final r in refs) if (!_imported.contains(r['library_id'])) r];
        if (fresh.isNotEmpty) {
          final ids = <String>{dev, ...?(await _ownIds?.call())};
          if (_ownIds == null) {
            final local = await libraryLocalDeviceId();
            if (local != null) ids.add(local);
          }
          for (final id in ids) {
            await calls.import({'dir': dir.path, 'dev': id, 'libraries': fresh});
          }
          _imported.addAll([for (final r in fresh) r['library_id'] as String]);
        }
      }
      var view = await calls.resolve({'dir': dir.path, 'libraries': refs});
      if (dev != null && await _firstSeen(calls, dir, dev, libs, view)) {
        view = await calls.resolve({'dir': dir.path, 'libraries': refs});
      }
      // the core keeps the view in .local/view.json itself
      if (_disposed) return;
      _apply(libs, view);
    } catch (_) {
      if (_disposed) return;
      _apply(libs, null);
    }
  }

  static const String _checkedFile = 'detected.json';

  File _checked(Directory dir) => File('${dir.path}${Platform.pathSeparator}.local${Platform.pathSeparator}$_checkedFile');

  Set<String> _readChecked(Directory dir) {
    try {
      final j = jsonDecode(_checked(dir).readAsStringSync());
      return {for (final c in (j as Map)['copies'] as List) c as String};
    } catch (_) {
      return {};
    }
  }

  /// Removes the header stubs an earlier build of this page wrote under `.local/packs/` (the core reads copies.jsonl now).
  static void _dropOldStubs(Directory dir) {
    try {
      final old = Directory('${dir.path}${Platform.pathSeparator}.local${Platform.pathSeparator}packs');
      if (old.existsSync()) old.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Copies seen for the first time (in the view, on this device): the core checks them once, against each other and every other
  /// copy here (`same ... by: auto` for each match), then a new book that matches nothing is shelved in its suggested division
  /// with the next free number, in (title, copy) order. The copies checked are remembered in `.local/detected.json`. True when
  /// anything was written.
  Future<bool> _firstSeen(ShelvesCalls calls, Directory dir, String dev, List<_LibraryBooks> libs, Map<String, dynamic> view) async {
    final checked = _readChecked(dir);
    final locOf = <String, String>{};
    for (final b in (view['books'] as Map? ?? const {}).values) {
      for (final c in ((b as Map)['copies'] as List? ?? const [])) {
        final locs = (c as Map)['locs'] as List? ?? const [];
        if (c['available'] == true && locs.isNotEmpty) locOf[c['copy'] as String] = '${locs.first}';
      }
    }
    final fresh = [for (final c in locOf.keys) if (!checked.contains(c)) c]..sort();
    if (fresh.isEmpty) return false;
    var wrote = false;
    final same = [
      for (final m in await calls.detect({'libraries': _refs(libs), 'copies': fresh, 'known': [for (final c in locOf.keys) if (checked.contains(c)) c]}))
        {'ev': 'same', 'copy': m['copy'], 'with': m['with'], 'by': 'auto', 'how': m['how'], 'score': ?m['score'], 'loc': ?locOf[m['copy']]},
    ];
    if (same.isNotEmpty) {
      await calls.append({'dir': dir.path, 'dev': dev, 'events': [for (final e in same) {...e, 'at': _clock()}]});
      view = await calls.resolve({'dir': dir.path, 'libraries': _refs(libs)});
      wrote = true;
    }
    // new books: every copy here is new and nothing has shelved them
    final freshSet = fresh.toSet();
    final books = (view['books'] as Map? ?? const {}).cast<String, dynamic>();
    final toShelve = <_ViewBook>[
      for (final e in books.entries)
        if (_ViewBook(e.key, (e.value as Map).cast<String, dynamic>()) case final b
            when !b.shelved && !b.removed && b.suggested?['div'] is String &&
                b.copies.where((c) => c['available'] == true).every((c) => freshSet.contains(c['copy'])))
          b,
    ]..sort((a, b) {
        final t = a.title.compareTo(b.title);
        return t != 0 ? t : a.id.compareTo(b.id);
      });
    final next = <String, int>{for (final e in (view['next'] as Map? ?? const {}).entries) e.key as String: (e.value as num).toInt()};
    final place = <Map<String, dynamic>>[];
    for (final b in toShelve) {
      final div = b.suggested!['div'] as String;
      if (cdsDivision(div) == null) continue;
      final seq = next[div] ?? 1;
      next[div] = seq + 1;
      final at = _clock();
      place
        ..add({'ev': 'place', 'copy': b.id, 'div': div, 'by': 'auto', 'loc': ?locOf[b.id], 'at': at})
        ..add({'ev': 'assign', 'copy': b.id, 'div': div, 'seq': seq, 'at': at});
    }
    if (place.isNotEmpty) {
      await calls.append({'dir': dir.path, 'dev': dev, 'events': place});
      wrote = true;
    }
    try {
      final f = _checked(dir);
      f.parent.createSync(recursive: true);
      final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode({'format': 1, 'copies': ([...checked, ...fresh]..sort())}), flush: true);
      tmp.renameSync(f.path);
    } catch (_) {}
    return wrote;
  }

  /// The books from the view (null: from the catalogues, read-only, in Unsorted).
  void _apply(List<_LibraryBooks> libs, Map<String, dynamic>? view) {
    _libs = libs;
    _books.clear();
    _hidden.clear();
    _byCopy.clear();
    _view.clear();
    _readOnly = view == null;
    _gaps = const [];
    _next = {for (final e in (view?['next'] as Map? ?? const {}).entries) e.key as String: (e.value as num).toInt()};
    if (view == null) {
      for (final lb in libs) {
        for (final d in lb.docs.entries) {
          final id = '${lb.item.folderName}/${d.key}';
          _books[id] = _shelfBook(id: id, lb: lb, doc: d.key, title: d.value.title);
        }
      }
    } else {
      final byId = {for (final lb in libs) lb.id: lb};
      final folders = <String, String>{
        for (final f in (view['folders'] as List? ?? const []))
          if (f is Map) '${f['dev']}/${f['folder_id']}': '${f['label'] ?? f['folder_id']}',
      };
      (_LibraryBooks, String)? here(Map<String, dynamic> copy) {
        for (final loc in (copy['locs'] as List? ?? const [])) {
          final s = '$loc';
          final i = s.indexOf('/');
          if (i < 0) continue;
          final lb = byId[s.substring(0, i)];
          final doc = s.substring(i + 1);
          if (lb != null && lb.docs.containsKey(doc)) return (lb, doc);
        }
        return null;
      }

      for (final e in (view['books'] as Map? ?? const {}).entries) {
        final vb = _ViewBook(e.key as String, (e.value as Map).cast<String, dynamic>());
        _view[vb.id] = vb;
        final copies = vb.copies;
        final reading = copies.where((c) => c['copy'] == vb.reading).firstOrNull ?? copies.firstOrNull;
        final at = reading == null ? null : here(reading);
        final spares = <SpareCopy>[
          for (final c in copies)
            if (c['copy'] != reading?['copy'])
              () {
                final h = here(c);
                final loc = [for (final l in (c['locations'] as List? ?? const [])) if (l is Map) l].firstOrNull;
                return SpareCopy(
                  copy: c['copy'] as String,
                  title: c['title'] as String? ?? (h == null ? vb.title : h.$1.docs[h.$2]!.title),
                  bytes: h == null ? null : _bytesOf(h.$1, h.$2),
                  here: h != null,
                  where: h != null
                      ? (libraries?.titleOf(h.$1.item) ?? h.$1.item.folderName)
                      : (loc != null ? '${folders['${loc['dev']}/${loc['folder_id']}'] ?? loc['folder_id']} · ${loc['relpath']}' : 'Not on this device'),
                );
              }(),
        ];
        final shelf = vb.shelf != null && cdsDivision(vb.shelf!) != null ? vb.shelf : null;
        final b = _shelfBook(
          id: vb.id,
          lb: at?.$1,
          doc: at?.$2,
          title: vb.title,
          shelf: shelf,
          callNumber: shelf == null ? null : vb.call?['text'] as String?,
          shelvedBy: switch (vb.j['by']) {
            'user' => ShelvedBy.person,
            'auto' => ShelvedBy.cache,
            _ => null,
          },
          author: vb.j['author'] as String?,
          edition: [?vb.j['edition'] as String?, if (vb.j['year'] != null) '${vb.j['year']}'].join(', '),
          suggested: vb.suggested?['div'] as String?,
          spares: spares,
          aka: [for (final a in (vb.j['aka'] as List? ?? const [])) '$a'],
          reading: reading?['copy'] as String? ?? vb.id,
        );
        // a hidden book keeps its shelf and number in the view; it shows only in Hidden books
        if (vb.removed) {
          _hidden[vb.id] = b;
          continue;
        }
        _books[vb.id] = b;
        for (final c in copies) {
          _byCopy[c['copy'] as String] = vb.id;
        }
      }
    }
    if (view != null) {
      // books the view has no copy for: their library came without copies.jsonl and without packs
      final seen = <String>{
        for (final b in (view['books'] as Map? ?? const {}).values)
          for (final c in ((b as Map)['copies'] as List? ?? const []))
            for (final l in ((c as Map)['locs'] as List? ?? const [])) '$l',
      };
      _gaps = [
        for (final lb in libs)
          if (lb.docs.keys.where((doc) => !seen.contains('${lb.id}/$doc')).length case final n when n > 0)
            ShelfGap(libraries?.titleOf(lb.item) ?? lb.item.folderName, n),
      ];
    }
    _loading = false;
    notifyListeners();
  }

  static int? _bytesOf(_LibraryBooks lb, String doc) {
    final f = lb.facts[doc];
    return (f?.compression?['stored_size'] as num?)?.toInt() ?? f?.sourceBytes;
  }

  ShelfBook _shelfBook({
    required String id,
    required _LibraryBooks? lb,
    required String? doc,
    required String title,
    String? shelf,
    String? callNumber,
    ShelvedBy? shelvedBy,
    String? author,
    String? edition,
    String? suggested,
    List<SpareCopy> spares = const [],
    List<String> aka = const [],
    String? reading,
  }) {
    final d = doc == null ? null : lb?.docs[doc];
    final facts = doc == null ? null : lb?.facts[doc];
    final stored = facts?.compression == null && facts?.sourceBytes == null
        ? null
        : compressionOutcomeWords(BuildBook(id: doc!, title: title, compression: facts?.compression, size: facts?.sourceBytes ?? 0));
    return ShelfBook(
      id: id,
      docId: doc,
      sourceKey: lb?.item.path,
      title: title,
      shelf: shelf,
      callNumber: callNumber,
      shelvedBy: shelvedBy,
      suggestions: facts?.suggested.isNotEmpty == true
          ? facts!.suggested
          : [if (suggested != null && cdsDivision(suggested) != null) suggested],
      pages: facts?.pages ?? d?.pages,
      bytes: lb == null || doc == null ? null : _bytesOf(lb, doc),
      stored: stored,
      author: author ?? facts?.author,
      edition: (edition == null || edition.isEmpty) ? [?facts?.edition, ?facts?.year].join(', ').emptyToNull : edition,
      originalTitle: facts?.sourceTitle != null && facts!.sourceTitle != title ? facts.sourceTitle : null,
      pdfPath: lb == null || doc == null ? null : localPdfOf(lb.item, doc, d?.hash),
      spares: spares,
      aka: aka,
      reading: reading,
      libraryName: lb == null ? null : (libraries?.titleOf(lb.item) ?? lb.item.folderName),
    );
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

  /// Where a book's PDF is kept on this device, when it is here: the library's Bookshelf copy, `bookshelf/<blake3>.pdf` (named by
  /// the stored file's hash, documents.tsv's `source_blake3`; it arrives with "PDF files" sync), else a device copy kept beside the
  /// libraries as Cache for Linux keeps it, `sources/<library_id>/<doc_id>.pdf`. Null when neither file is here.
  static String? localPdfOf(LibraryItem l, String doc, String? hash) {
    final sep = Platform.pathSeparator;
    final candidates = [
      if (hash != null) '${l.path}${sep}bookshelf$sep$hash.pdf',
      '${l.dir.parent.parent.path}${sep}sources$sep${l.folderName}$sep$doc.pdf',
    ];
    for (final c in candidates) {
      try {
        if (File(c).existsSync()) return c;
      } catch (_) {}
    }
    return null;
  }

  /// The library that holds [book].
  LibraryItem? libraryOf(ShelfBook book) => _libs.where((x) => x.item.path == book.sourceKey).firstOrNull?.item;

  // ---- writing

  @override
  String? nextNumber(String shelfId) => cdsDivision(shelfId) == null ? null : cdsCallText(shelfId, _next[shelfId] ?? 1);

  /// The number [book] would get on [shelfId]: one call number across all of the person's Bookshelves.
  String? nextNumberFor(ShelfBook book, String shelfId) => nextNumber(shelfId);

  Future<String> _dev() async => await _devOrNull() ?? (throw StateError('no device id to write the Bookshelves log as'));

  /// Appends [events] to this device's file of the Bookshelves log and reads the books again.
  Future<void> _append(List<Map<String, dynamic>> events) async {
    if (events.isEmpty) return;
    final calls = _calls;
    final dir = _dir ??= await _dirOf();
    if (calls == null || dir == null || _readOnly) throw StateError('the Bookshelves cannot be written here');
    final dev = await _dev();
    final at = _clock();
    await calls.append({'dir': dir.path, 'dev': dev, 'events': [for (final e in events) {'at': at, ...e}]});
    _signature = '';
    await _read();
  }

  _ViewBook _vb(ShelfBook b) => _view[b.id] ?? _view[_byCopy[b.id]] ?? (throw StateError('the book is not on the Bookshelves'));

  /// Writes the events of a set of moves (each book: to a division, or back to Unsorted with null) and reads the books again.
  /// Each move is against the book's numbered copy: `place`, `retire` (its old number), `assign`; Unsorted is `unsort`, `retire`.
  Future<List<PlacedBook>> _write(List<(ShelfBook, String?)> moves, {required String by}) async {
    final next = Map<String, int>.of(_next);
    final events = <Map<String, dynamic>>[];
    final placed = <PlacedBook>[];
    for (final (b, to) in moves) {
      final vb = _view[b.id] ?? _view[_byCopy[b.id]];
      if (vb == null) continue;
      final copy = vb.numbered;
      final call = vb.call;
      final retire = call == null ? null : {'ev': 'retire', 'copy': copy, 'div': call['div'], 'seq': call['seq']};
      if (to == null) {
        events.add({'ev': 'unsort', 'copy': copy, 'by': by});
        if (retire != null) events.add(retire);
        continue;
      }
      final seq = next[to] ?? 1;
      next[to] = seq + 1;
      events
        ..add({'ev': 'place', 'copy': copy, 'div': to, 'by': by})
        ..addAll([?retire])
        ..add({'ev': 'assign', 'copy': copy, 'div': to, 'seq': seq});
      placed.add(PlacedBook(before: b, shelf: to, callNumber: cdsCallText(to, seq)));
    }
    await _append(events);
    // The numbers as the logs now resolve them (a clash with another device's claim shows its suffix).
    return [
      for (final p in placed) PlacedBook(before: p.before, shelf: p.shelf, callNumber: book(p.before.id)?.callNumber ?? p.callNumber),
    ];
  }

  @override
  Future<Placement> place(List<(ShelfBook, String)> moves) async => Placement(await _write([for (final m in moves) (m.$1, m.$2)], by: 'user'));

  @override
  Future<void> undo(Placement placement) async {
    await _write([
      for (final p in placement.books)
        if (book(p.before.id) case final now?) (now, p.before.shelf),
    ], by: 'user');
  }

  /// Back to Unsorted (`unsort`, and its number retired); the book stays in its library.
  @override
  Future<void> unsort(ShelfBook book) => _write([(book, null)], by: 'user');

  @override
  Future<void> readInstead(ShelfBook book, String copy) => _append([{'ev': 'prefer', 'copy': copy}]);

  @override
  Future<void> notSame(ShelfBook book, String copy) {
    // apart from every other file of the book, so it stands alone whatever linked them
    final others = [for (final c in _vb(book).copies) if (c['copy'] != copy) c['copy'] as String];
    return _append([for (final o in others) {'ev': 'notsame', 'copy': copy, 'with': o, 'by': 'user'}]);
  }

  @override
  Future<ShelfBook?> sameAs(ShelfBook book, ShelfBook other) async {
    final a = _vb(book).reading, b = _vb(other).reading;
    if (a == b) return this.book(book.id);
    await _append([{'ev': 'same', 'copy': a, 'with': b, 'by': 'user', 'how': 'user'}]);
    return this.book(a);
  }

  @override
  Future<void> unjoin(ShelfBook book, ShelfBook other) {
    final a = book.reading ?? book.id, b = other.reading ?? other.id;
    return _append([{'ev': 'notsame', 'copy': a, 'with': b, 'by': 'user'}]);
  }

  @override
  Future<void> retitle(ShelfBook book, String title) => _append([{'ev': 'title', 'copy': _vb(book).reading, 'title': title}]);

  @override
  Future<void> hide(ShelfBook book, {bool hidden = true}) => _append([{'ev': hidden ? 'remove' : 'restore', 'copy': _vb(book).reading}]);

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    libraries?.removeListener(_onLibraries);
    super.dispose();
  }
}

extension on String {
  String? get emptyToNull => isEmpty ? null : this;
}
