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
  CoreToolHost({required this.core, required this.numbering, this.lookupRoute, this.queryVector, this.runAction});

  final SearchCore core;
  final CoreNumbering numbering;
  final Future<MapRoute> Function(String routeId)? lookupRoute;

  /// The query vector of a `search` call, made with the app's search model (null: the search runs on keywords). It goes
  /// to the core with the call as `query_vector`, which is not one of the arguments the model gives.
  final Future<QueryVector?> Function(String query)? queryVector;

  /// Runs a read or open action the core handed back from an `act` call (host_run) and returns the contract's tool result
  /// (ActionRegistry.run: `{"ok":true,"status":"done",...,"result"}` or `{"ok":false,"status":"failed",...,"error"}`). Null: the
  /// action fails as not installed.
  final Future<Map<String, dynamic>> Function(String action, Map<String, dynamic> fields)? runAction;

  /// The host_run of an act call's [content], or null when the core answered it itself (a confirm card or an error).
  static Map<String, dynamic>? hostRun(String content) {
    try {
      final j = jsonDecode(content);
      if (j is Map && j['ok'] == true && j['status'] == 'host_run' && j['run_id'] is String && j['action'] is String) {
        return j.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  /// The reply cs_act_finish takes, from the action's tool result.
  static Map<String, dynamic> finishReply(Map<String, dynamic> run) => run['ok'] == true
      ? {'ok': true, 'result': run['result'] ?? const <String, dynamic>{}}
      : {'ok': false, 'error': run['error'] ?? const {'type': 'failed'}};

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
    var sent = args;
    final query = args['query'];
    if (name == 'search' && query is String && queryVector != null) {
      final v = await queryVector!(query);
      if (v != null) sent = {...args, 'query_vector': v.toJson()};
    }
    final conv = await numbering.conversation;
    final o = await conv.tool(name, sent, now: isoWithOffset(now));
    var content = o.content;
    var ids = [for (final i in o.ids) NumberedAddress(n: i.n, address: i.address, title: i.title, link: i.link, time: i.time)];
    final run = name == 'act' ? hostRun(content) : null;
    if (run != null) {
      // A read or open action: the app runs it and the core's answer to the reply is what the model sees, numbered in this chat.
      final before = {for (final i in await conv.ids()) i.n};
      final fields = run['fields'] is Map ? (run['fields'] as Map).cast<String, dynamic>() : <String, dynamic>{};
      final result = runAction == null
          ? {'ok': false, 'error': {'type': 'unknown_action', 'detail': 'This action is not installed.'}}
          : await runAction!(run['action'] as String, fields);
      content = await conv.actFinish(run['run_id'] as String, finishReply(result));
      ids = [for (final i in await conv.ids()) if (!before.contains(i.n)) NumberedAddress(n: i.n, address: i.address, title: i.title, link: i.link, time: i.time)];
    }
    return HostToolResult(
      content: content,
      ids: ids,
      navigationActions: await actionsFor(name, content, ids, lookupRoute ?? core.mapRouteById),
    );
  }

  @override
  Future<void> dispose() async {}
}
