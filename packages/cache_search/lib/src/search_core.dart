import 'dart:typed_data';

import 'core_dispatch.dart';
import 'core_transport.dart';
import 'errors.dart';
import 'map_models.dart';
import 'models.dart';
import 'native.dart';
import 'transport_select.dart';

export 'core_dispatch.dart' show CsNativeFactory;

CsNative _openNative() => FfiCsNative.open();

/// What one browser tab sends with each tool request (convTool, convActFinish): [location] is `{lat, lon, accuracyM, fixedAt}` or null
/// (no position), [web] is `{provider, reference, online}` or null (web search off). Never a key.
typedef RequestContext = ({Map<String, dynamic>? location, Map<String, dynamic>? web});

/// The search core for the UI. Every call goes through a [CoreTransport] to the core's [CoreDispatcher]: on the phone a
/// long-lived background isolate that owns the handle, in the browser HTTPS to Cache Server's helper.
class SearchCore {
  SearchCore._(this._transport);

  /// Starts the transport and opens the core with [sources]. Throws a [CacheSearchException] if the native
  /// library is missing on this platform or cs_open fails. [extra] holds the other sections of the cs_open config
  /// (user, live, places, routing, ...), see cache_search.h.
  static Future<SearchCore> open(List<SourceConfig> sources, {Map<String, dynamic>? extra, CsNativeFactory native = _openNative, CoreTransport? transport}) async {
    final core = SearchCore._(transport ?? await openDefaultTransport(native));
    try {
      await core._call('open', {'sources': jsonSources(sources), 'extra': extra});
    } catch (_) {
      await core.close();
      rethrow;
    }
    return core;
  }

  final CoreTransport _transport;
  bool _closed = false;

  /// The browser build only (Cache Server's one engine is shared by every tab): the values of this tab, added to each tool request
  /// so the helper uses them for that request alone. Null on the phone and the desktop app, which have their own engine; their
  /// requests are unchanged.
  RequestContext Function()? requestContext;

  /// [args] with this tab's `location` and `web` (both, null when none) when [requestContext] is set; an absent field means an old client.
  Map<String, dynamic> _withContext(Map<String, dynamic> args) {
    final c = requestContext?.call();
    if (c == null) return args;
    return {...args, 'location': c.location, 'web': c.web};
  }

  static List<Map<String, dynamic>> jsonSources(List<SourceConfig> s) => [for (final x in s) x.toJson()];

  Future<dynamic> _call(String op, [Map<String, dynamic> args = const {}]) {
    if (_closed) return Future.error(const CacheSearchException('internal', 'The search core is closed'));
    return _transport.call(op, args);
  }

  Future<Map<String, dynamic>> version() async => (await _call('version') as Map).cast<String, dynamic>();

  /// Replaces the source list (a ZIM was added or removed).
  /// Replaces the source list; [extra] are the config fields cs_set_sources takes again each time (`indexes_dir`).
  Future<void> setSources(List<SourceConfig> sources, {Map<String, dynamic>? extra}) =>
      _call('setSources', {'sources': jsonSources(sources), 'extra': extra});

  Future<List<SourceStatus>> status() async => [
        for (final s in await _call('status') as List) SourceStatus.fromJson((s as Map).cast<String, dynamic>()),
      ];

  /// Snapshots the core found unusable and removed on this device ([SearchEngine.rejectedSnapshots]).
  /// The lines the core wrote about how long its last open took, for the app's log (empty from an older core).
  Future<List<String>> openTimings() async => [for (final t in await _call('openTimings') as List) t as String];

  Future<List<RejectedSnapshot>> rejectedSnapshots() async => [
        for (final r in await _call('rejected') as List) RejectedSnapshot.fromJson((r as Map).cast<String, dynamic>()),
      ];

  Future<SearchResponse> search(String query, {int k = 5, int offset = 0, List<String>? sources, QueryVector? queryVector, Duration? meaningLimit}) async =>
      SearchResponse.fromJson(((await _call('search', {
        'query': query,
        'k': k,
        'offset': offset,
        'sources': sources,
        'queryVector': queryVector?.toJson(),
        'meaningMs': ?meaningLimit?.inMilliseconds,
      })) as Map)
          .cast<String, dynamic>());

  Future<ReadResult> read(String address, {int maxChars = 6000}) async =>
      ReadResult.fromJson(((await _call('read', {'address': address, 'maxChars': maxChars})) as Map).cast<String, dynamic>());

  Future<LibraryDocument> readDocument(String address, {int maxChars = 200000}) async =>
      LibraryDocument.fromJson(((await _call('readDocument', {'address': address, 'maxChars': maxChars})) as Map).cast<String, dynamic>());

