import 'package:cache_search/cache_search.dart' show SearchCore;

/// The Bookshelves log's core calls as the Library uses them (cs_shelves_detect, cs_shelves_append, cs_shelves_resolve,
/// cs_shelves_import; cache_search.h; the format is server/builder/LIBRARY-LOG.md). Every rule (same-book detection, which events
/// count, the call numbers, the import) is the core's: the app only passes folders and events and reads the view.
abstract class ShelvesCalls {
  /// `{"copy": facts, "against": [facts]}` to the matches, `[{"with","how","score"}]`.
  Future<List<Map<String, dynamic>>> detect(Map<String, dynamic> args);

  /// `{"dir","dev","events":[...]}` to `{"written","last_at"}`.
  Future<Map<String, dynamic>> append(Map<String, dynamic> args);

  /// `{"dir","libraries":[{"library_id","dir","packs_dir"?}]}` to the view, format 1.
  Future<Map<String, dynamic>> resolve(Map<String, dynamic> args);

  /// `{"dir","dev","libraries":[...]}` to `{"events","files":[...]}`.
  Future<Map<String, dynamic>> import(Map<String, dynamic> args);
}

/// The calls through the app's search core (its worker isolate, so they never block the UI). Null from [core]: the core did
/// not open, and the calls fail with a [StateError].
class CoreShelvesCalls implements ShelvesCalls {
  CoreShelvesCalls(this.core);

  final Future<SearchCore?> Function() core;

  Future<SearchCore> _c() async => await core() ?? (throw StateError('the search core is not open'));

  @override
  Future<List<Map<String, dynamic>>> detect(Map<String, dynamic> args) async => (await _c()).shelvesDetect(args);

  @override
  Future<Map<String, dynamic>> append(Map<String, dynamic> args) async => (await _c()).shelvesAppend(args);

  @override
  Future<Map<String, dynamic>> resolve(Map<String, dynamic> args) async => (await _c()).shelvesResolve(args);

  @override
  Future<Map<String, dynamic>> import(Map<String, dynamic> args) async => (await _c()).shelvesImport(args);
}
