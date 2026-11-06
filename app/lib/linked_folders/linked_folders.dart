import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../browse/web/device_api.dart' show DeviceException, kDeviceCallTimeout;

class LinkedLibraryTarget {
  const LinkedLibraryTarget(this.id, this.title);
  final String id, title;
  factory LinkedLibraryTarget.fromJson(Map<String, dynamic> j) =>
      LinkedLibraryTarget(
        (j['id'] ?? j['name'] ?? '').toString(),
        (j['title'] ?? j['name'] ?? j['id'] ?? '').toString(),
      );
}

class LinkedRoot {
  const LinkedRoot({
    required this.id,
    required this.label,
    required this.path,
    required this.mode,
    this.exclusions = const [],
    this.paused = false,
  });
  final String id, label, path, mode;
  final List<String> exclusions;
  final bool paused;
  factory LinkedRoot.fromJson(Map<String, dynamic> j) => LinkedRoot(
    id: '${j['id'] ?? ''}',
    label: '${j['label'] ?? ''}',
    path: '${j['path'] ?? ''}',
    mode: '${j['mode'] ?? 'keep'}',
    exclusions: _strings(j['exclusions']),
    paused: j['paused'] == true,
  );
}

class LinkedLocation {
  const LinkedLocation(this.rootId, this.path, this.available);
  final String rootId, path;
  final bool available;
  factory LinkedLocation.fromJson(Map<String, dynamic> j) => LinkedLocation(
    '${j['root_id'] ?? ''}',
    '${j['relative_path'] ?? ''}',
    j['available'] == true,
  );
}

class LinkedBook {
  const LinkedBook(
    this.id,
    this.title,
    this.locations, {
    this.pendingIndexing = false,
    this.pendingReason,
  });
  final String id, title;
  final List<LinkedLocation> locations;
  final bool pendingIndexing;
  final String? pendingReason;
  factory LinkedBook.fromJson(Map<String, dynamic> j) {
    final locations = [
      for (final x in _maps(j['locations'])) LinkedLocation.fromJson(x),
    ];
    final documentId = j['doc_id'];
    final hash = j['blake3'];
    final rawTitle = j['title'];
    final locationTitle = locations
        .map((location) => location.path.trim())
        .where((path) => path.isNotEmpty)
        .firstOrNull;
    final title = rawTitle is String && rawTitle.trim().isNotEmpty
        ? rawTitle
        : locationTitle ?? 'Untitled PDF';
    return LinkedBook(
      documentId is String && documentId.isNotEmpty
          ? documentId
          : hash is String && hash.isNotEmpty
          ? hash
          : locationTitle ?? 'unknown-book',
      title,
      locations,
      pendingIndexing: j['pending_indexing'] == true,
      pendingReason: j['pending_reason']?.toString(),
    );
  }
}

class LinkedCounts {
  const LinkedCounts({
    this.rootsSeen,
    this.filesSeen,
    this.filesHashed,
    this.bytesHashed,
    this.matchedUniqueIds,
    this.matchedLocations,
    this.unmatchedIdentity,
    this.settlingFileCount,
    this.errors,
  });
  final int? rootsSeen,
      filesSeen,
      filesHashed,
      bytesHashed,
      matchedUniqueIds,
      matchedLocations,
      unmatchedIdentity,
      settlingFileCount,
      errors;
  factory LinkedCounts.fromJson(Object? v) {
    final j = v is Map ? v : const {};
    int? n(String k) => j[k] is num ? (j[k] as num).toInt() : null;
    return LinkedCounts(
      rootsSeen: n('roots_seen'),
      filesSeen: n('files_seen'),
      filesHashed: n('files_hashed'),
      bytesHashed: n('bytes_hashed'),
      matchedUniqueIds: n('matched_unique_ids'),
      matchedLocations: n('matched_locations'),
      unmatchedIdentity: n('unmatched_identity'),
      settlingFileCount: n('settling_file_count'),
      errors: n('errors'),
    );
  }
}

