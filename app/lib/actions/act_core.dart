import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../chat/tool.dart';
import '../search/core_numbering.dart';

/// What the app needs from the core's `act` tool (docs/ACTIONS.md): the core renders the tool description from the installed
/// definitions and checks every call; a read or open call comes back to the host as host_run (run by [CoreToolHost], finished with
/// cs_act_finish); a change call runs on the confirm card's tap with the machine values cs_act_resolve gave when the card was shown,
/// and its outcome goes back through cs_act_outcome.
abstract class ActCore {
  /// cs_act_set_definitions: makes [definitions] the installed set, if the core does not hold exactly these already. True when they
  /// were sent to the core.
  Future<bool> install(List<Map<String, dynamic>> definitions);

  /// cs_act_set_modules_off: the modules switched off.
  Future<void> setModulesOff(List<String> modules);

  /// cs_act_resolve: the same checks and resolution as the `act` call. `{"ok":true,"action":...,"fields":{...}}` with each `place`
  /// field as `{"lat","lon","name"?,"label"?}`, or `{"ok":false,"error":{"type","detail","field"?}}`.
  Future<Map<String, dynamic>> actResolve(String action, Map<String, dynamic> fields);

  /// cs_act_outcome: the exact content of the system message that carries [outcome] (done, declined or failed) into the
  /// conversation [numbering] numbers in.
  Future<String> outcome(ResultNumbering? numbering, Map<String, dynamic> outcome);
}

/// The contract's outcome message without the core (tests, and a chat with no core conversation): keys in the contract's order.
String hostEventContent(Map<String, dynamic> outcome) => jsonEncode({
      'host_event': 'act_outcome',
      'ok': outcome['ok'],
      'status': outcome['status'],
      'confirm_id': outcome['confirm_id'],
      'action': outcome['action'],
      if (outcome.containsKey('result')) 'result': outcome['result'],
      if (outcome.containsKey('error')) 'error': outcome['error'],
    });

/// The search core's act tool.
class CoreActCore implements ActCore {
  CoreActCore(this.core);

  /// The open core, or null while there is none.
  final SearchCore? Function() core;

  SearchCore? _installedIn;
  String? _installed;

  SearchCore _open() => core() ?? (throw StateError('The search core is not available'));

  @override
  Future<bool> install(List<Map<String, dynamic>> definitions) async {
    final c = core();
    if (c == null) return false;
    final text = jsonEncode(definitions);
    // The set is kept in the core's memory only, so a core opened again gets it again.
    if (identical(c, _installedIn) && text == _installed) return false;
    final report = await c.actSetDefinitions(definitions);
    _installedIn = c;
    _installed = text;
    final rejected = report['rejected'];
    final notListed = report['not_listed'];
    if ((rejected is List && rejected.isNotEmpty) || (notListed is List && notListed.isNotEmpty)) {
      debugPrint('cache act: rejected $rejected, not listed $notListed');
    }
    return true;
  }

  @override
  Future<void> setModulesOff(List<String> modules) async => _open().actSetModulesOff(modules);

  @override
  Future<Map<String, dynamic>> actResolve(String action, Map<String, dynamic> fields) => _open().actResolve(action, fields);

  @override
  Future<String> outcome(ResultNumbering? numbering, Map<String, dynamic> outcome) async {
    if (numbering is! CoreNumbering) return hostEventContent(outcome);
    return (await numbering.conversation).actOutcome(outcome);
  }
}
