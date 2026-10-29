import 'package:flutter/foundation.dart';

import 'action_def.dart';

/// Runs one action with its fields as the core resolved them and returns the module's result JSON. Throws [ActionFailure].
typedef ActionHandler = Future<Map<String, dynamic>> Function(Map<String, dynamic> fields);

/// Why an action could not do what it was asked; becomes the `error` of the tool result.
class ActionFailure implements Exception {
  const ActionFailure(this.type, this.detail);

  final String type;
  final String detail;

  Map<String, dynamic> toJson() => {'type': type, 'detail': detail};

  @override
  String toString() => detail;
}

/// A definition that was not installed, and why.
class ActionRejection {
  const ActionRejection({required this.module, required this.id, required this.reason});

  final String module;

  /// The id as published (may be missing or malformed).
  final String id;
  final String reason;

  @override
  String toString() => '$module: ${id.isEmpty ? 'an action' : id} rejected: $reason';
}

/// The actions every module of the app publishes, in module order and then each module's own order. A module publishes its whole
/// list at once (again whenever it changes, for example an enum of saved places); definitions that break the contract's rules are
/// rejected with the reason and the module's other actions still load.
class ActionRegistry extends ChangeNotifier {
  final Map<String, List<ActionDef>> _modules = {};
  final Map<String, ActionHandler> _handlers = {};
  List<ActionRejection> _rejected = const [];

  /// The last rejections of each module, for the log.
  List<ActionRejection> get rejected => _rejected;

  /// Every installed definition, as JSON for the core.
  List<Map<String, dynamic>> get definitions => [for (final m in _modules.values) for (final d in m) d.json];

  ActionDef? definition(String id) {
    for (final m in _modules.values) {
      for (final d in m) {
        if (d.id == id) return d;
      }
    }
    return null;
  }

  /// Installs (or replaces) [module]'s actions. [handlers] are by action id; a definition without a handler is rejected.
  List<ActionRejection> publish(String module, List<Map<String, dynamic>> defs, Map<String, ActionHandler> handlers) {
    final taken = {for (final e in _modules.entries) if (e.key != module) for (final d in e.value) d.id};
    final kept = <ActionDef>[];
    final rejected = <ActionRejection>[];
    for (final json in defs) {
      final id = json['id'] is String ? json['id'] as String : '';
      final p = ActionDef.parse(module, json);
      String? reason = p.reason;
      if (reason == null && (taken.contains(id) || kept.any((d) => d.id == id))) reason = 'id is already installed';
      if (reason == null && handlers[id] == null) reason = 'the module has no handler for it';
      if (reason != null) {
        rejected.add(ActionRejection(module: module, id: id, reason: reason));
      } else {
        kept.add(p.def!);
      }
    }
    for (final d in _modules[module] ?? const <ActionDef>[]) {
      _handlers.remove(d.id);
    }
    _modules[module] = kept;
    for (final d in kept) {
      _handlers[d.id] = handlers[d.id]!;
    }
    _rejected = [..._rejected.where((r) => r.module != module), ...rejected];
    for (final r in rejected) {
      debugPrint('cache actions: $r');
    }
    notifyListeners();
    return rejected;
  }

  /// Runs [id] and returns the result as the contract's tool result for [confirmId] (null for read and open, which the core wraps).
  Future<Map<String, dynamic>> run(String id, Map<String, dynamic> fields, {String? confirmId}) async {
    Map<String, dynamic> failed(ActionFailure f) => {
          'ok': false,
          'status': 'failed',
          'confirm_id': ?confirmId,
          'action': id,
          'error': f.toJson(),
        };
    final handler = _handlers[id];
    if (handler == null) return failed(const ActionFailure('unknown_action', 'This action is not installed.'));
    try {
      final result = await handler(fields);
      return {'ok': true, 'status': 'done', 'confirm_id': ?confirmId, 'action': id, 'result': result};
    } on ActionFailure catch (f) {
      return failed(f);
    } catch (e) {
      return failed(ActionFailure('failed', e.toString().replaceFirst('Bad state: ', '')));
    }
  }
}