class LinkedJob {
  const LinkedJob(
    this.id,
    this.state, {
    this.stage,
    this.rootId,
    this.pausedForFuture = false,
    this.counts = const LinkedCounts(),
    this.error,
    this.roots = const [],
    this.lastAttemptAt,
    this.lastSuccessfulAt,
  });
  final String id, state;
  final String? stage, rootId, error, lastAttemptAt, lastSuccessfulAt;
  final bool pausedForFuture;
  final LinkedCounts counts;
  final List<Map<String, dynamic>> roots;
  bool get active => state == 'queued' || state == 'running';
  factory LinkedJob.fromJson(Map<String, dynamic> j) {
    final s = j['scope'] is Map ? j['scope'] as Map : const {};
    final e = j['error'];
    return LinkedJob(
      '${j['job_id'] ?? ''}',
      '${j['state'] ?? 'unknown'}',
      stage: j['stage']?.toString(),
      rootId: s['root_id']?.toString(),
      pausedForFuture: j['paused_for_future'] == true,
      counts: LinkedCounts.fromJson(j['counts']),
      error: _errorWords(e),
      roots: j['roots'] is List
          ? (j['roots'] as List)
                .whereType<Map>()
                .map((x) => x.cast<String, dynamic>())
                .toList()
          : const [],
      lastAttemptAt: j['last_attempt_at']?.toString(),
      lastSuccessfulAt: j['last_successful_at']?.toString(),
    );
  }
}

class LinkedFolderSnapshot {
  const LinkedFolderSnapshot(this.roots, this.books);
  final List<LinkedRoot> roots;
  final List<LinkedBook> books;
  factory LinkedFolderSnapshot.fromJson(Map<String, dynamic> j) {
    final c = j['local_config'] is Map
        ? (j['local_config'] as Map).cast<String, dynamic>()
        : j;
    return LinkedFolderSnapshot(
      [for (final x in _maps(c['roots'])) LinkedRoot.fromJson(x)],
      [for (final x in _maps(c['books'])) LinkedBook.fromJson(x)],
    );
  }
}

String? _errorWords(Object? error) {
  if (error == null) return null;
  final value = error is Map
      ? (error['message'] ?? error['code'])?.toString()
      : error.toString();
  return switch (value) {
    'permission_denied' =>
      'Cache cannot read this folder. Restore access and try again.',
    'root_unavailable' => 'This folder cannot be reached right now.',
    'not_found' => 'The linked folder or file is no longer available.',
    'invalid_path' =>
      'The folder path could not be used. Check it and try again.',
    'invalid_state' =>
      'This folder cannot be checked right now. Refresh and try again.',
    'io_error' => 'Cache could not read a file. Check access and try again.',
    'interrupted' => 'The check stopped before it finished. Try again.',
    'unsafe_path' => 'This folder path cannot be used safely.',
    'invalid_data' => 'Cache could not read information about this folder.',
    'path_encoding' => 'A file name in this folder could not be read.',
    'invalid_exclusion' => 'An excluded folder path is invalid.',
    'file_changing' =>
      'This file is still changing. Cache will check it again.',
    _ => value,
  };
}

List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? [
        for (final x in v)
          if (x is Map) x.cast<String, dynamic>(),
      ]
    : const [];
List<String> _strings(Object? v) =>
    v is List ? v.map((e) => e.toString()).toList() : const [];

class LinkedFolderApi {
  LinkedFolderApi({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;
  final http.Client _client;
  final bool _ownsClient;
  void dispose() {
    if (_ownsClient) _client.close();
  }

  static String _id(String s) => Uri.encodeComponent(s);
  Future<dynamic> _call(String method, String path, {Object? body}) async {
    final request = http.Request(method, Uri.parse(path));
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(kDeviceCallTimeout),
      ).timeout(kDeviceCallTimeout);
    } catch (_) {
      throw const DeviceException(
        'unreachable',
        'This device could not be reached.',
      );
    }
    if (response.statusCode == 401) {
      throw const DeviceException(
        'unauthorized',
        'Sign in again.',
        status: 401,
      );
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {}
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = json is Map ? json['error'] : null;
      if (error is Map) {
        throw DeviceException(
          (error['code'] ?? 'failed').toString(),
          (error['message'] ?? '').toString(),
          status: response.statusCode,
        );
      }
      throw DeviceException(
        'failed',
        'This device answered ${response.statusCode}.',
        status: response.statusCode,
      );
    }
    if (json is Map && json['ok'] == true) return json['result'];
    throw const DeviceException(
      'failed',
      'Unexpected response from this device.',
    );
  }

