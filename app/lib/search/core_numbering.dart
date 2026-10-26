import 'package:cache_search/cache_search.dart';

import '../chat/tool.dart';

/// One chat's numbering in the search core (cs_format, cs_conversation_ids). The conversation is made
/// when it is first needed and freed with the chat. The core's tools (cs_tool) number in the same conversation.
class CoreNumbering implements ResultNumbering {
  CoreNumbering(Future<CoreConversation> Function() newConversation) : _newConversation = newConversation;

  /// A numbering that continues an existing conversation (one made by cs_conversation_import).
  CoreNumbering.of(CoreConversation conversation)
      : _newConversation = (() async => conversation),
        _conv = Future.value(conversation);

  final Future<CoreConversation> Function() _newConversation;
  Future<CoreConversation>? _conv;

  /// The conversation behind this numbering.
  Future<CoreConversation> get conversation => _conv ??= _newConversation();

  Future<CoreConversation> get _c => conversation;

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
