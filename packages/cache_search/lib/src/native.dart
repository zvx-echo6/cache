// Hand-written dart:ffi binding of the C ABI in native/include/cache_search.h.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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

/// cs_places_refresh: the core reads the places again (the merged database of the downloaded regions and the single-region
/// packs). Kept apart from [CsNative] so the fakes of the older seam do not change. [FfiCsNative] implements it;
/// [hasPlacesRefresh] is false when the loaded core is older than the call (the symbol is looked up when first used, never at
/// load).
abstract class CsPlacesNative {
  bool get hasPlacesRefresh;

  /// [argsJson] is `{"packs"?: [...]}`; the answer `{"ok","packs","merged"}`, or null on error.
  String? placesRefresh(int handle, String argsJson);
}

typedef _StrC = Pointer<Utf8> Function();
typedef _Str = Pointer<Utf8> Function();
typedef _OpenC = Pointer<Void> Function(Pointer<Utf8>);
typedef _Open = Pointer<Void> Function(Pointer<Utf8>);
typedef _HStrC = Pointer<Utf8> Function(Pointer<Void>);
typedef _HStr = Pointer<Utf8> Function(Pointer<Void>);
typedef _HStrStrC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _HStrStr = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _HStrStrStrC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _HStrStrStr = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _HStrIntC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Int32);
typedef _HStrInt = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _SetSourcesC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _SetSources = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _VoidHC = Void Function(Pointer<Void>);
typedef _VoidH = void Function(Pointer<Void>);
typedef _NewC = Pointer<Void> Function();
typedef _New = Pointer<Void> Function();
typedef _ZimGetC = Pointer<Uint8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Int64>);
typedef _ZimGet = Pointer<Uint8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Int64>);
typedef _SetLocC = Int32 Function(Pointer<Void>, Double, Double, Double, Pointer<Utf8>);
typedef _SetLoc = int Function(Pointer<Void>, double, double, double, Pointer<Utf8>);
typedef _IntHC = Int32 Function(Pointer<Void>);
typedef _IntH = int Function(Pointer<Void>);
typedef _SetWebC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetWeb = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _ToolC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Tool = Pointer<Utf8> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _ImportC = Pointer<Void> Function(Pointer<Utf8>);
typedef _Import = Pointer<Void> Function(Pointer<Utf8>);
typedef _JobStartC = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _JobStart = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _JobCancelC = Int32 Function(Pointer<Void>);
typedef _JobCancel = int Function(Pointer<Void>);
typedef _FreeStringC = Void Function(Pointer<Utf8>);
typedef _FreeString = void Function(Pointer<Utf8>);
typedef _FreeBytesC = Void Function(Pointer<Uint8>, Int64);
typedef _FreeBytes = void Function(Pointer<Uint8>, int);

