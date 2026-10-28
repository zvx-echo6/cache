import 'dart:convert';

import 'package:cache_search/cache_search.dart';

import '../chat/system_prompt.dart';
import '../chat/navigation_action.dart';
import '../chat/tool.dart';
import 'core_numbering.dart';

/// The search core's tools for one chat: the schemas of every installed tool (cs_tool_schemas) and one call
/// through the core's dispatch (cs_tool). It numbers sources in the chat's [CoreNumbering] conversation, which
/// is the one saved and restored with the chat; that numbering is freed by the loop, not here.
class CoreToolHost implements ToolHost {
  CoreToolHost({required this.core, required this.numbering, this.lookupRoute});

  final SearchCore core;
  final CoreNumbering numbering;
  final Future<MapRoute> Function(String routeId)? lookupRoute;

  /// The successful structured tool result is authoritative even when numbering
  /// reuses an existing n and returns no new ids. Never inspect model prose.
  static Future<List<NavigationAction>> actionsFor(String name, String content, List<NumberedAddress> ids,
      Future<MapRoute> Function(String) lookup) async {
    if (name != 'navigate') return const [];
    String routeId;
    try {
      final result = jsonDecode(content);
      if (result is! Map || result['ok'] != true || result['route_id'] is! String) return const [];
      routeId = result['route_id'] as String;
      if (routeId.isEmpty) return const [];
    } catch (_) {
      return const [];
    }
    final address = 'nav:$routeId';
    final navIds = ids.where((id) => id.address.startsWith('nav:'));
    if (navIds.isNotEmpty && !navIds.any((id) => id.address == address)) return const [];
    MapRoute? route;
    try {
      route = await lookup(routeId);
    } catch (_) {
      // Native eviction or an older core must not break the answer.
    }
    return [NavigationAction(address: address, route: route)];
  }

  @override
  Future<List<Map<String, dynamic>>> schemas() => core.toolSchemas();

  @override
  Future<HostToolResult> call(String name, Map<String, dynamic> args, DateTime now) async {
    final o = await (await numbering.conversation).tool(name, args, now: isoWithOffset(now));
    final ids = [for (final i in o.ids) NumberedAddress(n: i.n, address: i.address, title: i.title)];
    return HostToolResult(
      content: o.content,
      ids: ids,
      navigationActions: await actionsFor(name, o.content, ids, lookupRoute ?? core.mapRouteById),
    );
  }

  @override
  Future<void> dispose() async {}
}
