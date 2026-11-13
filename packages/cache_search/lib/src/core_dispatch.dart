import 'engine.dart';
import 'errors.dart';
import 'models.dart';
import 'native_api.dart';

/// Opens the native layer. A function so tests can give the worker a fake; it must be a top-level or
/// static function because it runs inside the worker isolate.
typedef CsNativeFactory = CsNative Function();

List<SourceConfig> sourcesFrom(List<dynamic> list) => [
      for (final s in list)
        (s as Map)['kind'] == 'library'
            ? SourceConfig.library(path: s['path'] as String, indexDir: s['index_dir'] as String, settings: (s['settings'] as Map?)?.cast<String, dynamic>())
            : SourceConfig.zim(path: s['path'] as String, indexDir: s['index_dir'] as String),
    ];

/// The core's op dispatch: one call `{op, args}` in, its plain map/list/scalar result out (or a thrown [CacheSearchException]).
/// It owns the native handle, the engine, the conversations and the jobs. The phone runs it in the worker isolate and Cache
/// Server runs it in a helper process; both reach it through the same `{id, op, args}` messages. It touches no dart:ffi
/// itself (the native layer comes from [CsNativeFactory]), so it compiles for the web as well.
class CoreDispatcher {
  CoreDispatcher(this.factory);

  final CsNativeFactory factory;

  CsNative? native;
  SearchEngine? engine;
  final convs = <int, ConversationNumbers>{};
  final jobs = <int, CoreJob>{};
  var nextKey = 1;

  SearchEngine eng() => engine ?? (throw const CacheSearchException('internal', 'The search core is not open'));