/// The real library, loaded with dart:ffi. Every method is a direct call.
class FfiCsNative implements CsNative, CsMapNative, CsLiveNative, CsPlacesNative {
  FfiCsNative(DynamicLibrary lib)
      : _lib = lib,
        _version = lib.lookupFunction<_StrC, _Str>('cs_version'),
        _open = lib.lookupFunction<_OpenC, _Open>('cs_open'),
        _setSources = lib.lookupFunction<_SetSourcesC, _SetSources>('cs_set_sources'),
        _status = lib.lookupFunction<_HStrC, _HStr>('cs_status'),
        _lastError = lib.lookupFunction<_HStrC, _HStr>('cs_last_error'),
        _close = lib.lookupFunction<_VoidHC, _VoidH>('cs_close'),
        _search = lib.lookupFunction<_HStrStrStrC, _HStrStrStr>('cs_search'),
        _read = lib.lookupFunction<_HStrIntC, _HStrInt>('cs_read'),
        _zimGet = lib.lookupFunction<_ZimGetC, _ZimGet>('cs_zim_get'),
        _zimMainPage = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_zim_main_page'),
        _suggest = lib.lookupFunction<_HStrStrStrC, _HStrStrStr>('cs_suggest'),
        _conversationNew = lib.lookupFunction<_NewC, _New>('cs_conversation_new'),
        _format = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_format'),
        _conversationIds = lib.lookupFunction<_HStrC, _HStr>('cs_conversation_ids'),
        _conversationFree = lib.lookupFunction<_VoidHC, _VoidH>('cs_conversation_free'),
        _conversationExport = lib.lookupFunction<_HStrC, _HStr>('cs_conversation_export'),
        _conversationImport = lib.lookupFunction<_ImportC, _Import>('cs_conversation_import'),
        _setLocation = lib.lookupFunction<_SetLocC, _SetLoc>('cs_set_location'),
        _clearLocation = lib.lookupFunction<_IntHC, _IntH>('cs_clear_location'),
        _setWeb = lib.lookupFunction<_SetWebC, _SetWeb>('cs_set_web'),
        _toolSchemas = lib.lookupFunction<_HStrC, _HStr>('cs_tool_schemas'),
        _tool = lib.lookupFunction<_ToolC, _Tool>('cs_tool'),
        _placesList = lib.lookupFunction<_HStrC, _HStr>('cs_places_list'),
        _placeSave = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_place_save'),
        _placeDelete = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_place_delete'),
        _liveSources = lib.lookupFunction<_HStrC, _HStr>('cs_live_sources'),
        _liveFetch = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_live_fetch'),
        _liveGet = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_live_get'),
        _videoInstances = lib.lookupFunction<_HStrC, _HStr>('cs_video_instances'),
        _videoInstanceAdd = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_instance_add'),
        _videoInstanceRemove = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_instance_remove'),
        _videoLogin = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_login'),
        _videoRefresh = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_refresh'),
        _videoMe = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_me'),
        _videoChannels = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_channels'),
        _videoList = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_list'),
        _videoSearch = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_search'),
        _videoGet = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_get'),
        _videoDownloads = lib.lookupFunction<_HStrC, _HStr>('cs_video_downloads'),
        _videoDelete = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_delete'),
        _videoResolve = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_resolve'),
        _layersList = lib.lookupFunction<_HStrC, _HStr>('cs_layers_list'),
        _layersRefresh = lib.lookupFunction<_HStrC, _HStr>('cs_layers_refresh'),
        _layersSave = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_layers_save'),
        _layersRemove = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_layers_remove'),
        _layersServer = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_layers_server'),
        _layersPlan = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_layers_plan'),
        _layersDelete = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_layers_delete'),
        _layersClearCache = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_layers_clear_cache'),
        _jobStart = lib.lookupFunction<_JobStartC, _JobStart>('cs_job_start'),
        _jobProgress = lib.lookupFunction<_HStrC, _HStr>('cs_job_progress'),
        _jobCancel = lib.lookupFunction<_JobCancelC, _JobCancel>('cs_job_cancel'),
        _jobFree = lib.lookupFunction<_VoidHC, _VoidH>('cs_job_free'),
        _freeString = lib.lookupFunction<_FreeStringC, _FreeString>('cs_free_string'),
        _freeBytes = lib.lookupFunction<_FreeBytesC, _FreeBytes>('cs_free_bytes');

  /// Opens the native library of the current platform. Throws when this platform has no core yet.
  factory FfiCsNative.open() {
    final DynamicLibrary lib;
    if (Platform.isAndroid || Platform.isLinux) {
      lib = DynamicLibrary.open('libcache_search.so');
    } else if (Platform.isWindows) {
      lib = DynamicLibrary.open('cache_search.dll');
    } else if (Platform.isIOS || Platform.isMacOS) {
      lib = DynamicLibrary.process();
    } else {
      throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
    }
    return FfiCsNative(lib);
  }