  Future<ZimBytes> zimGet(String address) async {
    final r = await _call('zimGet', {'address': address}) as List;
    return ZimBytes(r[0] as Uint8List, r[1] as String);
  }

  /// Cache Server only (the phone's core does not have this call): what the server's own index jobs are doing, by source path:
  /// `fraction` (0..1, or null while the total is not known) for a source being indexed, `error` for one whose index failed.
  Future<Map<String, ({double? fraction, String? error})>> indexState() async => {
        for (final e in ((await _call('index.state')) as Map).entries)
          e.key as String: (
            fraction: ((e.value as Map)['fraction'] as num?)?.toDouble(),
            error: (e.value as Map)['error'] as String?,
          ),
      };

  /// Cache Server only: all of `index.state` for the Library's index line: the per-source jobs as [indexState] has them (without the
  /// extra keys), the queue the server adds (`_queue`: items in run order, with done and total; null from a server that has none)
  /// and why the host holds the work (`hold`: "heat" or "memory"; null for none).
  Future<({Map<String, ({double? fraction, String? error})> jobs, Map<String, dynamic>? queue, String? hold})> indexStateAll() async {
    final r = (await _call('index.state')) as Map;
    final q = r['_queue'];
    final h = r['hold'];
    return (
      jobs: {
        for (final e in r.entries)
          if (e.key != '_queue' && e.key != 'hold')
            e.key as String: (
              fraction: ((e.value as Map)['fraction'] as num?)?.toDouble(),
              error: (e.value as Map)['error'] as String?,
            ),
      },
      queue: q is Map ? q.cast<String, dynamic>() : null,
      hold: h is Map ? h['hold'] as String? : null,
    );
  }

  /// Cache Server only: tries the work [key] again after it was skipped as stuck (the queue sheet's Retry).
  Future<void> indexRetry(String key) async {
    await _call('index.retry', {'key': key});
  }

  /// Cache Server only: the Catalog's Pause and Resume for the server's index work. `paused` true pauses, false resumes, null only
  /// reads. `busy` is whether there is index work (running, waiting, or held by the pause).
  Future<({bool paused, bool busy})> indexPause([bool? paused]) async {
    final r = (await _call('index.pause', {'paused': ?paused})) as Map;
    return (paused: r['paused'] == true, busy: r['busy'] == true);
  }

  Future<String> zimMainPage(String zimId) async => (await _call('zimMainPage', {'zimId': zimId})) as String;

  /// The ZIM's own icon (PNG bytes), or null when it has none.
  Future<Uint8List?> zimIllustration(String zimId) async => (await _call('zimIllustration', {'zimId': zimId})) as Uint8List?;

  Future<List<Suggestion>> suggest(String prefix, {int k = 10, List<String>? sources}) async => [
        for (final s in await _call('suggest', {'prefix': prefix, 'k': k, 'sources': sources}) as List)
          Suggestion.fromJson((s as Map).cast<String, dynamic>()),
      ];

  // ---- the map (cs_map_*) and saved places ----

  /// The map's search box. [query] is a place name, a category, coordinates in any format, or a meaning; [near] is the
  /// map centre or the GPS fix (distances and ranking are from it). [meaning] false skips the vector step (fast, for
  /// results as you type); [queryVector] is the query as the app's embedder made it.
  Future<MapSearchResponse> mapSearch(String query, {GeoPoint? near, int limit = 10, bool meaning = true, MapQueryVector? queryVector}) async =>
      MapSearchResponse.fromJson(((await _call('mapSearch', {
        'request': {
          'query': query,
          if (near != null) 'near': near.toJson(),
          'limit': limit,
          'meaning': meaning,
          'query_vector': ?queryVector?.toJson(),
        },
      })) as Map)
          .cast<String, dynamic>());

  /// The place the places build linked a base-map chip to (`poi_links`), by the chip's tile [kind] ("attraction"), [name] and point.
  /// Null when the build has no link for it. Nothing is searched or guessed.
  Future<MapPlace?> mapPoiLink({required String kind, required String name, required double lat, required double lon}) async {
    final r = MapSearchResponse.fromJson(((await _call('mapSearch', {
      'request': {
        'query': name,
        'near': {'lat': lat, 'lon': lon},
        'limit': 1,
        'meaning': false,
        'poi': {'kind': kind, 'name': name, 'lat': lat, 'lon': lon},
      },
    })) as Map)
        .cast<String, dynamic>());
    return r.results.isEmpty ? null : r.results.first;
  }

