import 'package:cache_search/cache_search.dart';

import '../chat/system_prompt.dart';
import '../chat/tool.dart';
import 'core_numbering.dart';

/// The search core's tools for one chat: the schemas of every installed tool (cs_tool_schemas) and one call
/// through the core's dispatch (cs_tool). It numbers sources in the chat's [CoreNumbering] conversation, which
/// is the one saved and restored with the chat; that numbering is freed by the loop, not here.
class CoreToolHost implements ToolHost {
  CoreToolHost({required this.core, required this.numbering});

  final SearchCore core;
  final CoreNumbering numbering;

  @override
  Future<List<Map<String, dynamic>>> schemas() => core.toolSchemas();

  @override
  Future<HostToolResult> call(String name, Map<String, dynamic> args, DateTime now) async {
    final o = await (await numbering.conversation).tool(name, args, now: isoWithOffset(now));
    return HostToolResult(
      content: o.content,
      ids: [for (final i in o.ids) NumberedAddress(n: i.n, address: i.address, title: i.title)],
    );
  }

  @override
  Future<void> dispose() async {}
}
