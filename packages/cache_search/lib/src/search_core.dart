import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'engine.dart';
import 'errors.dart';
import 'models.dart';
import 'native.dart';

/// Opens the native layer. A function so tests can give the worker a fake; it must be a top-level or
/// static function because it runs inside the worker isolate.
typedef CsNativeFactory = CsNative Function();

CsNative _openNative() => FfiCsNative.open();

/// The search core for the UI: every call runs in a long-lived background isolate that owns the handle
/// (a handle is used from one thread at a time, and open, search, read and the jobs can take time).
class SearchCore {
  SearchCore._(this._isolate, this._toWorker, this._fromWorker);

  /// Starts the worker and opens the core with [sources]. Throws a [CacheSearchException] if the native
  /// library is missing on this platform or cs_open fails. [extra] holds the other sections of the cs_open config
  /// (user, live, places, routing, ...), see cache_search.h.
  static Future<SearchCore> open(List<SourceConfig> sources, {Map<String, dynamic>? extra, CsNativeFactory native = _openNative}) async {
    final rp = ReceivePort();
    final errors = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, [rp.sendPort, native], debugName: 'cache_search', onError: errors.sendPort);
    final events = StreamIterator<dynamic>(rp);
    await events.moveNext();
    final core = SearchCore._(isolate, events.current as SendPort, rp);
    errors.listen((dynamic e) => core._failAll(CacheSearchException('internal', 'The search core crashed: ${(e as List).first}')));
    core._errors = errors;
    // The rest of the worker's messages are replies.
    unawaited(() async {
      while (await events.moveNext()) {
        core._onReply(events.current as Map);
      }
    }());
    try {
      await core._call('open', {'sources': jsonSources(sources), 'extra': extra});
    } catch (_) {
      await core.close();
      rethrow;
    }
    return core;
  }

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  ReceivePort? _errors;
  int _nextId = 1;
  bool _closed = false;
  final Map<int, Completer<dynamic>> _pending = {};

  static List<Map<String, dynamic>> jsonSources(List<SourceConfig> s) => [for (final x in s) x.toJson()];

  void _onReply(Map m) {
    final c = _pending.remove(m['id'] as int);
    if (c == null) return;
    final err = m['error'];
    if (err is List) {
      c.completeError(CacheSearchException(err[0] as String, err[1] as String));
    } else {
      c.complete(m['result']);
    }
  }

  void _failAll(CacheSearchException e) {
    for (final c in _pending.values) {
      c.completeError(e);
    }
    _pending.clear();
  }

  Future<dynamic> _call(String op, [Map<String, dynamic> args = const {}]) {
    if (_closed) return Future.error(const CacheSearchException('internal', 'The search core is closed'));
    final id = _nextId++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _toWorker.send({'id': id, 'op': op, 'args': args});
    return c.future;
  }

  Future<Map<String, dynamic>> version() async => (await _call('version') as Map).cast<String, dynamic>();

  /// Replaces the source list (a ZIM was added or removed).
  Future<void> setSources(List<SourceConfig> sources) => _call('setSources', {'sources': jsonSources(sources)});

  Future<List<SourceStatus>> status() async => [
        for (final s in await _call('status') as List) SourceStatus.fromJson((s as Map).cast<String, dynamic>()),
      ];

  Future<SearchResponse> search(String query, {int k = 5, int offset = 0, List<String>? sources, QueryVector? queryVector}) async =>
      SearchResponse.fromJson(((await _call('search', {
        'query': query,
        'k': k,
        'offset': offset,
        'sources': sources,
        'queryVector': queryVector?.toJson(),
      })) as Map)
          .cast<String, dynamic>());

  Future<ReadResult> read(String address, {int maxChars = 6000}) async =>
      ReadResult.fromJson(((await _call('read', {'address': address, 'maxChars': maxChars})) as Map).cast<String, dynamic>());

  Future<ZimBytes> zimGet(String address) async {
    final r = await _call('zimGet', {'address': address}) as List;
    return ZimBytes(r[0] as Uint8List, r[1] as String);
  }

  Future<String> zimMainPage(String zimId) async => (await _call('zimMainPage', {'zimId': zimId})) as String;

  Future<List<Suggestion>> suggest(String prefix, {int k = 10, List<String>? sources}) async => [
        for (final s in await _call('suggest', {'prefix': prefix, 'k': k, 'sources': sources}) as List)
          Suggestion.fromJson((s as Map).cast<String, dynamic>()),
      ];

  /// A new [n] numbering for one chat. Free it with [CoreConversation.free].
  Future<CoreConversation> newConversation() async => CoreConversation._(this, (await _call('convNew')) as int);

  /// A conversation continued from [CoreConversation.export]'s output, with the same numbering.
  Future<CoreConversation> importConversation(String json) async =>
      CoreConversation._(this, (await _call('convImport', {'json': json})) as int);

  /// The phone's GPS fix for the tools that default to "where I am" (cs_set_location). [fixedAt] is ISO 8601 with an offset.
  Future<void> setLocation(double lat, double lon, {double accuracyM = -1, required String fixedAt}) =>
      _call('setLocation', {'lat': lat, 'lon': lon, 'accuracy': accuracyM, 'fixedAt': fixedAt});

  Future<void> clearLocation() => _call('clearLocation');

  /// Web search settings (cs_set_web); [provider] null turns it off.
  Future<void> setWeb({String? provider, String? key, required bool online}) =>
      _call('setWeb', {'provider': provider, 'key': key, 'online': online});

  /// The function schemas of the tools available now (cs_tool_schemas).
  Future<List<Map<String, dynamic>>> toolSchemas() async =>
      [for (final t in await _call('toolSchemas') as List) (t as Map).cast<String, dynamic>()];

  Future<Map<String, dynamic>> _map(String op, [Map<String, dynamic> args = const {}]) async =>
      ((await _call(op, args)) as Map).cast<String, dynamic>();

  /// Saved places (cs_places_list, cs_place_save, cs_place_delete).
  Future<Map<String, dynamic>> placesList() => _map('placesList');
  Future<Map<String, dynamic>> placeSave(Map<String, dynamic> place) => _map('placeSave', {'place': place});
  Future<Map<String, dynamic>> placeDelete(String key) => _map('placeDelete', {'key': key});

  /// Live data (cs_live_sources, cs_live_fetch, cs_live_get).
  Future<Map<String, dynamic>> liveSources() => _map('liveSources');
  Future<Map<String, dynamic>> liveFetch(Map<String, dynamic> request) => _map('liveFetch', {'request': request});
  Future<Map<String, dynamic>> liveGet(Map<String, dynamic> request) => _map('liveGet', {'request': request});

  /// Starts a long job: kind "index_zim" with {"zim_path","index_dir","heap_mb"} and so on (see cache_search.h).
  Future<CoreJobHandle> startJob(String kind, Map<String, dynamic> params) async =>
      CoreJobHandle._(this, (await _call('jobStart', {'kind': kind, 'params': params})) as int);

  /// Closes the core and ends the worker.
  Future<void> close() async {
    if (_closed) return;
    try {
      await _call('close');
    } catch (_) {}
    _closed = true;
    _failAll(const CacheSearchException('internal', 'The search core is closed'));
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _fromWorker.close();
    _errors?.close();
  }
}