  final DynamicLibrary _lib;
  final _Str _version;
  final _Open _open;
  final _SetSources _setSources;
  final _HStr _status;
  final _HStr _lastError;
  final _VoidH _close;
  final _HStrStrStr _search;
  final _HStrInt _read;
  final _ZimGet _zimGet;
  final _HStrStr _zimMainPage;
  final _HStrStrStr _suggest;
  final _New _conversationNew;
  final _HStrStr _format;
  final _HStr _conversationIds;
  final _VoidH _conversationFree;
  final _HStr _conversationExport;
  final _Import _conversationImport;
  final _SetLoc _setLocation;
  final _IntH _clearLocation;
  final _SetWeb _setWeb;
  final _HStr _toolSchemas;
  final _Tool _tool;
  final _HStr _placesList;
  final _HStrStr _placeSave;
  final _HStrStr _placeDelete;
  final _HStr _liveSources;
  final _HStrStr _liveFetch;
  final _HStrStr _liveGet;
  final _HStr _videoInstances;
  final _HStrStr _videoInstanceAdd;
  final _HStrStr _videoInstanceRemove;
  final _HStrStr _videoLogin;
  final _HStrStr _videoRefresh;
  final _HStrStr _videoMe;
  final _HStrStr _videoChannels;
  final _HStrStr _videoList;
  final _HStrStr _videoSearch;
  final _HStrStr _videoGet;
  final _HStr _videoDownloads;
  final _HStrStr _videoDelete;
  final _HStrStr _videoResolve;
  final _HStr _layersList;
  final _HStr _layersRefresh;
  final _HStrStr _layersSave;
  final _HStrStr _layersRemove;
  final _HStrStr _layersServer;
  final _HStrStr _layersPlan;
  final _HStrStr _layersDelete;
  final _HStrStr _layersClearCache;
  final _JobStart _jobStart;
  final _HStr _jobProgress;
  final _JobCancel _jobCancel;
  final _VoidH _jobFree;
  final _FreeString _freeString;
  final _FreeBytes _freeBytes;

  static Pointer<Void> _p(int address) => Pointer<Void>.fromAddress(address);

  /// Copies a returned C string into Dart and gives the native copy back (cs_free_string).
  String? _take(Pointer<Utf8> s) {
    if (s == nullptr) return null;
    try {
      return s.toDartString();
    } finally {
      _freeString(s);
    }
  }

  @override
  String? version() => _take(_version());

  @override
  int open(String configJson) => using((a) => _open(configJson.toNativeUtf8(allocator: a)).address);

  @override
  int setSources(int handle, String configJson) =>
      using((a) => _setSources(_p(handle), configJson.toNativeUtf8(allocator: a)));

  @override
  String? status(int handle) => _take(_status(_p(handle)));

  @override
  String? lastError(int handle) => _take(_lastError(_p(handle)));

  @override
  void close(int handle) => _close(_p(handle));

  @override
  String? search(int handle, String query, String optionsJson) => using((a) =>
      _take(_search(_p(handle), query.toNativeUtf8(allocator: a), optionsJson.toNativeUtf8(allocator: a))));

  @override
  String? read(int handle, String address, int maxChars) =>
      using((a) => _take(_read(_p(handle), address.toNativeUtf8(allocator: a), maxChars)));

  @override
  ZimBytes? zimGet(int handle, String address) => using((a) {
        final mimeOut = a<Pointer<Utf8>>();
        final lenOut = a<Int64>();
        mimeOut.value = nullptr;
        final p = _zimGet(_p(handle), address.toNativeUtf8(allocator: a), mimeOut, lenOut);
        if (p == nullptr) {
          _take(mimeOut.value);
          return null;
        }
        final bytes = Uint8List.fromList(p.asTypedList(lenOut.value));
        _freeBytes(p, lenOut.value);
        return ZimBytes(bytes, _take(mimeOut.value) ?? 'application/octet-stream');
      });

  @override
  String? zimMainPage(int handle, String zimId) =>
      using((a) => _take(_zimMainPage(_p(handle), zimId.toNativeUtf8(allocator: a))));

  @override
  String? suggest(int handle, String prefix, String optionsJson) => using((a) =>
      _take(_suggest(_p(handle), prefix.toNativeUtf8(allocator: a), optionsJson.toNativeUtf8(allocator: a))));

  @override
  int conversationNew() => _conversationNew().address;

