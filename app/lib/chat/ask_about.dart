import 'dart:convert';

/// "Ask about this" on an alert: a new chat whose first turn is the question, then the `live_data` call the model could have made
/// itself for the item's source and place, then that call's real result, and then the model writes (project decision, 2026-10-29).
/// Only ordinary messages: the model sees a call it could have made.
class AskAbout {
  const AskAbout({required this.sourceTitle, required this.sourceId, required this.place, required this.label});

  /// The source's title as the Weather screen shows it, and its id.
  final String sourceTitle;
  final String sourceId;

  /// The watched place's name, the same text in the question and the call.
  final String place;

  /// The item's label ("Freeze Warning").
  final String label;

  String get question => 'Tell me about this ${sourceTitle.toLowerCase()} item near $place: $label. What does it mean for me, and what should I do?';

  /// The seeded call's tool name and arguments, keys in this order.
  String get toolName => 'live_data';
  Map<String, dynamic> get arguments => {'source': sourceId, 'place': place};
}

/// [value] as JSON written the way the training captures write tool-call arguments (Python's json.dumps with ensure_ascii off and
/// its default separators ", " and ": "), so a seeded call is byte for byte the one the model was trained on.
String spacedJson(Object? value) {
  if (value is Map) {
    return '{${[for (final e in value.entries) '${jsonEncode('${e.key}')}: ${spacedJson(e.value)}'].join(', ')}}';
  }
  if (value is List) return '[${[for (final v in value) spacedJson(v)].join(', ')}]';
  return jsonEncode(value);
}