  Map<String, dynamic> _map(Object? v) => (v as Map).cast<String, dynamic>();
  Future<List<LinkedLibraryTarget>> libraries() async {
    final x = await _call('GET', '/api/linked-folders/libraries');
    return [for (final j in x as List) LinkedLibraryTarget.fromJson(_map(j))];
  }

  Future<LinkedFolderSnapshot> getLibrary(String l) async =>
      LinkedFolderSnapshot.fromJson(
        _map(await _call('GET', '/api/linked-folders/${_id(l)}')),
      );
  Future<Map<String, dynamic>> preview(String p, List<String> e) async => _map(
    await _call(
      'POST',
      '/api/linked-folders/preview',
      body: {'root': p, 'exclusions': e},
    ),
  );
  Future<Map<String, dynamic>> register(
    String l, {
    required String id,
    required String label,
    required String path,
    required List<String> exclusions,
  }) async => _map(
    await _call(
      'POST',
      '/api/linked-folders/${_id(l)}',
      body: {
        'id': id,
        'label': label,
        'mode': 'keep',
        'root': path,
        'exclusions': exclusions,
      },
    ),
  );
  Future<LinkedJob> check(String l, {String? rootId}) async =>
      LinkedJob.fromJson(
        _map(
          await _call(
            'POST',
            '/api/linked-folders/${_id(l)}/checks',
            body: {'root_id': ?rootId},
          ),
        ),
      );
  Future<({LinkedJob? active, LinkedJob? latest})> checks(String l) async {
    final j = _map(await _call('GET', '/api/linked-folders/${_id(l)}/checks'));
    return (
      active: j['active'] is Map ? LinkedJob.fromJson(_map(j['active'])) : null,
      latest: j['latest'] is Map ? LinkedJob.fromJson(_map(j['latest'])) : null,
    );
  }

  Future<void> pause(String l, String r) =>
      _call('POST', '/api/linked-folders/${_id(l)}/${_id(r)}/pause');
  Future<void> resume(String l, String r) =>
      _call('POST', '/api/linked-folders/${_id(l)}/${_id(r)}/resume');
  Future<void> unlink(String l, String r) =>
      _call('DELETE', '/api/linked-folders/${_id(l)}/${_id(r)}');
}

class LinkedFolderController extends ChangeNotifier {
  LinkedFolderController({
    required this.api,
    this.pollEvery = const Duration(seconds: 2),
  });
  final LinkedFolderApi api;
  final Duration pollEvery;
  LinkedFolderSnapshot? snapshot;
  LinkedJob? activeJob, latestJob;
  List<LinkedLibraryTarget> targets = const [];
  String? error;
  bool loading = false, busy = false, actionBusy = false;
  Timer? _timer;
  String? _watching;
  bool _disposed = false;
  int _generation = 0;
  int _targetGeneration = 0;
  int? _pollingGeneration;
  int? _actionGeneration;

  bool _current(String libraryId, int generation) =>
      !_disposed &&
      generation == _generation &&
      (_watching == null || _watching == libraryId);

