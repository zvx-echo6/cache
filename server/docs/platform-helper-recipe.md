# Web-safe platform checks: recipe for the app branches

dart:io's `Platform.isAndroid`, `isIOS` and the rest throw "Unsupported operation: Platform._operatingSystem" in a browser, so the web build (served by Cache Server) crashes at start. The fix is one small helper, `app/lib/platform.dart`, and a mechanical replacement. Phone behaviour is identical: off the web every getter returns what dart:io returns.

Use it as top-level getters through a prefix: `import 'platform.dart' as plat;` then `plat.isAndroid`. Getters: `isWeb`, `isAndroid`, `isIOS`, `isWindows`, `isLinux`, `isMacOS`, `operatingSystem` ('web' in a browser), `hostName` (dart:io's `Platform.localHostname`; in a browser, `Uri.base.host`, the server's own name). New in the helper: `hostName`. Use `plat.hostName` wherever `Platform.localHostname` could run on the web (the device name in main.dart).

## 1. Add the three files to app/lib

`app/lib/platform.dart`

```dart
// Platform checks that are safe on the web. dart:io's Platform.isAndroid, Platform.isIOS and the rest throw "Unsupported operation:
// Platform._operatingSystem" in a browser, so code that may run in the web build asks this file instead:
//
//   import 'platform.dart' as plat;   // the path to lib/platform.dart, relative to the importing file
//   if (plat.isAndroid) { ... }
//
// On the web isWeb is true, the other checks are false and operatingSystem is 'web'. Everywhere else every getter returns exactly
// what dart:io's Platform returns, so phone behaviour is unchanged. The dart:io side sits in platform_io.dart, chosen by a
// conditional import, so a web build never touches dart:io's Platform.
import 'package:flutter/foundation.dart' show kIsWeb;

import 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart' as impl;

bool get isWeb => kIsWeb;
bool get isAndroid => impl.isAndroid;
bool get isIOS => impl.isIOS;
bool get isWindows => impl.isWindows;
bool get isLinux => impl.isLinux;
bool get isMacOS => impl.isMacOS;
String get operatingSystem => impl.operatingSystem;
// The machine's own name (dart:io's Platform.localHostname); in a browser, the host the page was loaded from, i.e. the server.
String get hostName => impl.hostName;
```

`app/lib/platform_io.dart`

```dart
import 'dart:io' as io;

bool get isAndroid => io.Platform.isAndroid;
bool get isIOS => io.Platform.isIOS;
bool get isWindows => io.Platform.isWindows;
bool get isLinux => io.Platform.isLinux;
bool get isMacOS => io.Platform.isMacOS;
String get operatingSystem => io.Platform.operatingSystem;
String get hostName => io.Platform.localHostname;
```

`app/lib/platform_web.dart`

```dart
bool get isAndroid => false;
bool get isIOS => false;
bool get isWindows => false;
bool get isLinux => false;
bool get isMacOS => false;
String get operatingSystem => 'web';
String get hostName => Uri.base.host;
```

## 2. Replace the call sites

Save as `replace_platform.dart` anywhere (outside the repo), run from the repo root with `dart path/to/replace_platform.dart`. It rewrites the seven getters in `app/lib`, adds the relative import, and removes a `dart:io` import only where the analyzer then reports it unused. Running it twice changes nothing. It keeps each file's line endings.

```dart
// Run from the repo root:  dart replace_platform.dart
// Rewrites Platform.isAndroid/isIOS/isWindows/isLinux/isMacOS/operatingSystem in app/lib to plat.<name> (lib/platform.dart),
// adds the import, then removes a dart:io import only if the analyzer says it is now unused. Safe to run twice.
import 'dart:io';

final getters = RegExp(r'(?<![\w.])Platform\.(isAndroid|isIOS|isWindows|isLinux|isMacOS|operatingSystem)\b');

void main() {
  final lib = Directory('app/lib');
  var sites = 0, files = 0;
  for (final f in lib.listSync(recursive: true).whereType<File>()) {
    final path = f.path.replaceAll('\\', '/');
    if (!path.endsWith('.dart') || RegExp(r'/platform(_io|_web)?\.dart$').hasMatch(path)) continue;
    var text = f.readAsStringSync();
    final n = getters.allMatches(text).length;
    if (n == 0) continue;
    final nl = text.contains('\r\n') ? '\r\n' : '\n';
    text = text.replaceAllMapped(getters, (m) => 'plat.${m[1]}');
    if (!text.contains(RegExp(r"import '[^']*platform\.dart' as plat;"))) {
      final depth = path.substring('app/lib/'.length).split('/').length - 1;
      final imp = "import '${'../' * depth}platform.dart' as plat;";
      // after the last import directive (an import may span lines, so find its closing ';')
      final last = RegExp(r"^import [^;]*;", multiLine: true).allMatches(text).last;
      text = text.replaceRange(last.end, last.end, '$nl$imp');
    }
    f.writeAsStringSync(text);
    sites += n;
    files++;
  }
  print('replaced $sites call sites in $files files');
  // Drop dart:io imports the analyzer now reports as unused.
  final r = Process.runSync('dart', ['analyze', '--format=machine', 'app/lib'], runInShell: true);
  final unused = <String, Set<int>>{};
  for (final line in '${r.stdout}\n${r.stderr}'.split(RegExp(r'\r?\n'))) {
    final p = line.split('|');
    if (p.length > 7 && p[2] == 'UNUSED_IMPORT' && p[7].contains('dart:io')) {
      unused.putIfAbsent(p[3].replaceAll(RegExp(r'\\+'), '/'), () => {}).add(int.parse(p[4]));
    }
  }
  unused.forEach((path, lines) {
    final f = File(path);
    final src = f.readAsLinesSync();
    final nl = f.readAsStringSync().contains('\r\n') ? '\r\n' : '\n';
    final keep = [for (var i = 0; i < src.length; i++) if (!lines.contains(i + 1)) src[i]];
    f.writeAsStringSync(keep.join(nl) + nl);
    print('removed unused dart:io import: $path');
  });
}
```

## 3. Verify

```
cd app && flutter analyze && flutter test
git grep -nE "Platform\.(isAndroid|isIOS|isWindows|isLinux|isMacOS|isFuchsia|operatingSystem)" -- app/lib ":!app/lib/platform_io.dart"
```

The grep must print nothing. Other dart:io uses (`Platform.pathSeparator`, `Platform.localHostname`, ...) are not touched: check each for a web code path, since they can throw in a browser too (`git grep -n "Platform\." -- app/lib`).

## Not changed here

- `packages/*/lib` native-only files (`cache_llama_bindings.dart`, `native_io.dart`, `regions_core_io.dart`, `sync_core_io.dart`) use `Platform.isX` behind `dart:ffi` / `dart.library.io` conditional imports; the web build never loads them.
- Model-visible text (prompts, tool text, `chat/tool_loop.dart`) has no platform check and is not touched.
