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