/// One chat's [n] numbering, owned by the core's worker.
class CoreConversation {
  CoreConversation._(this._core, this._id);

  final SearchCore _core;
  final int _id;
  bool _freed = false;

  /// Numbers [results] (search hits as [SearchHit.toFormatJson], or any {address,title,snippet}) and
  /// returns the exact tool message and the id map so far.
  Future<FormattedResults> format(List<Map<String, dynamic>> results) async =>
      FormattedResults.fromJson(((await _core._call('convFormat', {'conv': _id, 'results': results})) as Map).cast<String, dynamic>());

  /// The id map so far, for the citation check.
  Future<List<ConversationId>> ids() async => [
        for (final i in await _core._call('convIds', {'conv': _id}) as List) ConversationId.fromJson((i as Map).cast<String, dynamic>()),
      ];

  /// Runs one tool call in this conversation (cs_tool); its sources are numbered here. A failure of the tool comes back
  /// as its error JSON in [ToolOutput.content], not as an exception. [now] is the local time, ISO 8601 with an offset.
  Future<ToolOutput> tool(String name, Map<String, dynamic> args, {required String now}) async => ToolOutput.fromJson(
      ((await _core._call('convTool', {'conv': _id, 'name': name, 'args': args, 'now': now})) as Map).cast<String, dynamic>());

