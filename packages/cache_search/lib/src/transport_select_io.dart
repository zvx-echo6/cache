import 'core_dispatch.dart';
import 'core_transport.dart';
import 'transport_isolate.dart';

/// The phone and the desktop app: the worker isolate.
Future<CoreTransport> openDefaultTransport(CsNativeFactory native) => IsolateTransport.spawn(native);
