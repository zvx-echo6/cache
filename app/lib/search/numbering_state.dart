import 'dart:convert';
import 'dart:typed_data';

import '../chat/tool.dart';

/// Saves and restores one conversation's `[n]` numbering, so a conversation reopened after a restart goes
/// on numbering where it stopped. The saved state is an opaque blob the store keeps with the conversation.
abstract class NumberingState {
  /// The state of [numbering] as bytes, or null when this kind of numbering cannot be saved.
  Future<Uint8List?> save(ResultNumbering numbering);

  /// A numbering that continues from [state], or null when the state is not understood.
  Future<ResultNumbering?> restore(Uint8List state);
}

// ---------------------------------------------------------------------------------------------------
// STAND-IN. Remove this part when the search core has cs_conversation_export and cs_conversation_import.
// Until then the state is kept by the app (the numbers, addresses and titles from cs_conversation_ids) and
// a restored conversation is numbered in Dart with the same rules as the core's cs_format (rust
// conv.rs). Binding the real calls means: make a `CoreNumberingState implements NumberingState` that calls
// the two core functions, pass it to ChatController in main.dart, and delete everything below.
// ---------------------------------------------------------------------------------------------------

/// Stand-in for the core's export and import (see the marked block above).
class StandInNumberingState implements NumberingState {
  const StandInNumberingState();

  @override
  Future<Uint8List?> save(ResultNumbering numbering) async {
    final ids = await numbering.ids();
    final entries = [
      for (final i in [...ids]..sort((a, b) => a.n.compareTo(b.n))) [i.address, i.title],
    ];
    return Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'entries': entries})));
  }

  @override
  Future<ResultNumbering?> restore(Uint8List state) async {
    try {
      final j = jsonDecode(utf8.decode(state)) as Map<String, dynamic>;
      if (j['v'] != 1) return null;
      return StandInNumbering([
        for (final e in j['entries'] as List) (address: (e as List)[0] as String, title: e[1] as String),
      ]);
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
