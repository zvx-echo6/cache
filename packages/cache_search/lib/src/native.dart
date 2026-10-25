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

  int jobStart(String kind, String paramsJson);
  String? jobProgress(int job);
  int jobCancel(int job);
  void jobFree(int job);
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
typedef _JobStartC = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _JobStart = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _JobCancelC = Int32 Function(Pointer<Void>);
typedef _JobCancel = int Function(Pointer<Void>);
typedef _FreeStringC = Void Function(Pointer<Utf8>);
typedef _FreeString = void Function(Pointer<Utf8>);
typedef _FreeBytesC = Void Function(Pointer<Uint8>, Int64);
typedef _FreeBytes = void Function(Pointer<Uint8>, int);

/// The real library, loaded with dart:ffi. Every method is a direct call.
class FfiCsNative implements CsNative {
  FfiCsNative(DynamicLibrary lib)
      : _version = lib.lookupFunction<_StrC, _Str>('cs_version'),
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
  int jobStart(String kind, String paramsJson) =>
      using((a) => _jobStart(kind.toNativeUtf8(allocator: a), paramsJson.toNativeUtf8(allocator: a)).address);

  @override
  String? jobProgress(int job) => _take(_jobProgress(_p(job)));

  @override
  int jobCancel(int job) => _jobCancel(_p(job));

  @override
  void jobFree(int job) => _jobFree(_p(job));
}
