import 'dart:convert';
import 'dart:typed_data';

import 'package:cache_search/cache_search.dart';

import '../chat/tool.dart';
import 'core_numbering.dart';

/// Saves and restores one conversation's `[n]` numbering, so a conversation reopened after a restart goes
/// on numbering where it stopped. The saved state is an opaque blob the store keeps with the conversation.
abstract class NumberingState {
  /// The state of [numbering] as bytes, or null when this kind of numbering cannot be saved.
  Future<Uint8List?> save(ResultNumbering numbering);

  /// A numbering that continues from [state], or null when the state is not understood.
  Future<ResultNumbering?> restore(Uint8List state);
}

/// The core's export and import: the saved state is the JSON of cs_conversation_export (format 1) and a
/// restored numbering is the conversation made by cs_conversation_import. The core is looked up when needed, so
/// a core that is not open (or has closed) saves nothing and restores nothing.
class CoreNumberingState implements NumberingState {
  CoreNumberingState(this._core);

  final SearchCore? Function() _core;

  @override
  Future<Uint8List?> save(ResultNumbering numbering) async {
    if (numbering is! CoreNumbering) return null;
    return Uint8List.fromList(utf8.encode(await (await numbering.conversation).export()));
  }

  @override
  Future<ResultNumbering?> restore(Uint8List state) async {
    final core = _core();
    if (core == null) return null;
    try {
      return CoreNumbering.of(await core.importConversation(utf8.decode(state)));
    } catch (_) {
      return null; // the core answered NULL: bad_json, or a format it does not know
    }
  }
}
