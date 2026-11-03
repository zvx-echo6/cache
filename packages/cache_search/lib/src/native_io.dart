// Hand-written dart:ffi binding of the C ABI in native/include/cache_search.h.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_api.dart';

export 'native_api.dart';

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
class FfiCsNative implements CsNative, CsJobNative, CsMapNative, CsLiveNative, CsPlacesNative, CsActNative, CsNotebookNative, CsUserLayersNative, CsPdfNative, CsCaptionsNative {
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
        _videoAuthMethods = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_auth_methods'),
        _videoCaptionsFetch = lib.lookupFunction<_HStrStrC, _HStrStr>('cs_video_captions_fetch'),
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
  final _HStrStr _videoAuthMethods;
  final _HStrStr _videoCaptionsFetch;
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
      'auth_methods' => _take(_videoAuthMethods(_p(handle), req)),
      'captions_fetch' => _take(_videoCaptionsFetch(_p(handle), req)),
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

  late final _HStrStr? _jobSet = _lookupHS('cs_job_set');

  @override
  String? jobSet(int job, String json) => _callHS(_jobSet, job, json);

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

  // ---- the act tool: looked up on first use, because an older core must still load ----

  late final _HStrStr? _actSetDefinitions = _lookupHS('cs_act_set_definitions');
  late final int Function(Pointer<Void>, Pointer<Utf8>)? _actModulesOff = _lookupSetter('cs_act_set_modules_off');
  late final _HStrStrStr? _actResolve = _lookupHSS('cs_act_resolve');
  late final _HStrStrStr? _actFinish = _lookupHSS('cs_act_finish');
  late final _HStrStr? _actOutcome = _lookupHS('cs_act_outcome');

  _HStrStrStr? _lookupHSS(String name) {
    try {
      return _lib.lookupFunction<_HStrStrStrC, _HStrStrStr>(name);
    } on ArgumentError {
      return null;
    }
  }

  @override
  bool get hasAct => _actSetDefinitions != null && _actModulesOff != null && _actResolve != null && _actFinish != null && _actOutcome != null;

  @override
  String? actSetDefinitions(int handle, String defsJson) => _callHS(_actSetDefinitions, handle, defsJson);

  @override
  int actSetModulesOff(int handle, String? modulesJson) => using((a) {
        final f = _actModulesOff;
        if (f == null) return -1;
        return f(_p(handle), modulesJson == null ? nullptr : modulesJson.toNativeUtf8(allocator: a));
      });

  @override
  String? actResolve(int handle, String action, String? fieldsJson) => using((a) {
        final f = _actResolve;
        if (f == null) return null;
        return _take(f(_p(handle), action.toNativeUtf8(allocator: a), fieldsJson == null ? nullptr : fieldsJson.toNativeUtf8(allocator: a)));
      });

  @override
  String? actFinish(int conv, String runId, String replyJson) => using((a) {
        final f = _actFinish;
        if (f == null) return null;
        return _take(f(_p(conv), runId.toNativeUtf8(allocator: a), replyJson.toNativeUtf8(allocator: a)));
      });

  @override
  String? actOutcome(int conv, String outcomeJson) => _callHS(_actOutcome, conv, outcomeJson);

  // ---- the Notebook: looked up on first use, because an older core must still load ----

  late final _HStrStrStr? _notebook = _lookupHSS('cs_notebook');

  @override
  bool get hasNotebook => _notebook != null;

  @override
  String? notebook(int handle, String op, String? argsJson) => using((a) {
        final f = _notebook;
        if (f == null) return null;
        return _take(f(_p(handle), op.toNativeUtf8(allocator: a), argsJson == null ? nullptr : argsJson.toNativeUtf8(allocator: a)));
      });

  // ---- the user's map layers and repeater lists: looked up on first use ----

  late final _HStrStr? _ulImport = _lookupHS('cs_userlayers_import');
  late final _HStr? _ulList = (() {
    try {
      return _lib.lookupFunction<_HStrC, _HStr>('cs_userlayers_list');
    } on ArgumentError {
      return null;
    }
  })();
  late final _HStrStr? _ulGet = _lookupHS('cs_userlayer_get');
  late final _HStrStr? _ulVisible = _lookupHS('cs_userlayer_set_visible');
  late final _HStrStr? _ulDelete = _lookupHS('cs_userlayer_delete');
  late final _HStrStr? _ulExport = _lookupHS('cs_userlayer_export');

