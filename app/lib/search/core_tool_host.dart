import 'package:cache_search/cache_search.dart';

import '../chat/system_prompt.dart';
import '../chat/tool.dart';

/// The search core's tools for one chat: the schemas of every installed tool (cs_tool_schemas) and one call
/// through the core's dispatch (cs_tool). The chat's conversation is made when first needed and freed with the chat.
class CoreToolHost implements ToolHost {
  CoreToolHost({required this.core, required this.newConversation});

  final SearchCore core;
  final Future<CoreConversation> Function() newConversation;
  Future<CoreConversation>? _conv;

  Future<CoreConversation> get _c => _conv ??= newConversation();

  @override
  Future<List<Map<String, dynamic>>> schemas() => core.toolSchemas();

  @override
  Future<HostToolResult> call(String name, Map<String, dynamic> args, DateTime now) async {
    final o = await (await _c).tool(name, args, now: isoWithOffset(now));
    return HostToolResult(
      content: o.content,
      ids: [for (final i in o.ids) NumberedAddress(n: i.n, address: i.address, title: i.title)],
    );
  }

  @override
  Future<void> dispose() async {
    final c = _conv;
    _conv = null;
    if (c != null) await (await c).free();
  }
}
