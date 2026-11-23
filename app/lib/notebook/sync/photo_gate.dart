import '../notebook_model.dart';
import '../notebook_store.dart';
import 'sync_engine_core.dart';

/// The photos notebook sync may send: those an entry that goes out refers to. An entry goes out when its notebook is not
/// switched off ([off]: the folder names the engine is given) and notebook sync writes it for sharing (not a draft; not private
/// unless its notebook is included, [included]). A photo no such entry refers to stays on this device, whichever notebook holds it.
/// The paths are the engine's, inside the share folder (`photos/cache-<id>.jpg`).
///
/// Flutter-free: the phone (share_items.dart) and the Dart helper on a server both give the engine this list.
Future<List<String>> notebookPhotosToSendFrom(NotebookStore notebooks, List<String> off, {required bool Function(String notebookId) included}) async {
  final out = <String>{};
  for (final n in notebooks.notebooks) {
    if (off.contains(NotebookSyncCore.folderNameOf(n))) continue;
    final inc = included(n.id);
    final photoFields = {for (final f in n.def.fields) if (f.type == FieldType.photo && f.fid != null) f.fid!};
    for (final e in await notebooks.entries(n.id)) {
      if (e.draft || (e.private && !inc)) continue;
      for (final p in e.photos) {
        out.add(NotebookSyncCore.photoPath(p.id));
      }
      for (final fid in photoFields) {
        final v = e.values[fid];
        if (v is List) out.addAll([for (final id in v.whereType<String>()) NotebookSyncCore.photoPath(id)]);
      }
    }
  }
  return out.toList()..sort();
}