  /// The complete route. [to] and [from] are ends (`{"id"?, "lat", "lon", "name"?}`, from a [MapPlace.toEnd]); no [from]
  /// is the core's last GPS fix. A route that cannot be made is a [MapRoute] with `ok` false and its errors.
  Future<MapRoute> mapRoute({Map<String, dynamic>? from, required Map<String, dynamic> to, List<Map<String, dynamic>> via = const [], String mode = 'drive', String? landAccess, int alternatives = 2}) async =>
      MapRoute.fromJson(((await _call('mapRoute', {
        'request': {
          'from': ?from,
          'to': to,
          if (via.isNotEmpty) 'via': via,
          'mode': mode,
          'land_access': ?landAccess,
          'alternatives': alternatives,
        },
      })) as Map)
          .cast<String, dynamic>());

  /// Retrieves a retained exact route; never computes a replacement route.
  Future<MapRoute> mapRouteById(String routeId) async => MapRoute.fromJson(
      ((await _call('mapRoute', {'request': {'route_id': routeId}})) as Map).cast<String, dynamic>());

  /// Where a fix is on a route. Sends [route] too, so the core finds the route again after a restart.
  Future<MapProgress> mapProgress(MapRoute route, {required double lat, required double lon, double? accuracyM, DateTime? now, bool reset = false, double? offRouteM, int? offRouteFixes, bool sendRoute = false}) async =>
      MapProgress.fromJson(((await _call('mapProgress', {
        'request': {
          'route_id': route.routeId,
          if (sendRoute) 'route': route.raw,
          'lat': lat,
          'lon': lon,
          'accuracy_m': ?accuracyM,
          if (now != null) 'now': rfc3339(now),
          if (reset) 'reset': true,
          'off_route_m': ?offRouteM,
          'off_route_fixes': ?offRouteFixes,
        },
      })) as Map)
          .cast<String, dynamic>());

  /// Makes the next search read the places again (cs_places_refresh): after a region's places were merged or removed, and
  /// when the sources are refreshed. [packs], when given, replaces the single-region packs. `{"ok", "packs", "merged"}`.
  Future<Map<String, dynamic>> refreshPlaces({List<String>? packs}) => _map('placesRefresh', {'packs': packs});

  Future<List<SavedPlaceRecord>> savedPlaces() async => [
        for (final p in await _call('savedPlaces') as List) SavedPlaceRecord.fromJson((p as Map).cast<String, dynamic>()),
      ];

  Future<SavedPlaceRecord> savePlace({String? key, required String name, required double lat, required double lon, String? label}) async =>
      SavedPlaceRecord.fromJson(((await _call('savePlace', {'place': {'key': ?key, 'name': name, 'lat': lat, 'lon': lon, 'label': ?label}})) as Map).cast<String, dynamic>());

  Future<void> deleteSavedPlace(String key) => _call('deleteSavedPlace', {'key': key});

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

  /// Installs the act tool's action definitions (cs_act_set_definitions), replacing the earlier set; the install report.
  Future<Map<String, dynamic>> actSetDefinitions(List<Map<String, dynamic>> definitions) => _map('actSetDefinitions', {'defs': definitions});

  /// The modules switched off (cs_act_set_modules_off).
  Future<void> actSetModulesOff(List<String> modules) => _call('actSetModulesOff', {'modules': modules});

  /// The checks and place resolution of an act call, kept with a confirm card (cs_act_resolve).
  Future<Map<String, dynamic>> actResolve(String action, Map<String, dynamic> fields) => _map('actResolve', {'action': action, 'fields': fields});

  /// One op of the Notebook (cs_notebook; cache_search.h lists the ops and their answers).
  Future<Map<String, dynamic>> notebook(String op, [Map<String, dynamic> args = const {}]) => _map('notebook', {'op': op, 'args': args});

  /// True when the core has the PDF index calls (cs_zim_pdfs, cs_pdfindex_*).
  Future<bool> hasPdfIndex() async => (await _call('hasPdfIndex')) as bool;

  /// The ZIM's PDF entries (cs_zim_pdfs).
  Future<Map<String, dynamic>> zimPdfs(String zimId) => _map('zimPdfs', {'zimId': zimId});

  /// One handle-less PDF call: the build session (`open`, `add`, `reuse`, `skip`, `close`, `discard`) or `chunk` (cs_pdf_chunk);
  /// see cache_search.h.
  Future<Map<String, dynamic>> pdfIndex(String op, {int session = 0, Map<String, dynamic>? args}) =>
      _map('pdfIndex', {'op': op, 'session': session, 'args': args});

