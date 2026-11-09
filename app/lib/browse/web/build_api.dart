import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'device_api.dart' show DeviceException, kDeviceCallTimeout;

/// A library built from PDFs on this device (`GET /api/build/libraries`).
class BuildLibrary {
  const BuildLibrary({
    required this.id,
    required this.title,
    this.books = 0,
    this.passages = 0,
    this.pages = 0,
    this.createdAt,
    this.published = false,
    this.dirty = false,
    this.waiting = 0,
    this.building = false,
    this.publishError,
  });

  final String id;
  final String title;
  final int books;
  final int passages;
  final int pages;
  final DateTime? createdAt;
  final bool published;

  /// Built books that are not searchable yet.
  final bool dirty;
  /// Books of this library that are waiting or being built.
  final int waiting;

  /// A book of it is being built now.
  final bool building;
  final String? publishError;

  static BuildLibrary fromJson(Map<String, dynamic> j) => BuildLibrary(
        id: j['id'] as String,
        title: (j['title'] ?? '') as String,
        books: (j['books'] as num?)?.toInt() ?? 0,
        passages: (j['passages'] as num?)?.toInt() ?? 0,
        pages: (j['pages'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse((j['created_at'] ?? '') as String),
        published: j['published'] == true,
        dirty: j['dirty'] == true,
        waiting: (j['waiting'] as num?)?.toInt() ?? 0,
        building: j['building'] == true,
        publishError: j['publish_error'] as String?,
      );
}

/// One book of a built library.
class BuildBook {
  const BuildBook({
    required this.id,
    required this.title,
    this.docVersion = 1,
    this.pages = 0,
    this.passages = 0,
    this.ocrPages = 0,
    this.partial,
    this.fileName = '',
    this.size = 0,
    this.addedAt,
    this.status = 'ready',
    this.division,
    this.callNumber,
    this.unsureReason,
    this.suggestions = const [],
    this.compression,

  });

  final String id;
  final String title;
  final int docVersion;
  final int pages;
  final int passages;
  final int ocrPages;
  final String? partial;
  final String fileName;
  final int size;
  final DateTime? addedAt;

  /// `ready` or `replacing`.
  final String status;
  final String? division;
  final String? callNumber;
  final String? unsureReason;
  final List<BuildSuggestion> suggestions;
  final Map<String, dynamic>? compression;
  bool get unsorted => division == null;


  bool get replacing => status == 'replacing';

  /// The file name without its ending: what "Use file name" gives.
  String get fileStem => fileName.toLowerCase().endsWith('.pdf') ? fileName.substring(0, fileName.length - 4) : fileName;

  static BuildBook fromJson(Map<String, dynamic> j) => BuildBook(
        id: j['id'] as String,
        title: (j['title'] ?? '') as String,
        docVersion: (j['doc_version'] as num?)?.toInt() ?? 1,
        pages: (j['pages'] as num?)?.toInt() ?? 0,
        passages: (j['passages'] as num?)?.toInt() ?? 0,
        ocrPages: (j['ocr_pages'] as num?)?.toInt() ?? 0,
        partial: j['partial'] as String?,
        fileName: (j['file_name'] ?? '') as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        addedAt: DateTime.tryParse((j['added_at'] ?? '') as String),
        status: (j['status'] ?? 'ready') as String,
        division: j['division'] as String?,
        callNumber: j['call_number'] as String?,
        unsureReason: j['unsure_reason'] as String?,
        suggestions: [for (final v in (j['suggestions'] as List? ?? const [])) BuildSuggestion.fromJson((v as Map).cast<String, dynamic>())],
        compression: (j['compression'] as Map?)?.cast<String, dynamic>(),

      );
}

/// What the book is doing in the queue.
class QueueProgress {
  const QueueProgress({this.pages = 0, this.pieces = 0, this.piecesTotal, this.ocrPages = 0});

  final int pages;
  final int pieces;
  final int? piecesTotal;
  final int ocrPages;

  static QueueProgress fromJson(Object? j) {
    if (j is! Map) return const QueueProgress();
    return QueueProgress(
      pages: (j['pages'] as num?)?.toInt() ?? 0,
      pieces: (j['pieces'] as num?)?.toInt() ?? 0,
      piecesTotal: (j['pieces_total'] as num?)?.toInt(),
      ocrPages: (j['ocr_pages'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One book in the queue (`GET /api/build/queue`).
class QueueItem {
  const QueueItem({
    required this.id,
    required this.libraryId,
    required this.fileName,
    this.title,
    required this.state,
    this.size = 0,
    this.progress = const QueueProgress(),
    this.error,
    this.note,
    this.replace,
    this.docId,
    this.duplicateOf,
    this.drop = false,
    this.position,
    this.createdAt,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String libraryId;
  final String fileName;
  final String? title;

  /// `queued`, `reading`, `building`, `done`, `skipped_duplicate`, `failed` or `ocr_needed`.
  final String state;
  final int size;
  final QueueProgress progress;
  final String? error;
  final String? note;
  final String? replace;
  final String? docId;
  final String? duplicateOf;
  final bool drop;
  final int? position;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  String get name => (title != null && title!.isNotEmpty) ? title! : fileName;
  bool get active => state == 'reading' || state == 'building';
  bool get waiting => state == 'queued';
  bool get needsAttention => state == 'failed' || state == 'ocr_needed';
  bool get skipped => state == 'skipped_duplicate';
  bool get finished => state == 'done' || skipped || needsAttention;

  static QueueItem fromJson(Map<String, dynamic> j) => QueueItem(
        id: j['id'] as String,
        libraryId: (j['library_id'] ?? '') as String,
        fileName: (j['file_name'] ?? '') as String,
        title: j['title'] as String?,
        state: (j['state'] ?? 'queued') as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        progress: QueueProgress.fromJson(j['progress']),
        error: j['error'] as String?,
        note: j['note'] as String?,
        replace: j['replace'] as String?,
        docId: j['doc_id'] as String?,
        duplicateOf: j['duplicate_of'] as String?,
        drop: j['drop'] == true,
        position: (j['position'] as num?)?.toInt(),
        createdAt: DateTime.tryParse((j['created_at'] ?? '') as String),
        startedAt: DateTime.tryParse((j['started_at'] ?? '') as String),
        finishedAt: DateTime.tryParse((j['finished_at'] ?? '') as String),
      );
}

class QueueCounts {
  const QueueCounts({this.total = 0, this.waiting = 0, this.working = 0, this.done = 0, this.skipped = 0, this.failed = 0, this.ocrNeeded = 0});

  final int total;
  final int waiting;
  final int working;
  final int done;
  final int skipped;
  final int failed;
  final int ocrNeeded;

  static QueueCounts fromJson(Object? j) {
    if (j is! Map) return const QueueCounts();
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return QueueCounts(total: n('total'), waiting: n('waiting'), working: n('working'), done: n('done'), skipped: n('skipped'), failed: n('failed'), ocrNeeded: n('ocr_needed'));
  }
}

/// The whole build queue.
class BuildQueue {
  const BuildQueue({this.paused = false, this.blocked, this.counts = const QueueCounts(), this.etaLow, this.etaHigh, this.items = const []});

  final bool paused;

  /// "waiting for the search model" while building cannot start; null otherwise.
  final String? blocked;
  final QueueCounts counts;
  final int? etaLow;
  final int? etaHigh;
  final List<QueueItem> items;

  bool get idle => !items.any((i) => !i.finished);

  static BuildQueue fromJson(Map<String, dynamic> j) {
    final eta = j['eta'];
    return BuildQueue(
      paused: j['paused'] == true,
      blocked: j['blocked'] as String?,
      counts: QueueCounts.fromJson(j['counts']),
      etaLow: eta is Map ? (eta['low_seconds'] as num?)?.toInt() : null,
      etaHigh: eta is Map ? (eta['high_seconds'] as num?)?.toInt() : null,
      items: [for (final i in (j['items'] as List? ?? const [])) QueueItem.fromJson((i as Map).cast<String, dynamic>())],
    );
  }
}

/// A file in the drop folder's three subfolders.
class DropFile {
  const DropFile({required this.name, required this.folder, required this.state, this.position, this.size = 0, this.progress, this.itemId, this.reason, this.canRetry = false, this.note});

  final String name;

  /// `ingest`, `complete` or `failed`.
  final String folder;

  /// `new`, `queued`, `working`, `failed`, `done`, `duplicate` or `unsupported`.
  final String state;
  final int? position;
  final int size;
  final QueueProgress? progress;
  final String? itemId;
  final String? reason;
  final bool canRetry;
  final String? note;

  static DropFile fromJson(Map<String, dynamic> j) => DropFile(
        name: (j['name'] ?? '') as String,
        folder: (j['folder'] ?? 'ingest') as String,
        state: (j['state'] ?? 'new') as String,
        position: (j['position'] as num?)?.toInt(),
        size: (j['size'] as num?)?.toInt() ?? 0,
        progress: j['progress'] is Map ? QueueProgress.fromJson(j['progress']) : null,
        itemId: j['item_id'] as String?,
        reason: j['reason'] as String?,
        canRetry: j['can_retry'] == true,
        note: j['note'] as String?,
      );
}

class DropSettings {
  const DropSettings({this.folder = '', this.enabled = false, this.libraryId, this.libraryTitle});

  final String folder;
  final bool enabled;
  final String? libraryId;
  final String? libraryTitle;

  static DropSettings fromJson(Object? j) {
    if (j is! Map) return const DropSettings();
    return DropSettings(folder: (j['folder'] ?? '') as String, enabled: j['enabled'] == true, libraryId: j['library_id'] as String?, libraryTitle: j['library_title'] as String?);
  }
}

class DropError {
  const DropError(this.code, this.message);

  /// `missing`, `denied`, `error` or `no_library`.
  final String code;
  final String message;
}

class DropStatus {
  const DropStatus({this.state = 'off', this.lastCheck, this.found = 0, this.all = 0, this.queue = 0, this.complete = 0, this.failed = 0, this.error, this.stale = false});

  /// `off`, `ok` or `error`.
  final String state;
  final DateTime? lastCheck;
  final int found;
  final int all;
  final int queue;
  final int complete;
  final int failed;
  final DropError? error;
  final bool stale;

  static DropStatus fromJson(Object? j) {
    if (j is! Map) return const DropStatus();
    final c = j['counts'];
    int n(String k) => c is Map ? (c[k] as num?)?.toInt() ?? 0 : 0;
    final e = j['error'];
    return DropStatus(
      state: (j['state'] ?? 'off') as String,
      lastCheck: DateTime.tryParse((j['last_check'] ?? '') as String),
      found: (j['found'] as num?)?.toInt() ?? 0,
      all: n('all'),
      queue: n('queue'),
      complete: n('complete'),
      failed: n('failed'),
      error: e is Map ? DropError((e['code'] ?? 'error').toString(), (e['message'] ?? '').toString()) : null,
      stale: j['stale'] == true,
    );
  }
}

class DropState {
  const DropState({this.settings = const DropSettings(), this.status = const DropStatus(), this.files = const []});

  final DropSettings settings;
  final DropStatus status;
  final List<DropFile> files;

  static DropState fromJson(Map<String, dynamic> j) => DropState(
        settings: DropSettings.fromJson(j['settings']),
        status: DropStatus.fromJson(j['status']),
        files: [for (final f in (j['files'] as List? ?? const [])) DropFile.fromJson((f as Map).cast<String, dynamic>())],
      );
}


class CompressionChoice {
  const CompressionChoice._(this.level, this.preset);

  static const off = CompressionChoice._('off', null);
  static const lossless = CompressionChoice._('lossless', null);
  static const high = CompressionChoice._('smaller_scans', 'high');
  static const balanced = CompressionChoice._('smaller_scans', 'balanced');
  static const smallest = CompressionChoice._('smaller_scans', 'smallest');

  final String level;
  final String? preset;
  String get label => switch (level) {
        'off' => 'Off',
        'lossless' => 'Smaller file, pages unchanged',
        _ => 'Smaller scans',
      };

  String get summaryLabel => level == 'smaller_scans'
      ? 'Smaller scans: ${switch (preset) { 'high' => 'High quality', 'smallest' => 'Smallest', _ => 'Balanced' }}'
      : label;

  Map<String, dynamic> toJson() => {'level': level, if (preset != null) 'preset': preset};

  static CompressionChoice fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid compression choice');
    final level = value['level'];
    final preset = value['preset'];
    if (level == 'off') return off;
    if (level == 'lossless') return lossless;
    if (level == 'smaller_scans') {
      return switch (preset) { 'high' => high, 'balanced' || null => balanced, 'smallest' => smallest, _ => throw const FormatException('Invalid compression preset') };
    }
    throw const FormatException('Invalid compression level');
  }

  @override
  bool operator ==(Object other) => other is CompressionChoice && other.level == level && other.preset == preset;
  @override
  int get hashCode => Object.hash(level, preset);
}

class BuildCompressionSettings {
  const BuildCompressionSettings({this.compression = CompressionChoice.lossless, this.askWhenOne = true});
  final CompressionChoice compression;
  final bool askWhenOne;

  factory BuildCompressionSettings.fromJson(Map<String, dynamic> json) => BuildCompressionSettings(
        compression: CompressionChoice.fromJson(json['compression']),
        askWhenOne: json['ask_when_one'] == true,
      );

  Map<String, dynamic> toJson() => {'compression': compression.toJson(), 'ask_when_one': askWhenOne};
}

/// Optional settings API so existing BuildApi fakes do not need new methods.
abstract interface class BuildCompressionApi implements BuildApi {
  Future<BuildCompressionSettings> getCompressionSettings();
  Future<BuildCompressionSettings> putCompressionSettings(BuildCompressionSettings settings);
}

/// What the browser can ask of the device about building libraries from PDFs (`/api/build/...`). A class so tests can answer for it.
abstract class BuildApi {
  Future<List<BuildLibrary>> libraries();
  Future<BuildLibrary> createLibrary(String title);
  Future<BuildLibrary> renameLibrary(String id, String title);
  Future<List<BuildBook>> books(String libraryId);
  Future<void> renameBook(String libraryId, String docId, String title);
  Future<void> removeBook(String libraryId, String docId);

  Future<BuildQueue> queue();
  Future<BuildQueue> pause();
  Future<BuildQueue> resume();

  /// Takes the waiting books off the list; the book being built finishes.
  Future<BuildQueue> stop();
  Future<BuildQueue> retry(String itemId);
  Future<BuildQueue> dismiss(String itemId);

  Future<DropState> drop();

  /// Any of the folder, whether it is on and the library the PDFs go into.
  Future<DropState> putDrop({String? folder, bool? enabled, String? libraryId});
  Future<DropState> checkDrop();
  Future<DropState> retryDrop(String name);
}

/// Classification functions supported by the Linux library builder.
abstract interface class BuildFilingApi implements BuildApi {
  Future<List<BuildClass>> classes(String libraryId);
  Future<void> placeBook(String libraryId, String bookId, String division);
}

class BuildSuggestion {
  const BuildSuggestion(this.division, this.name);
  final String division;
  final String name;
  factory BuildSuggestion.fromJson(Map<String, dynamic> j) => BuildSuggestion(j['division'] as String, (j['name'] ?? '') as String);
}

class BuildDivision {
  const BuildDivision({required this.number, required this.name, required this.classNumber, this.assigned = true});
  final String number;
  final String name;
  final String classNumber;
  final bool assigned;
}

class BuildClass {
  const BuildClass(this.number, this.name, this.divisions);
  final String number;
  final String name;
  final List<BuildDivision> divisions;
}

/// The browser's [BuildApi]: Cache for Linux's `/api/build/...`, same origin, so the session goes along.
class HttpBuildApi implements BuildFilingApi, BuildCompressionApi {
  HttpBuildApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<dynamic> _call(String method, String path, {Object? body}) async {
    final req = http.Request(method, Uri.parse(path));
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req).timeout(kDeviceCallTimeout)).timeout(kDeviceCallTimeout);
    } catch (_) {
      throw const DeviceException('unreachable', 'This device could not be reached.');
    }
    if (r.statusCode == 401) throw const DeviceException('unauthorized', 'Sign in again.', status: 401);
    Object? j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {}
    if (r.statusCode < 200 || r.statusCode >= 300) {
      final e = j is Map ? j['error'] : null;
      if (e is Map) throw DeviceException((e['code'] ?? 'failed').toString(), (e['message'] ?? '').toString(), status: r.statusCode);
      throw DeviceException('failed', 'This device answered ${r.statusCode}.', status: r.statusCode);
    }
    if (j is Map && j['ok'] == true) return j['result'];
    throw const DeviceException('failed', 'This device answered with something unexpected.');
  }

  static Map<String, dynamic> _map(Object? o) => (o as Map).cast<String, dynamic>();
  static String _id(String s) => Uri.encodeComponent(s);

  @override
  Future<List<BuildLibrary>> libraries() async => [for (final j in (await _call('GET', '/api/build/libraries')) as List) BuildLibrary.fromJson(_map(j))];

  @override
  Future<BuildLibrary> createLibrary(String title) async => BuildLibrary.fromJson(_map(await _call('POST', '/api/build/libraries', body: {'title': title})));

  @override
  Future<BuildLibrary> renameLibrary(String id, String title) async => BuildLibrary.fromJson(_map(await _call('PATCH', '/api/build/libraries/${_id(id)}', body: {'title': title})));

  @override
  Future<List<BuildBook>> books(String libraryId) async => [for (final j in (await _call('GET', '/api/build/libraries/${_id(libraryId)}/books')) as List) BuildBook.fromJson(_map(j))];

  @override
  Future<void> renameBook(String libraryId, String docId, String title) async {
    await _call('PATCH', '/api/build/libraries/${_id(libraryId)}/books/${_id(docId)}', body: {'title': title});
  }

  @override
  Future<void> removeBook(String libraryId, String docId) async {
    await _call('DELETE', '/api/build/libraries/${_id(libraryId)}/books/${_id(docId)}');
  }

  @override
  Future<List<BuildClass>> classes(String libraryId) async {
    final j = _map(await _call('GET', '/api/build/classes?library_id=${_id(libraryId)}'));
    return [
      for (final c in j['classes'] as List)
        BuildClass(c['number'] as String, c['name'] as String, [
          for (final d in c['divisions'] as List)
            BuildDivision(number: d['number'] as String, name: d['name'] as String, classNumber: c['number'] as String, assigned: d['assigned'] == true),
        ]),
    ];
  }

  @override
  Future<void> placeBook(String libraryId, String bookId, String division) async {
    await _call('POST', '/api/build/libraries/${_id(libraryId)}/books/${_id(bookId)}/place', body: {'division': division});
  }

  @override
  Future<BuildQueue> queue() async => BuildQueue.fromJson(_map(await _call('GET', '/api/build/queue')));

  @override
  Future<BuildQueue> pause() async => BuildQueue.fromJson(_map(await _call('POST', '/api/build/queue/pause')));

  @override
  Future<BuildQueue> resume() async => BuildQueue.fromJson(_map(await _call('POST', '/api/build/queue/resume')));

  @override
  Future<BuildQueue> stop() async => BuildQueue.fromJson(_map(await _call('POST', '/api/build/queue/stop')));

  @override
  Future<BuildQueue> retry(String itemId) async => BuildQueue.fromJson(_map(await _call('POST', '/api/build/queue/${_id(itemId)}/retry')));

  @override
  Future<BuildQueue> dismiss(String itemId) async => BuildQueue.fromJson(_map(await _call('DELETE', '/api/build/queue/${_id(itemId)}')));

  @override
  Future<BuildCompressionSettings> getCompressionSettings() async {
    try {
      return BuildCompressionSettings.fromJson(_map(await _call('GET', '/api/build/settings')));
    } on DeviceException {
      rethrow;
    } catch (_) {
      throw const DeviceException('failed', 'This device answered with something unexpected.');
    }
  }

  @override
  Future<BuildCompressionSettings> putCompressionSettings(BuildCompressionSettings settings) async {
    try {
      return BuildCompressionSettings.fromJson(_map(await _call('PUT', '/api/build/settings', body: settings.toJson())));
    } on DeviceException {
      rethrow;
    } catch (_) {
      throw const DeviceException('failed', 'This device answered with something unexpected.');
    }
  }

  @override
  Future<DropState> drop() async => DropState.fromJson(_map(await _call('GET', '/api/build/drop')));

  @override
  Future<DropState> putDrop({String? folder, bool? enabled, String? libraryId}) async => DropState.fromJson(_map(await _call('PUT', '/api/build/drop', body: {
        'folder': ?folder,
        'enabled': ?enabled,
        'library_id': ?libraryId,
      })));

  @override
  Future<DropState> checkDrop() async => DropState.fromJson(_map(await _call('POST', '/api/build/drop/check')));

  @override
  Future<DropState> retryDrop(String name) async => DropState.fromJson(_map(await _call('POST', '/api/build/drop/retry', body: {'name': name})));
}