  Future<void> loadTargets() async {
    if (_disposed) return;
    final generation = ++_targetGeneration;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final next = await api.libraries();
      if (!_disposed && generation == _targetGeneration) targets = next;
    } on DeviceException catch (e) {
      if (!_disposed && generation == _targetGeneration) error = _words(e);
    } finally {
      if (!_disposed && generation == _targetGeneration) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh(String libraryId) async {
    if (_disposed ||
        actionBusy ||
        (_watching != null && _watching != libraryId)) {
      return;
    }
    final generation = ++_generation;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final jobs = await api.checks(libraryId);
      if (!_current(libraryId, generation)) return;
      final nextSnapshot = await api.getLibrary(libraryId);
      if (!_current(libraryId, generation)) return;
      snapshot = nextSnapshot;
      activeJob = jobs.active;
      latestJob = jobs.latest;
    } on DeviceException catch (e) {
      if (_current(libraryId, generation)) error = _words(e);
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        notifyListeners();
      }
    }
    _schedule(libraryId, generation);
  }

  void watch(String libraryId) {
    if (_disposed) return;
    _timer?.cancel();
    if (_watching != libraryId) {
      _generation++;
      busy = false;
      actionBusy = false;
      _actionGeneration = null;
      error = null;
      snapshot = null;
      activeJob = null;
      latestJob = null;
      _watching = libraryId;
      notifyListeners();
    }
    unawaited(refresh(libraryId));
  }

  void unwatch(String libraryId, {bool notify = true}) {
    if (_disposed || _watching != libraryId) return;
    _watching = null;
    _generation++;
    _timer?.cancel();
    _timer = null;
    busy = false;
    actionBusy = false;
    _actionGeneration = null;
    if (notify) notifyListeners();
  }

  Future<void> _poll(String libraryId, int generation) async {
    if (!_current(libraryId, generation) || _pollingGeneration == generation) {
      return;
    }
    _pollingGeneration = generation;
    final wasActive = activeJob?.active == true;
    try {
      final jobs = await api.checks(libraryId);
      if (!_current(libraryId, generation)) return;
      activeJob = jobs.active;
      latestJob = jobs.latest;
      error = null;
      if (wasActive && activeJob?.active != true) {
        final nextSnapshot = await api.getLibrary(libraryId);
        if (!_current(libraryId, generation)) return;
        snapshot = nextSnapshot;
      }
    } on DeviceException catch (e) {
      if (_current(libraryId, generation)) error = _words(e);
    } finally {
      if (_pollingGeneration == generation) _pollingGeneration = null;
      if (_current(libraryId, generation)) notifyListeners();
    }
    _schedule(libraryId, generation);
  }

  void _schedule(String libraryId, int generation) {
    if (!_current(libraryId, generation) || _watching != libraryId) return;
    _timer?.cancel();
    if (activeJob?.active == true) {
      _timer = Timer(pollEvery, () => _poll(libraryId, generation));
    }
  }

  Future<Map<String, dynamic>> preview(String p, List<String> e) =>
      api.preview(p, e);
  Future<Map<String, dynamic>> register(
    String l, {
    required String id,
    required String label,
    required String path,
    required List<String> exclusions,
  }) =>
      api.register(l, id: id, label: label, path: path, exclusions: exclusions);
  Future<void> checkNow(String libraryId, {String? rootId}) async {
    if (actionBusy ||
        _disposed ||
        (_watching != null && _watching != libraryId)) {
      return;
    }
    final generation = ++_generation;
    _timer?.cancel();
    busy = false;
    actionBusy = true;
    _actionGeneration = generation;
    error = null;
    notifyListeners();
    try {
      final job = await api.check(libraryId, rootId: rootId);
      if (_current(libraryId, generation)) {
        activeJob = job;
        latestJob = job;
      }
    } on DeviceException catch (e) {
      if (_current(libraryId, generation)) error = _words(e);
    } finally {
      if (!_disposed && _actionGeneration == generation) {
        actionBusy = false;
        _actionGeneration = null;
        notifyListeners();
      }
    }
    _schedule(libraryId, generation);
  }

  Future<void> pause(String l, String r) async {
    await _control(l, () => api.pause(l, r));
  }

  Future<void> resume(String l, String r) async {
    await _control(l, () => api.resume(l, r));
  }

  Future<void> unlink(String l, String r) async {
    await _control(l, () => api.unlink(l, r));
  }

  Future<void> _control(String libraryId, Future<void> Function() call) async {
    if (actionBusy ||
        _disposed ||
        (_watching != null && _watching != libraryId)) {
      return;
    }
    final generation = ++_generation;
    _timer?.cancel();
    busy = false;
    actionBusy = true;
    _actionGeneration = generation;
    error = null;
    notifyListeners();
    var failed = false;
    try {
      await call();
    } on DeviceException catch (e) {
      failed = true;
      if (_current(libraryId, generation)) error = _words(e);
    } finally {
      if (!_disposed && _actionGeneration == generation) {
        actionBusy = false;
        _actionGeneration = null;
      }
    }
    if (_current(libraryId, generation)) {
      if (failed) {
        notifyListeners();
        _schedule(libraryId, generation);
      } else {
        await refresh(libraryId);
      }
    }
  }

  static String _words(DeviceException e) => e.status == 409
      ? 'This folder has a check in progress. Wait for it to finish, then try again.'
      : e.message.isEmpty
      ? 'This device could not complete that action. Try again.'
      : e.message;
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    api.dispose();
    super.dispose();
  }
}