  @override
  String? format(int conv, String resultsJson) =>
      using((a) => _take(_format(_p(conv), resultsJson.toNativeUtf8(allocator: a))));

  @override
  String? conversationIds(int conv) => _take(_conversationIds(_p(conv)));

  @override
  void conversationFree(int conv) => _conversationFree(_p(conv));

  @override
  String? conversationExport(int conv) => _take(_conversationExport(_p(conv)));

  @override
  int conversationImport(String json) => using((a) => _conversationImport(json.toNativeUtf8(allocator: a)).address);

  @override
  int setLocation(int handle, double lat, double lon, double accuracyM, String fixedAt) =>
      using((a) => _setLocation(_p(handle), lat, lon, accuracyM, fixedAt.toNativeUtf8(allocator: a)));

  @override
  int clearLocation(int handle) => _clearLocation(_p(handle));

  @override
  int setWeb(int handle, String? provider, String? key, bool online) => using((a) => _setWeb(
      _p(handle), provider == null ? nullptr : provider.toNativeUtf8(allocator: a), key == null ? nullptr : key.toNativeUtf8(allocator: a), online ? 1 : 0));

  @override
  String? toolSchemas(int handle) => _take(_toolSchemas(_p(handle)));

  @override
  String? tool(int handle, int conv, String name, String argsJson, String now) => using((a) => _take(_tool(
      _p(handle), _p(conv), name.toNativeUtf8(allocator: a), argsJson.toNativeUtf8(allocator: a), now.toNativeUtf8(allocator: a))));

  @override
  String? placesList(int handle) => _take(_placesList(_p(handle)));

  @override
  String? placeSave(int handle, String placeJson) => using((a) => _take(_placeSave(_p(handle), placeJson.toNativeUtf8(allocator: a))));

  @override
  String? placeDelete(int handle, String key) => using((a) => _take(_placeDelete(_p(handle), key.toNativeUtf8(allocator: a))));

  @override
  String? live(int handle, String op, String requestJson) => using((a) {
        final req = requestJson.toNativeUtf8(allocator: a);
        return switch (op) {
          'sources' => _take(_liveSources(_p(handle))),
          'fetch' => _take(_liveFetch(_p(handle), req)),
          'get' => _take(_liveGet(_p(handle), req)),
          _ => throw ArgumentError('Unknown live call $op'),
        };
      });

  @override
  String? video(int handle, String op, String requestJson) => using((a) {
        final req = requestJson.toNativeUtf8(allocator: a);
        return switch (op) {
      'instances' => _take(_videoInstances(_p(handle))),
      'instance_add' => _take(_videoInstanceAdd(_p(handle), req)),
      'instance_remove' => _take(_videoInstanceRemove(_p(handle), req)),
      'login' => _take(_videoLogin(_p(handle), req)),
      'refresh' => _take(_videoRefresh(_p(handle), req)),
      'me' => _take(_videoMe(_p(handle), req)),
      'channels' => _take(_videoChannels(_p(handle), req)),
      'list' => _take(_videoList(_p(handle), req)),
      'search' => _take(_videoSearch(_p(handle), req)),
      'get' => _take(_videoGet(_p(handle), req)),
      'downloads' => _take(_videoDownloads(_p(handle))),
      'delete' => _take(_videoDelete(_p(handle), req)),
      'resolve' => _take(_videoResolve(_p(handle), req)),
      _ => throw ArgumentError('Unknown video call $op'),
        };
      });

  @override
  String? layers(int handle, String op, String? arg) => using((a) {
        final h = _p(handle);
        final s = arg == null ? nullptr : arg.toNativeUtf8(allocator: a);
        return switch (op) {
          'list' => _take(_layersList(h)),
          'refresh' => _take(_layersRefresh(h)),
          'save' => _take(_layersSave(h, s)),
          'remove' => _take(_layersRemove(h, s)),
          'server' => _take(_layersServer(h, s)),
          'plan' => _take(_layersPlan(h, s)),
          'delete' => _take(_layersDelete(h, s)),
          'clear_cache' => _take(_layersClearCache(h, s)),
          _ => throw ArgumentError('Unknown layers call $op'),
        };
      });

