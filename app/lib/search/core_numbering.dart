import 'package:cache_search/cache_search.dart';

import '../chat/tool.dart';

/// One chat's numbering in the search core (cs_format, cs_conversation_ids). The conversation is made
/// when it is first needed and freed with the chat.
class CoreNumbering implements ResultNumbering {
  CoreNumbering(this._newConversation);

  final Future<CoreConversation> Function() _newConversation;
  Future<CoreConversation>? _conv;

  Future<CoreConversation> get _c => _conv ??= _newConversation();

  @override
  Future<String> format(List<SourceResult> results) async {
    final f = await (await _c).format([
      for (final r in results) {'address': r.address, 'title': r.title, 'snippet': r.snippet},
    ]);
    return f.toolMessage;
  }

  @override
  Future<List<NumberedAddress>> ids() async => [
        for (final i in await (await _c).ids()) NumberedAddress(n: i.n, address: i.address, title: i.title),
      ];

  @override
  Future<void> dispose() async {
    final c = _conv;
    _conv = null;
    if (c != null) await (await c).free();
  }
}
