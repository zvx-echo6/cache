import 'dart:io';

import '../../platform/app_log.dart';
import '../notebook_model.dart';
import '../templates.dart';
import 'sync_engine_core.dart';

// The engine itself is sync_engine_core.dart, with no Flutter (the Dart helper on a server runs it). This file is the app's side of it:
// the built-in templates from the asset bundle and the errors into the app's log. Everything else is re-exported, so the app and its
// tests keep importing this file.
export 'sync_engine_core.dart';

class NotebookSync extends NotebookSyncCore {
  NotebookSync({
    required super.notebook,
    required super.kind,
    required super.folder,
    required super.stateFile,
    super.includePrivate,
    super.privateBooks,
    super.logseqConfig,
    super.importTag,
    super.clock,
    Future<Templates> Function()? templates,
  }) : super(templates: templates ?? loadTemplates, onError: logError);

  static String folderNameOf(Notebook n) => NotebookSyncCore.folderNameOf(n);
  static String photoPath(String id) => NotebookSyncCore.photoPath(id);
  static Future<({Set<String> imported, Set<String> stopped})> links(File stateFile) => NotebookSyncCore.links(stateFile);
}
