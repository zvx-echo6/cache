// Platform checks that are safe on the web. dart:io's Platform.isAndroid, Platform.isIOS and the rest throw "Unsupported operation:
// Platform._operatingSystem" in a browser, so code that may run in the web build asks this file instead:
//
//   import 'platform.dart' as plat;   // the path to lib/platform.dart, relative to the importing file
//   if (plat.isAndroid) { ... }
//
// On the web isWeb is true, the other checks are false and operatingSystem is 'web'. Everywhere else every getter returns exactly
// what dart:io's Platform returns, so phone behaviour is unchanged. The dart:io side sits in platform_io.dart, chosen by a
// conditional import, so a web build never touches dart:io's Platform. Nothing here imports Flutter.
import 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart' as impl;

// Flutter's kIsWeb is defined exactly so (foundation/constants.dart); it is spelled out here so this file, and everything that imports
// it (lib/search/core_config.dart, which Cache for Linux's helper reads), needs no Flutter.
const bool _isWeb = bool.fromEnvironment('dart.library.js_util');
bool get isWeb => _isWeb;
bool get isAndroid => impl.isAndroid;
bool get isIOS => impl.isIOS;
bool get isWindows => impl.isWindows;
bool get isLinux => impl.isLinux;
bool get isMacOS => impl.isMacOS;
String get operatingSystem => impl.operatingSystem;
// The machine's own name (dart:io's Platform.localHostname); in a browser, the host the page was loaded from, i.e. the server.
String get hostName => impl.hostName;
