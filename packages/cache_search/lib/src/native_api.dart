// The seam between the search core and the C library: the plain-Dart interfaces (no dart:ffi). The phone's implementation is
// FfiCsNative in native_io.dart; the web build has a stub in native_web.dart.
import 'dart:typed_data';

/// The raw bytes of a ZIM entry with its mime type.
class ZimBytes {
  const ZimBytes(this.bytes, this.mime);

  final Uint8List bytes;
  final String mime;
}

/// The C ABI as plain Dart values: handles are their addresses (0 = NULL), strings are copied out and
/// the native copy is freed here. A null string or a negative number means the call failed; ask
/// [lastError]. This is the seam the unit tests replace with a fake.
abstract class CsNative {
  String? version();

  int open(String configJson);
  int setSources(int handle, String configJson);
  String? status(int handle);

  /// The last error of [handle], or of the calling thread when [handle] is 0.
  String? lastError(int handle);
  void close(int handle);

  String? search(int handle, String query, String optionsJson);
  String? read(int handle, String address, int maxChars);
  ZimBytes? zimGet(int handle, String address);
  String? zimMainPage(int handle, String zimId);
  String? suggest(int handle, String prefix, String optionsJson);

  int conversationNew();
  String? format(int conv, String resultsJson);
  String? conversationIds(int conv);
  void conversationFree(int conv);

  /// The conversation's whole state as JSON (cs_conversation_export), or null on error.
  String? conversationExport(int conv);

  /// A conversation from [json] (cs_conversation_import); 0 on error (ask [lastError] with handle 0).
  int conversationImport(String json);

  /// The phone's GPS fix (cs_set_location). [accuracyM] < 0 means unknown, [fixedAt] is ISO 8601 with an offset.
  /// 0 on success, -1 on error.
  int setLocation(int handle, double lat, double lon, double accuracyM, String fixedAt);

  /// cs_clear_location: the tools answer no_location again.
  int clearLocation(int handle);

  /// cs_set_web: [provider] null turns web search off. 0 on success, -1 on error.
  int setWeb(int handle, String? provider, String? key, bool online);

  /// cs_tool_schemas: a JSON array of the function schemas of the tools available now.
  String? toolSchemas(int handle);

  /// cs_tool: runs one tool call in conversation [conv]. [now] is the local date and time, ISO 8601 with an offset.
  /// Returns {"content","ids"}.
  String? tool(int handle, int conv, String name, String argsJson, String now);

  /// Saved places (cs_places_list, cs_place_save, cs_place_delete).
  String? placesList(int handle);
  String? placeSave(int handle, String placeJson);
  String? placeDelete(int handle, String key);

  /// Live data. [op] is the function's name after `cs_live_`: sources, fetch, get. [requestJson] is ignored for sources.
  String? live(int handle, String op, String requestJson);

  /// The video connector (cs_video_*). [op] is the function's name after `cs_video_`: instances, instance_add,
  /// instance_remove, login, refresh, me, channels, list, search, get, downloads, delete, resolve.
  /// [requestJson] is ignored for instances and downloads.
  String? video(int handle, String op, String requestJson);

  /// The map layer engine (cs_layers_*). [op] is the function's name after `cs_layers_`: list, refresh, save, remove,
  /// server, plan, delete, clear_cache. [arg] is the definition JSON (save), the id (remove), the options (server, may be
  /// null), the request (plan, delete) or the layer (clear_cache, may be null); ignored for list and refresh.
  String? layers(int handle, String op, String? arg);

  int jobStart(String kind, String paramsJson);
  String? jobProgress(int job);
  int jobCancel(int job);
  void jobFree(int job);
}

/// cs_job_set: changes a running job's pace ({"work_ms","idle_ms","threads","paused","auto"}, what is left out stays) and answers
/// {"duty","effective","auto","paused"}; null when the core is older than the call (or on bad input). Kept apart from
/// [CsNative] so its fakes do not change.
abstract class CsJobNative {
  String? jobSet(int job, String json);
}