  @override
  bool get hasUserLayers => _ulImport != null && _ulList != null && _ulGet != null && _ulVisible != null && _ulDelete != null && _ulExport != null;

  @override
  String? userLayers(int handle, String call, String? arg) {
    if (call == 'list') {
      final f = _ulList;
      return f == null ? null : _take(f(_p(handle)));
    }
    final f = switch (call) {
      'import' => _ulImport,
      'get' => _ulGet,
      'set_visible' => _ulVisible,
      'delete' => _ulDelete,
      'export' => _ulExport,
      _ => null,
    };
    return _callHS(f, handle, arg ?? '');
  }

  // ---- caption search: looked up on first use ----

  late final _HStrStr? _captionsSearch = _lookupHS('cs_captions_search');

  @override
  bool get hasCaptionsSearch => _captionsSearch != null;

  @override
  String? captionsSearch(int handle, String requestJson) => _callHS(_captionsSearch, handle, requestJson);

  // ---- PDF indexes of ZIMs: looked up on first use ----

  late final _HStrStr? _zimPdfs = _lookupHS('cs_zim_pdfs');
  late final Pointer<Utf8> Function(Pointer<Utf8>)? _pdfOpen = _lookupStr1('cs_pdfindex_open');
  late final Pointer<Utf8> Function(Pointer<Utf8>)? _pdfDiscard = _lookupStr1('cs_pdfindex_discard');
  late final Pointer<Utf8> Function(int, Pointer<Utf8>)? _pdfAdd = _lookupSessionStr('cs_pdfindex_add');
  late final Pointer<Utf8> Function(int, Pointer<Utf8>)? _pdfSkip = _lookupSessionStr('cs_pdfindex_skip');
  late final Pointer<Utf8> Function(int)? _pdfClose = _lookupSession('cs_pdfindex_close');
  late final Pointer<Utf8> Function(int, Pointer<Utf8>)? _pdfReuse = _lookupSessionStr('cs_pdfindex_reuse');
  late final Pointer<Utf8> Function(Pointer<Utf8>)? _pdfChunk = _lookupStr1('cs_pdf_chunk');

  Pointer<Utf8> Function(Pointer<Utf8>)? _lookupStr1(String name) {
    try {
      return _lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>(name);
    } on ArgumentError {
      return null;
    }
  }

  Pointer<Utf8> Function(int, Pointer<Utf8>)? _lookupSessionStr(String name) {
    try {
      return _lib.lookupFunction<Pointer<Utf8> Function(Uint64, Pointer<Utf8>), Pointer<Utf8> Function(int, Pointer<Utf8>)>(name);
    } on ArgumentError {
      return null;
    }
  }

  Pointer<Utf8> Function(int)? _lookupSession(String name) {
    try {
      return _lib.lookupFunction<Pointer<Utf8> Function(Uint64), Pointer<Utf8> Function(int)>(name);
    } on ArgumentError {
      return null;
    }
  }

  @override
  bool get hasPdfIndex => _zimPdfs != null && _pdfOpen != null && _pdfAdd != null && _pdfSkip != null && _pdfClose != null && _pdfDiscard != null;

  @override
  String? zimPdfs(int handle, String zimId) => _callHS(_zimPdfs, handle, zimId);

  @override
  String? pdfIndex(String op, {int session = 0, String json = '{}'}) => using((a) {
    final j = json.toNativeUtf8(allocator: a);
    final open = _pdfOpen, discard = _pdfDiscard, add = _pdfAdd, skip = _pdfSkip, close = _pdfClose, reuse = _pdfReuse, chunk = _pdfChunk;
    return switch (op) {
      'reuse' when reuse != null => _take(reuse(session, j)),
      'chunk' when chunk != null => _take(chunk(j)),
      'open' when open != null => _take(open(j)),
      'discard' when discard != null => _take(discard(j)),
      'add' when add != null => _take(add(session, j)),
      'skip' when skip != null => _take(skip(session, j)),
      'close' when close != null => _take(close(session)),
      _ => null,
    };
  });

  // The saved-places calls are bound with the rest of the core's calls above (cs_places_list, cs_place_save, cs_place_delete).
  @override
  bool get hasSavedPlaces => true;
}