  /// The conversation's whole state as JSON (cs_conversation_export).
  Future<String> export() async => (await _core._call('convExport', {'conv': _id})) as String;

  Future<void> free() async {
    if (_freed) return;
    _freed = true;
    try {
      await _core._call('convFree', {'conv': _id});
    } catch (_) {}
  }
}

/// A running or finished job.
class CoreJobHandle {
  CoreJobHandle._(this._core, this._id);

  final SearchCore _core;
  final int _id;
  bool _freed = false;

  Future<JobProgress> progress() async =>
      JobProgress.fromJson(((await _core._call('jobProgress', {'job': _id})) as Map).cast<String, dynamic>());

  Future<void> cancel() => _core._call('jobCancel', {'job': _id});

  /// Frees a job that is done, cancelled or failed.
  Future<void> free() async {
    if (_freed) return;
    _freed = true;
    try {
      await _core._call('jobFree', {'job': _id});
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- worker isolate

List<SourceConfig> _sourcesFrom(List<dynamic> list) => [
      for (final s in list)
        (s as Map)['kind'] == 'library'
            ? SourceConfig.library(path: s['path'] as String, indexDir: s['index_dir'] as String, settings: (s['settings'] as Map?)?.cast<String, dynamic>())
            : SourceConfig.zim(path: s['path'] as String, indexDir: s['index_dir'] as String),
    ];

void _workerMain(List<dynamic> init) {
  final toMain = init[0] as SendPort;
  final factory = init[1] as CsNativeFactory;
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  CsNative? native;
  SearchEngine? engine;
  final convs = <int, ConversationNumbers>{};
  final jobs = <int, CoreJob>{};
  var nextKey = 1;

  SearchEngine eng() => engine ?? (throw const CacheSearchException('internal', 'The search core is not open'));

  rp.listen((dynamic m) {
    final msg = m as Map;
    final id = msg['id'] as int;
    final a = (msg['args'] as Map).cast<String, dynamic>();
    try {
      Object? result;
      switch (msg['op']) {
        case 'open':
          native = factory();
          engine = SearchEngine.open(native!, _sourcesFrom(a['sources'] as List), extra: (a['extra'] as Map?)?.cast<String, dynamic>());
        case 'version':
          result = eng().version();
        case 'setSources':
          eng().setSources(_sourcesFrom(a['sources'] as List));
        case 'status':
          result = [
            for (final s in eng().status())
              {
                'id': s.id,
                'kind': s.kind,
                'path': s.path,
                'title': s.title,
                'indexed': s.indexed,
                'building': s.building,
                'stale': s.stale,
                'opening': s.opening,
                'updating': s.updating,
                'docs': s.docs,
                'error': s.error == null ? null : {'code': s.error!.code, 'message': s.error!.message},
              }
          ];
        case 'search':
          final r = eng().search(
            a['query'] as String,
            k: a['k'] as int,
            offset: a['offset'] as int,
            sources: (a['sources'] as List?)?.cast<String>(),
            queryVector: a['queryVector'] == null
                ? null
                : QueryVector((a['queryVector'] as Map)['model'] as String, ((a['queryVector'] as Map)['vector'] as List).cast<double>()),
          );
          result = {
            'results': [
              for (final h in r.results)
                {
                  'address': h.address,
                  'title': h.title,
                  'snippet': h.snippet,
                  'source_id': h.sourceId,
                  'source_kind': h.sourceKind,
                  'source_title': h.sourceTitle,
                  'page': h.page,
                }
            ],
            'total_estimate': r.totalEstimate,
            'vector_sources': r.vectorSources,
            'keyword_only_sources': r.keywordOnlySources,
          };
        case 'read':
          final r = eng().read(a['address'] as String, maxChars: a['maxChars'] as int);
          result = {
            'address': r.address,
            'title': r.title,
            'text': r.text,
            'truncated': r.truncated,
            'author': r.author,
            'page': r.page,
            'source_type': r.sourceType,
          };
        case 'zimGet':
          final z = eng().zimGet(a['address'] as String);
          result = [z.bytes, z.mime];
        case 'zimMainPage':
          result = eng().zimMainPage(a['zimId'] as String);
        case 'suggest':
          result = [
            for (final s in eng().suggest(a['prefix'] as String, k: a['k'] as int, sources: (a['sources'] as List?)?.cast<String>()))
              {'title': s.title, 'address': s.address, 'source_id': s.sourceId}
          ];
        case 'convNew':
          final c = ConversationNumbers.create(native ?? (native = factory()));
          final key = nextKey++;
          convs[key] = c;
          result = key;
        case 'convFormat':
          final f = convs[a['conv']]!.format([for (final r in a['results'] as List) (r as Map).cast<String, dynamic>()]);
          result = {
            'tool_message': f.toolMessage,
            'ids': [for (final i in f.ids) {'n': i.n, 'address': i.address, 'title': i.title}],
          };
        case 'convIds':
          result = [for (final i in convs[a['conv']]!.ids()) {'n': i.n, 'address': i.address, 'title': i.title}];
        case 'convImport':
          final c = ConversationNumbers.import(native ?? (native = factory()), a['json'] as String);
          final key = nextKey++;
          convs[key] = c;
          result = key;
        case 'convExport':
          result = convs[a['conv']]!.export();
        case 'convTool':
          final o = eng().tool(convs[a['conv']]!, a['name'] as String, (a['args'] as Map).cast<String, dynamic>(), now: a['now'] as String);
          result = {
            'content': o.content,
            'ids': [for (final i in o.ids) {'n': i.n, 'address': i.address, 'title': i.title}],
          };
        case 'setLocation':
          eng().setLocation(a['lat'] as double, a['lon'] as double, accuracyM: a['accuracy'] as double, fixedAt: a['fixedAt'] as String);
        case 'clearLocation':
          eng().clearLocation();
        case 'setWeb':
          eng().setWeb(provider: a['provider'] as String?, key: a['key'] as String?, online: a['online'] as bool);
        case 'toolSchemas':
          result = eng().toolSchemas();
        case 'placesList':
          result = eng().placesList();
        case 'placeSave':
          result = eng().placeSave((a['place'] as Map).cast<String, dynamic>());
        case 'placeDelete':
          result = eng().placeDelete(a['key'] as String);
        case 'liveSources':
          result = eng().liveSources();
        case 'liveFetch':
          result = eng().liveFetch((a['request'] as Map).cast<String, dynamic>());
        case 'liveGet':
          result = eng().liveGet((a['request'] as Map).cast<String, dynamic>());
        case 'convFree':
          convs.remove(a['conv'])?.free();
        case 'jobStart':
          final j = CoreJob.start(native ?? (native = factory()), a['kind'] as String, (a['params'] as Map).cast<String, dynamic>());
          final key = nextKey++;
          jobs[key] = j;
          result = key;
        case 'jobProgress':
          final p = jobs[a['job']]!.progress();
          result = {
            'state': p.state.name,
            'done': p.done,
            'total': p.total,
            'error': p.errorCode == null ? null : {'code': p.errorCode, 'message': p.errorMessage},
          };
        case 'jobCancel':
          jobs[a['job']]!.cancel();
        case 'jobFree':
          jobs.remove(a['job'])?.free();
        case 'close':
          for (final c in convs.values) {
            c.free();
          }
          convs.clear();
          for (final j in jobs.values) {
            j.free();
          }
          jobs.clear();
          engine?.close();
          engine = null;
        default:
          throw CacheSearchException('internal', 'Unknown call ${msg['op']}');
      }
      toMain.send({'id': id, 'result': result});
    } on CacheSearchException catch (e) {
      toMain.send({'id': id, 'error': [e.code, e.message]});
    } catch (e) {
      toMain.send({'id': id, 'error': ['internal', e.toString()]});
    }
  });
}