/// The map calls (cs_map_search, cs_map_route, cs_map_progress) and saved places (cs_place_*). Kept apart from [CsNative] so
/// the fakes of the older seam do not change. [FfiCsNative] implements it; [hasMap] is false when the loaded core is older
/// than the map calls (the symbols are looked up when first used, never at load).
abstract class CsMapNative {
  bool get hasMap;
  String? mapSearch(int handle, String requestJson);
  String? mapRoute(int handle, String requestJson);
  String? mapProgress(int handle, String requestJson);

  bool get hasSavedPlaces;
  String? placesList(int handle);
  String? placeSave(int handle, String placeJson);
  String? placeDelete(int handle, String key);
}

/// The live-fetch policy, the keys and the connector checker (cs_live_set_fetch_policy, cs_live_set_key, cs_live_preview). Kept apart
/// from [CsNative] so the fakes of the older seam do not change. [FfiCsNative] implements it; [hasLivePolicy] is false when the loaded
/// core is older than these calls (the symbols are looked up when first used, never at load).
abstract class CsLiveNative {
  bool get hasLivePolicy;

  /// cs_live_set_fetch_policy: [policyJson] null clears the policy. 0 on success, -1 on error.
  int liveSetFetchPolicy(int handle, String? policyJson);

  /// cs_live_set_key: [key] null clears it. 0 on success, -1 on error. The key is kept in the core's memory only.
  int liveSetKey(int handle, String sourceId, String? key);

  /// cs_live_preview (no handle): checks a connector definition, or downloads once with it. Null on error: [CsNative.lastError] with handle 0.
  String? livePreview(String requestJson);
}

/// cs_live_fetch_start: cs_live_fetch as a job on a thread of the core's own, so the download's network wait never holds the
/// worker. Kept apart from [CsNative] so the fakes do not change.
abstract class CsLiveJobNative {
  /// The job (for [CsNative.jobProgress] and the rest), 0 on error ([CsNative.lastError] with [handle]), -1 when the loaded core
  /// is older than the call.
  int liveFetchStart(int handle, String requestJson);
}

/// cs_places_refresh: the core reads the places again (the merged database of the downloaded regions and the single-region
/// packs). Kept apart from [CsNative] so the fakes of the older seam do not change. [FfiCsNative] implements it;
/// [hasPlacesRefresh] is false when the loaded core is older than the call (the symbol is looked up when first used, never at
/// load).
abstract class CsPlacesNative {
  bool get hasPlacesRefresh;

  /// [argsJson] is `{"packs"?: [...]}`; the answer `{"ok","packs","merged"}`, or null on error.
  String? placesRefresh(int handle, String argsJson);
}

/// The act tool's calls (cs_act_set_definitions, cs_act_set_modules_off, cs_act_resolve, cs_act_finish, cs_act_outcome; docs/ACTIONS.md
/// is the contract). Kept apart from [CsNative] so the fakes of the older seam do not change. [FfiCsNative] implements it; [hasAct] is
/// false when the loaded core is older than these calls (the symbols are looked up when first used, never at load).
abstract class CsActNative {
  bool get hasAct;

  /// Installs the action definitions (a JSON array), replacing the earlier set; the install report, or null on error.
  String? actSetDefinitions(int handle, String defsJson);

  /// The modules switched off (a JSON array of ids; null = none). 0 on success, -1 on error.
  int actSetModulesOff(int handle, String? modulesJson);

  /// The checks and place resolution of an act call, for a confirm card; [fieldsJson] null = {}. Null on error.
  String? actResolve(int handle, String action, String? fieldsJson);

  /// The host's reply to a host_run; the tool result for the model, or null on error (ask [CsNative.lastError] with handle 0).
  String? actFinish(int conv, String runId, String replyJson);

  /// What a tap on a confirm card came to; the system message's content, or null on error (handle 0).
  String? actOutcome(int conv, String outcomeJson);
}

