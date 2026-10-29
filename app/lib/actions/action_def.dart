/// One action a module publishes for the `act` tool (docs: the actions contract). The JSON is what the core gets; this class only
/// checks it against the contract's rules when the module is installed.
enum ActionEffect { read, open, change }

class ActionDef {
  const ActionDef._(this.json, this.effect);

  /// The definition exactly as published.
  final Map<String, dynamic> json;
  final ActionEffect effect;

  String get id => json['id'] as String;
  String get module => json['module'] as String;
  String get title => json['title'] as String;

  /// The definition for [json] published by [module], or the reason it breaks the contract's rules.
  static ({ActionDef? def, String? reason}) parse(String module, Map<String, dynamic> json) {
    final reason = _check(module, json);
    if (reason != null) return (def: null, reason: reason);
    return (def: ActionDef._(json, ActionEffect.values.byName(json['effect'] as String)), reason: null);
  }
}

const int kMaxActionId = 48;
const int kMaxActionTitle = 40;
const int kMaxActionDescription = 120;
const int kMaxFieldDescription = 80;
const int kMaxActionFields = 10;

final _idPattern = RegExp(r'^[a-z0-9_]+(\.[a-z0-9_]+)+$');
final _fieldPattern = RegExp(r'^[a-z0-9_]+$');
const _topKeys = {'id', 'module', 'title', 'description', 'effect', 'fields', 'required'};
const _typeKeys = {
  'string': {'maxLength', 'enum'},
  'number': {'minimum', 'maximum'},
  'integer': {'minimum', 'maximum'},
  'boolean': <String>{},
  'date': <String>{},
  'time': <String>{},
  'duration': <String>{},
  'place': <String>{},
};

String? _text(Map<String, dynamic> j, String key, int max) {
  final v = j[key];
  if (v is! String || v.trim().isEmpty) return '$key is missing';
  if (v.length > max) return '$key is longer than $max characters';
  return null;
}

String? _check(String module, Map<String, dynamic> j) {
  for (final k in j.keys) {
    if (!_topKeys.contains(k)) return 'unknown key $k';
  }
  final id = j['id'];
  if (id is! String || !_idPattern.hasMatch(id)) return 'id must be <module>.<verb> in lowercase a-z 0-9 _ .';
  if (id.length > kMaxActionId) return 'id is longer than $kMaxActionId characters';
  final prefix = id.substring(0, id.indexOf('.'));
  if (j['module'] != prefix) return 'module must be the id\'s prefix ($prefix)';
  if (prefix != module) return 'the action belongs to module $prefix, not $module';
  final text = _text(j, 'title', kMaxActionTitle) ?? _text(j, 'description', kMaxActionDescription);
  if (text != null) return text;
  if (!ActionEffect.values.any((e) => e.name == j['effect'])) return 'effect must be read, open or change';
  final fields = j['fields'] ?? const <String, dynamic>{};
  if (fields is! Map) return 'fields must be an object';
  if (fields.length > kMaxActionFields) return 'more than $kMaxActionFields fields';
  for (final e in fields.entries) {
    final name = e.key;
    if (name is! String || !_fieldPattern.hasMatch(name)) return 'field name $name must be lowercase a-z 0-9 _';
    final reason = _checkField(e.value);
    if (reason != null) return 'field $name: $reason';
  }
  final required = j['required'] ?? const [];
  if (required is! List) return 'required must be a list';
  final seen = <String>{};
  for (final r in required) {
    if (r is! String || !fields.containsKey(r)) return 'required names a field that does not exist ($r)';
    if (!seen.add(r)) return 'required names $r twice';
  }
  return null;
}

String? _checkField(dynamic f) {
  if (f is! Map) return 'must be an object';
  final type = f['type'];
  final allowed = _typeKeys[type];
  if (allowed == null) return 'unknown type $type';
  for (final k in f.keys) {
    if (k == 'type' || k == 'description') continue;
    if (!allowed.contains(k)) return 'key $k does not apply to type $type';
  }
  final d = f['description'];
  if (d != null && (d is! String || d.length > kMaxFieldDescription)) return 'description must be text of at most $kMaxFieldDescription characters';
  if (type == 'string') {
    final max = f['maxLength'];
    if (max != null && (max is! int || max < 1)) return 'maxLength must be a positive whole number';
    final values = f['enum'];
    if (values != null) {
      if (values is! List || values.isEmpty || values.any((v) => v is! String || v.isEmpty)) return 'enum must be a list of strings';
      if (values.toSet().length != values.length) return 'enum has a value twice';
    }
  }
  if (type == 'number' || type == 'integer') {
    final min = f['minimum'], max = f['maximum'];
    for (final v in [min, max]) {
      if (v != null && (v is! num || (type == 'integer' && v is! int))) return 'minimum and maximum must be ${type == 'integer' ? 'whole numbers' : 'numbers'}';
    }
    if (min is num && max is num && min > max) return 'minimum is above maximum';
  }
  return null;
}