  @override
  int jobStart(String kind, String paramsJson) =>
      using((a) => _jobStart(kind.toNativeUtf8(allocator: a), paramsJson.toNativeUtf8(allocator: a)).address);

  @override
  String? jobProgress(int job) => _take(_jobProgress(_p(job)));

  @override
  int jobCancel(int job) => _jobCancel(_p(job));

  @override
  void jobFree(int job) => _jobFree(_p(job));

  // ---- the map and saved places: looked up on first use, because a core older than these calls must still load ----

  _HStrStr? _lookupHS(String name) {
    try {
      return _lib.lookupFunction<_HStrStrC, _HStrStr>(name);
    } on ArgumentError {
      return null;
    }
  }

  late final _HStrStr? _mapSearch = _lookupHS('cs_map_search');
  late final _HStrStr? _mapRoute = _lookupHS('cs_map_route');
  late final _HStrStr? _mapProgress = _lookupHS('cs_map_progress');

  @override
  bool get hasMap => _mapSearch != null && _mapRoute != null && _mapProgress != null;

  String? _callHS(_HStrStr? f, int handle, String json) {
    if (f == null) return null;
    return using((a) => _take(f(_p(handle), json.toNativeUtf8(allocator: a))));
  }

  @override
  String? mapSearch(int handle, String requestJson) => _callHS(_mapSearch, handle, requestJson);

  @override
  String? mapRoute(int handle, String requestJson) => _callHS(_mapRoute, handle, requestJson);

  @override
  String? mapProgress(int handle, String requestJson) => _callHS(_mapProgress, handle, requestJson);

  late final _HStrStr? _placesRefresh = _lookupHS('cs_places_refresh');

  @override
  bool get hasPlacesRefresh => _placesRefresh != null;

  @override
  String? placesRefresh(int handle, String argsJson) => _callHS(_placesRefresh, handle, argsJson);

  // ---- live fetch policy, keys and the connector checker: looked up on first use, because an older core must still load ----

  late final int Function(Pointer<Void>, Pointer<Utf8>)? _livePolicy = _lookupSetter('cs_live_set_fetch_policy');
  late final Pointer<Utf8> Function(Pointer<Utf8>)? _livePreview = _lookupPreview();

  int Function(Pointer<Void>, Pointer<Utf8>)? _lookupSetter(String name) {
    try {
      return _lib.lookupFunction<_SetSourcesC, _SetSources>(name);
    } on ArgumentError {
      return null;
    }
  }

  Pointer<Utf8> Function(Pointer<Utf8>)? _lookupPreview() {
    try {
      return _lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('cs_live_preview');
    } on ArgumentError {
      return null;
    }
  }

  late final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)? _liveKey = _lookupKey();

  int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)? _lookupKey() {
    try {
      return _lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>), int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)>('cs_live_set_key');
    } on ArgumentError {
      return null;
    }
  }

  @override
  bool get hasLivePolicy => _livePolicy != null && _liveKey != null && _livePreview != null;

  @override
  int liveSetFetchPolicy(int handle, String? policyJson) => using((a) {
        final f = _livePolicy;
        if (f == null) return -1;
        return f(_p(handle), policyJson == null ? nullptr : policyJson.toNativeUtf8(allocator: a));
      });

  @override
  int liveSetKey(int handle, String sourceId, String? key) => using((a) {
        final f = _liveKey;
        if (f == null) return -1;
        return f(_p(handle), sourceId.toNativeUtf8(allocator: a), key == null ? nullptr : key.toNativeUtf8(allocator: a));
      });

  @override
  String? livePreview(String requestJson) => using((a) {
        final f = _livePreview;
        if (f == null) return null;
        return _take(f(requestJson.toNativeUtf8(allocator: a)));
      });

  // The saved-places calls are bound with the rest of the core's calls above (cs_places_list, cs_place_save, cs_place_delete).
  @override
  bool get hasSavedPlaces => true;
}
