import 'core_dispatch.dart';
import 'core_transport.dart';
import 'transport_http.dart';

/// The browser: HTTPS to Cache for Linux. There is no native library here, so [native] is not used.
Future<CoreTransport> openDefaultTransport(CsNativeFactory native) async => HttpTransport();