  /// True when the core has cs_captions_search.
  Future<bool> hasCaptionsSearch() async => (await _call('hasCaptionsSearch')) as bool;

  /// Saved videos and ZIM videos matched by caption text (cs_captions_search): {"videos":[...]}.
  Future<Map<String, dynamic>> captionsSearch(String query, {int? k, String? lang}) =>
      _map('captionsSearch', {'request': {'query': query, 'k': ?k, 'lang': ?lang}});

  // ---- the Bookshelves log (cs_shelves_*; handle-less, run in the worker so they never block the UI) ----

  /// Same-book detection for one copy (cs_shelves_detect): `{"copy": facts, "against": [facts], "tuning"?}` gives the matches,
  /// `[{"with","how","score"}]`.
  Future<List<Map<String, dynamic>>> shelvesDetect(Map<String, dynamic> args) async => [
        for (final m in (await _call('shelves', {'op': 'detect', 'args': args})) as List) (m as Map).cast<String, dynamic>(),
      ];

  /// Appends events to this device's file of the Bookshelves log (cs_shelves_append): `{"dir","dev","events":[...]}` gives
  /// `{"written","last_at"}`.
  Future<Map<String, dynamic>> shelvesAppend(Map<String, dynamic> args) => _map('shelves', {'op': 'append', 'args': args});

  /// The Bookshelves view, format 1 (cs_shelves_resolve): `{"dir","libraries":[{"library_id","dir","packs_dir"?}]}`.
  Future<Map<String, dynamic>> shelvesResolve(Map<String, dynamic> args) => _map('shelves', {'op': 'resolve', 'args': args});

  /// Brings this device's own old per-library log events into the Bookshelves log once (cs_shelves_import):
  /// `{"dir","dev","libraries":[...]}` gives `{"events","files":[...]}`.
  Future<Map<String, dynamic>> shelvesImport(Map<String, dynamic> args) => _map('shelves', {'op': 'import', 'args': args});

  /// One of the user's map layer and repeater list calls (cs_userlayer*; see [SearchEngine.userLayers]).
  Future<Map<String, dynamic>> userLayers(String call, [String? arg]) => _map('userLayers', {'call': call, 'arg': arg});

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
  ///
  /// [liveFetch] runs as a job on a thread of the core's own (cs_live_fetch_start) and is polled, so the download's network wait
  /// never holds the core's one worker: searches, reads and stored weather are answered meanwhile, and several sources download
  /// at once. A core (or Cache Server helper) without the call fetches on the worker as before.
  Future<Map<String, dynamic>> liveFetch(Map<String, dynamic> request) async {
    if (!_noLiveJob) {
      Object? id;
      try {
        id = await _call('liveFetchStart', {'request': request});
      } on CacheSearchException catch (e) {
        if (!(e.code == 'internal' && e.message.startsWith('Unknown call'))) rethrow;
      }
      if (id is int) return _jobResult(id, 'The live fetch');
      _noLiveJob = true;
    }
    return _map('liveFetch', {'request': request});
  }

  bool _noLiveJob = false;

  /// The "result" of a job that runs one of the handle's long calls on a thread of its own; [what] names it in an error.
  Future<Map<String, dynamic>> _jobResult(int id, String what) async {
    final job = CoreJobHandle._(this, id);
    try {
      var wait = const Duration(milliseconds: 40);
      while (true) {
        final p = await job.progress();
        switch (p.state) {
          case JobState.running:
            await Future<void>.delayed(wait);
            if (wait < const Duration(milliseconds: 320)) wait *= 2;
          case JobState.done:
            return p.result ?? (throw CacheSearchException('internal', '$what gave no answer'));
          case JobState.cancelled:
          case JobState.failed:
            throw CacheSearchException(p.errorCode ?? 'internal', p.errorMessage ?? '$what stopped');
        }
      }
    } finally {
      await job.free();
    }
  }
  Future<Map<String, dynamic>> liveGet(Map<String, dynamic> request) => _map('liveGet', {'request': request});

  /// The host's grant for network fetches (cs_live_set_fetch_policy): `{"online","allow_metered","metered","enabled_sources":[ids]}`.
  /// Null clears it, and the core fetches nothing. Push it at start and whenever the connection or the settings change.
  Future<void> liveSetFetchPolicy(Map<String, dynamic>? policy) => _call('liveSetFetchPolicy', {'policy': policy});

  /// A source's key (cs_live_set_key), kept in the core's memory only and never read back; null forgets it.
  Future<void> liveSetKey(String sourceId, String? key) => _call('liveSetKey', {'source': sourceId, 'key': key});

