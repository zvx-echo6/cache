import 'dart:convert';
import 'dart:typed_data';

import '../chat/tool.dart';

/// Saves and restores one conversation's `[n]` numbering, so a conversation reopened after a restart goes
/// on numbering where it stopped. The saved state is an opaque blob the store keeps with the conversation.
///
/// The real implementation maps onto the core's `cs_conversation_export(c) -> json` (the blob is that JSON,
/// format 1) and `cs_conversation_import(json) -> cs_conv*` (NULL plus cs_last_error on failure: bad_json,
/// or unsupported for an unknown format).
abstract class NumberingState {
  /// The state of [numbering] as bytes, or null when this kind of numbering cannot be saved.
  Future<Uint8List?> save(ResultNumbering numbering);

  /// A numbering that continues from [state], or null when the state is not understood.
  Future<ResultNumbering?> restore(Uint8List state);
}

// ---------------------------------------------------------------------------------------------------
// STAND-IN. To bind the core's calls, swap exactly this:
//   1. add `CoreNumberingState implements NumberingState`: save() = cs_conversation_export of the
//      conversation behind [numbering] (utf8 bytes of the JSON); restore() = cs_conversation_import(json),
//      wrapped like CoreNumbering (null on a failed import);
//   2. in main.dart pass `numberingState: CoreNumberingState(...)` to ChatController instead of the
//      default StandInNumberingState;
//   3. delete everything below this block (StandInNumberingState, StandInNumbering) and the stand-in test.
// The stand-in writes the same JSON as the core's format 1 ({"format":1,"next_n":N,"ids":[{n,address,title}]},
// without web_hits) and numbers a restored conversation in Dart with the rules of the core's cs_format.
// ---------------------------------------------------------------------------------------------------

/// Stand-in for the core's export and import (see the marked block above).
class StandInNumberingState implements NumberingState {
  const StandInNumberingState();

  @override
  Future<Uint8List?> save(ResultNumbering numbering) async {
    final ids = [...await numbering.ids()]..sort((a, b) => a.n.compareTo(b.n));
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'format': 1,
      'next_n': ids.isEmpty ? 1 : ids.last.n + 1,
      'ids': [for (final i in ids) {'n': i.n, 'address': i.address, 'title': i.title}],
    })));
  }

  @override
  Future<ResultNumbering?> restore(Uint8List state) async {
    try {
      final j = jsonDecode(utf8.decode(state)) as Map<String, dynamic>;
      if (j['format'] != 1) return null;
      final ids = [...(j['ids'] as List).cast<Map<String, dynamic>>()]..sort((a, b) => (a['n'] as int).compareTo(b['n'] as int));
      return StandInNumbering([for (final e in ids) (address: e['address'] as String, title: (e['title'] ?? '') as String)]);
    } catch (_) {
      return null;
    }
  }
}

/// Numbers results like the core's cs_format: the first time an address is seen it gets the next number
/// and keeps it; a repeated address in one call appears once; the tool message is one line per result.
class StandInNumbering implements ResultNumbering {
  StandInNumbering(List<({String address, String title})> entries) {
    for (final e in entries) {
      _byAddress[e.address] = _entries.length;
      _entries.add(e);
    }
  }

  final List<({String address, String title})> _entries = [];
  final Map<String, int> _byAddress = {};

  String _oneLine(String s) => s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

  @override
  Future<String> format(List<SourceResult> results) async {
    if (results.isEmpty) return 'No results found.';
    final seen = <int>{};
    final lines = <String>[];
    for (final r in results) {
      final idx = _byAddress.putIfAbsent(r.address, () {
        _entries.add((address: r.address, title: r.title));
        return _entries.length - 1;
      });
      if (!seen.add(idx)) continue;
      final title = _oneLine(r.title), snippet = _oneLine(r.snippet);
      lines.add(snippet.isEmpty ? '[${idx + 1}] $title' : '[${idx + 1}] $title — $snippet');
    }
    return lines.join('\n');
  }

  @override
  Future<List<NumberedAddress>> ids() async => [
        for (var i = 0; i < _entries.length; i++)
          NumberedAddress(n: i + 1, address: _entries[i].address, title: _entries[i].title),
      ];

  @override
  Future<void> dispose() async {}
}
