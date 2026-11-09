// The app's file seam (see app_fs_base.dart). A class that keeps a file in the app's folders asks for one of these instead of
// building a File from path_provider:
//
//   final fs = createAppFs(supportOverride: settingsDirOverride);   // the override is the tests' folder
//   await fs.mkdir(AppRoot.support, '');
//   final text = await fs.readString(AppRoot.support, 'layout.json');
//
// The dart:io side sits in app_fs_io.dart and the browser side in app_fs_web.dart, chosen by a conditional import (the same
// switch as platform.dart), so a web build never reaches path_provider or File.
import 'dart:io' show Directory;

import 'app_fs_base.dart';
import 'app_fs_io.dart' if (dart.library.js_interop) 'app_fs_web.dart' as impl;

export 'app_fs_base.dart';

/// An [AppFs] for the app's folders. [supportOverride] and [docsOverride] stand in for the support and documents folders (tests);
/// a browser ignores them.
AppFs createAppFs({Directory? supportOverride, Directory? docsOverride}) =>
    impl.createAppFs(supportOverride: supportOverride, docsOverride: docsOverride);

// Where the app's folders are, as paths. These stand in for the direct path_provider calls (a browser has no path_provider). On a phone
// and on desktop each is exactly what path_provider gives (nothing is cached or changed). In a browser the support and files folders
// are the roots on Cache Server (fs.roots), which is what AppFs addresses; a path of the server is not something dart:io's File or
// Directory can open in a browser, so code that goes on to use them there still checks plat.isWeb first.

/// The application support folder (path_provider's getApplicationSupportDirectory). Browser: the server's support root.
Future<String> appSupportPath() => impl.appSupportPath();

/// The plain application documents folder (getApplicationDocumentsDirectory, with no Android external-storage lookup). Browser: the
/// server's docs root.
Future<String> appDocumentsPath() => impl.appDocumentsPath();

/// The folder the app keeps its big files in (models, libraries, ZIMs, videos): the external-storage folder on Android, else the
/// documents folder. The same folder as AppRoot.docs. Browser: the server's docs root.
Future<String> appFilesPath() => impl.appFilesPath();

/// The temporary folder (getTemporaryDirectory). A browser has none (Cache Server has no temp root), so this throws UnsupportedError
/// there; callers check plat.isWeb first.
Future<String> appTempPath() => impl.appTempPath();