/// The Notebook (cs_notebook; cache_search.h lists its ops). Kept apart from [CsNative] so the fakes of the older seam do not change.
/// [FfiCsNative] implements it; [hasNotebook] is false when the loaded core is older than the call (looked up when first used).
abstract class CsNotebookNative {
  bool get hasNotebook;

  /// One op with its arguments (a JSON object; null = {}); the answer, or null on error (ask [CsNative.lastError]).
  String? notebook(int handle, String op, String? argsJson);
}

/// The user's map layers and repeater lists (cs_userlayers_import, cs_userlayers_list, cs_userlayer_get, cs_userlayer_set_visible,
/// cs_userlayer_delete, cs_userlayer_export; cache_search.h). Kept apart from [CsNative] like the Notebook; [hasUserLayers] is false
/// when the loaded core is older than these calls.
abstract class CsUserLayersNative {
  bool get hasUserLayers;

  /// [call] is one of `import`, `list`, `get`, `set_visible`, `delete`, `export`; [arg] the call's JSON or id (none for `list`).
  /// The answer, or null on error (ask [CsNative.lastError]).
  String? userLayers(int handle, String call, String? arg);
}

/// The PDF indexes of ZIMs (cs_zim_pdfs, cs_pdfindex_open/add/skip/close/discard; cache_search.h). Kept apart from [CsNative]
/// like the Notebook; [hasPdfIndex] is false when the loaded core is older than these calls (looked up when first used).
abstract class CsPdfNative {
  bool get hasPdfIndex;

  /// cs_zim_pdfs: {"zim_uuid","zim_name","pdfs":[{"path","title","size"}]}, or null on error (ask [CsNative.lastError]).
  String? zimPdfs(int handle, String zimId);

  /// The handle-less calls: [op] is `open`, `add`, `reuse`, `skip`, `close`, `discard` (the build session; [session] is open's
  /// session for add, reuse, skip and close) or `chunk` (cs_pdf_chunk, pure); [json] the call's JSON (none for close). The
  /// answer, or null on error or when the core lacks that call (ask [CsNative.lastError] with 0).
  String? pdfIndex(String op, {int session = 0, String json = '{}'});
}

/// The Bookshelves log (cs_shelves_detect, cs_shelves_append, cs_shelves_resolve, cs_shelves_import; cache_search.h). Handle-less: each
/// takes one JSON object naming the folders and answers JSON. Kept apart from [CsNative] like the Notebook; [hasShelves] is false when
/// the loaded core is older than these calls (looked up when first used).
abstract class CsShelvesNative {
  bool get hasShelves;

  /// [op] is the function's name after `cs_shelves_`: `detect`, `append`, `resolve` or `import`; [argsJson] its one argument. The
  /// answer, or null on error or when the core lacks that call (ask [CsNative.lastError] with 0).
  String? shelves(String op, String argsJson);
}

/// Add PDF: the ingest job (cs_ingest_start, cs_ingest_step, cs_ingest_ocr, cs_ingest_cancel, cs_ingest_probe; cache_search.h and
/// packages/cache_ingest/INGEST-API.md). Handle-less like the Bookshelves; [hasIngest] is false when the loaded core is older than
/// these calls (looked up when first used).
abstract class CsIngestNative {
  bool get hasIngest;

  /// [op] is the function's name after `cs_ingest_`: `start`, `step`, `ocr`, `cancel` or `probe`; [argsJson] its one argument.
  /// The answer, or null on error or when the core lacks that call (ask [CsNative.lastError] with 0).
  String? ingest(String op, String argsJson);
}

/// Search saved videos and ZIM videos by caption text (cs_captions_search; cache_search.h). Kept apart from [CsNative] like
/// the PDF indexes; [hasCaptionsSearch] is false when the loaded core is older than the call (looked up when first used).
abstract class CsCaptionsNative {
  bool get hasCaptionsSearch;

  /// cs_captions_search: {"videos":[...]}, or null on error (ask [CsNative.lastError]).
  String? captionsSearch(int handle, String requestJson);
}