  /// Checks a connector definition without downloading (cs_live_preview with `check_only`): `{"valid":true,"source":{...},
  /// "requests":[...],"warnings":[...]}`, or a [CacheSearchException] whose message names every problem field.
  Future<Map<String, dynamic>> liveCheck(Object definition) => _map('livePreview', {'request': {'definition': definition, 'check_only': true}});

  /// Downloads once with a definition (cs_live_preview): to check a key, and for a connector's author. Nothing is stored.
  Future<Map<String, dynamic>> livePreview(Map<String, dynamic> request) => _map('livePreview', {'request': request});

  /// The map layer engine (cs_layers_*): [op] is list, refresh, save, remove, server, plan, delete or clear_cache; [arg]
  /// is that call's one string (see cache_search.h).
  ///
  /// refresh runs as a job on a thread of the core's own (cs_layers_refresh_start) and is polled: the catalogue's network wait
  /// (retries, long timeouts; once an hour across a suspension) held the core's one worker at every start, and saved places, live
  /// data and searches waited behind it. A core (or Cache Server helper) without the call refreshes on the worker as before.
  Future<Map<String, dynamic>> layers(String op, [String? arg]) async {
    if (op == 'refresh' && !_noLayersJob) {
      Object? id;
      try {
        id = await _call('layersRefreshStart');
      } on CacheSearchException catch (e) {
        if (!(e.code == 'internal' && e.message.startsWith('Unknown call'))) rethrow;
      }
      if (id is int) return _jobResult(id, 'The layer catalogue refresh');
      _noLayersJob = true;
    }
    return _map('layers', {'op': op, 'arg': arg});
  }

  bool _noLayersJob = false;

  /// Starts a long job: kind "index_zim" with {"zim_path","index_dir","heap_mb"} and so on (see cache_search.h).
  Future<CoreJobHandle> startJob(String kind, Map<String, dynamic> params) async =>
      CoreJobHandle._(this, (await _call('jobStart', {'kind': kind, 'params': params})) as int);

  /// A handle on a job that is already running in this core: the job a Cache Server keeps going with no tab open, found again
  /// by the id [CoreJobHandle.id] gave when it started (a page reloaded). Its [CoreJobHandle.progress] throws when the core has no
  /// such job.
  CoreJobHandle attachJob(int id) => CoreJobHandle._(this, id);

  /// Closes the core and ends the worker.
  Future<void> close() async {
    if (_closed) return;
    try {
      await _call('close');
    } catch (_) {}
    _closed = true;
    await _transport.close();
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
  ///
  /// [perRequest] false leaves this tab's location and web setting off the request (a key check that lends the engine a key
  /// for one search with setWeb, which the request's own `web` would override).
  Future<ToolOutput> tool(String name, Map<String, dynamic> args, {required String now, bool perRequest = true}) async {
    final a = {'conv': _id, 'name': name, 'args': args, 'now': now};
    return ToolOutput.fromJson(((await _core._call('convTool', perRequest ? _core._withContext(a) : a)) as Map).cast<String, dynamic>());
  }

  /// The host's reply to an act call's host_run (cs_act_finish): the exact tool message for the model.
  Future<String> actFinish(String runId, Map<String, dynamic> reply) async =>
      (await _core._call('convActFinish', _core._withContext({'conv': _id, 'run_id': runId, 'reply': reply}))) as String;

  /// A confirm card's outcome (cs_act_outcome): the exact content of the system message for the model.
  Future<String> actOutcome(Map<String, dynamic> outcome) async => (await _core._call('convActOutcome', {'conv': _id, 'outcome': outcome})) as String;

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

  /// The core's number for the job (kept by an app that must find it again, see [SearchCore.attachJob]).
  int get id => _id;

  Future<JobProgress> progress() async =>
      JobProgress.fromJson(((await _core._call('jobProgress', {'job': _id})) as Map).cast<String, dynamic>());

  Future<void> cancel() => _core._call('jobCancel', {'job': _id});

  /// Changes the job's pace now (cs_job_set; see [CoreJob.set]); null when the core has no cs_job_set.
  Future<Map<String, dynamic>?> set(Map<String, Object?> pace) async =>
      ((await _core._call('jobSet', {'job': _id, 'pace': pace})) as Map?)?.cast<String, dynamic>();

  /// Frees a job that is done, cancelled or failed.
  Future<void> free() async {
    if (_freed) return;
    _freed = true;
    try {
      await _core._call('jobFree', {'job': _id});
    } catch (_) {}
  }
}
