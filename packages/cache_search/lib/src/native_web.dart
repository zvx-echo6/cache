// Web build: there is no native library in a browser, so the C ABI is not available here. The interfaces are the same ones the phone
// uses; FfiCsNative is a stub whose every member throws. (The web side gets its own transport in a later step.)
import 'native_api.dart';

export 'native_api.dart';

/// The real library does not exist on the web. [open] throws; no member of this class can be reached.
class FfiCsNative implements CsNative, CsJobNative, CsMapNative, CsLiveNative, CsPlacesNative, CsActNative, CsNotebookNative, CsUserLayersNative, CsPdfNative, CsZimIconNative, CsCaptionsNative, CsShelvesNative, CsIngestNative {
  FfiCsNative._();

  /// Opens the native library of the current platform. Throws on the web.
  factory FfiCsNative.open() => throw UnsupportedError('web: FfiCsNative.open');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('web: FfiCsNative');
}