  Object? handle(String op, Map<String, dynamic> a) {
    Object? result;
    switch (op) {
      case 'open':
        native = factory();
        engine = SearchEngine.open(native!, sourcesFrom(a['sources'] as List), extra: (a['extra'] as Map?)?.cast<String, dynamic>());
      case 'version':
        result = eng().version();
      case 'mapSearch':
        result = eng().mapSearchRaw((a['request'] as Map).cast<String, dynamic>());
      case 'mapRoute':
        result = eng().mapRouteRaw((a['request'] as Map).cast<String, dynamic>());
      case 'mapProgress':
        result = eng().mapProgressRaw((a['request'] as Map).cast<String, dynamic>());
      case 'placesRefresh':
        result = eng().placesRefresh(packs: (a['packs'] as List?)?.cast<String>());
      case 'savedPlaces':
        result = [
          for (final p in eng().savedPlaces()) {'key': p.key, 'name': p.name, 'lat': p.lat, 'lon': p.lon, 'label': p.label},
        ];
      case 'savePlace':
        final p = eng().savePlace((a['place'] as Map).cast<String, dynamic>());
        result = {'key': p.key, 'name': p.name, 'lat': p.lat, 'lon': p.lon, 'label': p.label};
      case 'deleteSavedPlace':
        eng().deleteSavedPlace(a['key'] as String);
      case 'setSources':
        eng().setSources(sourcesFrom(a['sources'] as List), extra: (a['extra'] as Map?)?.cast<String, dynamic>());
      case 'openTimings':
        result = eng().openTimings();
      case 'rejected':
        result = [for (final r in eng().rejectedSnapshots()) r.toJson()];
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
              'keyword_source': s.keywordSource,
              'embedding_model': s.embeddingModel,
              'whole_library_only': s.wholeLibraryOnly,
              'source_id': s.sourceId,
              'index': s.index?.toJson(),
              'captionsindex': s.captionsIndex?.toJson(),
              'epubindex': s.epubIndex?.toJson(),
              'pdfindex': s.pdfIndex?.toJson(),
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
              : QueryVector((a['queryVector'] as Map)['model'] as String, [for (final x in (a['queryVector'] as Map)['vector'] as List) (x as num).toDouble()]),
        );
        // One serialisation for both directions (SearchHit.toJson and fromJson), so no field of a hit is lost on the way.
        result = r.toJson();
      case 'read':
        result = eng().read(a['address'] as String, maxChars: a['maxChars'] as int).toJson();
      case 'zimGet':
        final z = eng().zimGet(a['address'] as String);
        result = [z.bytes, z.mime];
      case 'zimMainPage':
        result = eng().zimMainPage(a['zimId'] as String);
      case 'zimIllustration':
        result = eng().zimIllustration(a['zimId'] as String);
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
          'ids': [for (final i in f.ids) i.toJson()],
        };
      case 'convIds':
        result = [for (final i in convs[a['conv']]!.ids()) i.toJson()];
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
          'ids': [for (final i in o.ids) i.toJson()],
        };
      case 'setLocation':
        eng().setLocation((a['lat'] as num).toDouble(), (a['lon'] as num).toDouble(), accuracyM: (a['accuracy'] as num).toDouble(), fixedAt: a['fixedAt'] as String);
      case 'clearLocation':
        eng().clearLocation();
      case 'setWeb':
        eng().setWeb(provider: a['provider'] as String?, key: a['key'] as String?, online: a['online'] as bool);
      case 'toolSchemas':
        result = eng().toolSchemas();
      case 'actSetDefinitions':
        result = eng().actSetDefinitions([for (final d in a['defs'] as List) (d as Map).cast<String, dynamic>()]);
      case 'actSetModulesOff':
        eng().actSetModulesOff((a['modules'] as List).cast<String>());
      case 'actResolve':
        result = eng().actResolve(a['action'] as String, (a['fields'] as Map).cast<String, dynamic>());
      case 'convActFinish':
        result = eng().actFinish(convs[a['conv']]!, a['run_id'] as String, (a['reply'] as Map).cast<String, dynamic>());
      case 'convActOutcome':
        result = eng().actOutcome(convs[a['conv']]!, (a['outcome'] as Map).cast<String, dynamic>());
      case 'notebook':
        result = eng().notebook(a['op'] as String, (a['args'] as Map).cast<String, dynamic>());
      case 'hasPdfIndex':
        result = eng().hasPdfIndex;
      case 'zimPdfs':
        result = eng().zimPdfs(a['zimId'] as String);
      case 'pdfIndex':
        result = eng().pdfIndex(a['op'] as String, session: (a['session'] as int?) ?? 0, args: (a['args'] as Map?)?.cast<String, dynamic>());
      case 'hasCaptionsSearch':
        result = eng().hasCaptionsSearch;
      case 'captionsSearch':
        result = eng().captionsSearch((a['request'] as Map).cast<String, dynamic>());
      case 'shelves':
        // handle-less: works before the core is opened
        result = SearchEngine.shelvesCall(native ?? (native = factory()), a['op'] as String, (a['args'] as Map).cast<String, dynamic>());
      case 'userLayers':
        result = eng().userLayers(a['call'] as String, a['arg'] as String?);
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
      case 'liveFetchStart':
        // null: this core has no cs_live_fetch_start (the caller uses liveFetch)
        final j = eng().liveFetchJob((a['request'] as Map).cast<String, dynamic>());
        if (j != null) {
          final key = nextKey++;
          jobs[key] = j;
          result = key;
        }
      case 'liveGet':
        result = eng().liveGet((a['request'] as Map).cast<String, dynamic>());
      case 'liveSetFetchPolicy':
        eng().liveSetFetchPolicy((a['policy'] as Map?)?.cast<String, dynamic>());
      case 'liveSetKey':
        eng().liveSetKey(a['source'] as String, a['key'] as String?);
      case 'livePreview':
        result = eng().livePreview((a['request'] as Map).cast<String, dynamic>());
      case 'layers':
        result = eng().layers(a['op'] as String, a['arg'] as String?);
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
          if (p.detail != null) 'detail': p.detail,
          if (p.phase != null) 'phase': p.phase,
          if (p.result != null) 'result': p.result,
          if (p.paused != null) 'paused': p.paused,
          if (p.effective != null) 'effective': p.effective,
        };
      case 'jobCancel':
        jobs[a['job']]!.cancel();
      case 'jobSet':
        result = jobs[a['job']]!.set((a['pace'] as Map).cast<String, Object?>());
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
        throw CacheSearchException('internal', 'Unknown call $op');
    }
    return result;
  }
}
