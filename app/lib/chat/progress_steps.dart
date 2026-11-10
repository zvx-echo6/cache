/// One tool call as the progress line shows it: the tool's name and the arguments the model gave it. UI state only; never sent
/// to the model.
class ToolStep {
  const ToolStep(this.tool, [this.arguments = const {}, this.title]);

  final String tool;
  final Map<String, dynamic> arguments;

  /// A name the app looked up for the call: the title of the source a `read` opens, or of the action an `act` runs.
  final String? title;

  ToolStep withTitle(String? t) => ToolStep(tool, arguments, t);
}

/// The most characters of a person's or the model's words that go into a step line.
const int kStepValueMax = 60;

/// A value for a step line: whitespace collapsed to single spaces, double quotes removed, cut to [kStepValueMax] characters with
/// an ellipsis. Null when nothing is left. Formatting only: nothing is matched against the words.
String? stepValue(Object? raw) {
  if (raw is! String) return null;
  final out = <int>[];
  var gap = false;
  for (final c in raw.runes) {
    if (c == 0x22 || c == 0x201C || c == 0x201D) continue;
    if (c <= 0x20 || c == 0xA0) {
      gap = out.isNotEmpty;
      continue;
    }
    if (gap) out.add(0x20);
    gap = false;
    out.add(c);
  }
  if (out.isEmpty) return null;
  if (out.length > kStepValueMax) return '${String.fromCharCodes(out.take(kStepValueMax)).trimRight()}…';
  return String.fromCharCodes(out);
}

/// One tool's wording, present and past tense, with a value filled in from the call's own arguments or without one.
/// `{}` marks where the value goes. A present line ends with an ellipsis; the past line is the same step finished.
class StepTemplate {
  const StepTemplate(this.present, this.past, {required this.presentBare, required this.pastBare, this.value});

  final String present;
  final String past;
  final String presentBare;
  final String pastBare;

  /// The value of a call, from its arguments (and the title the app looked up); null: use the bare wording.
  final String? Function(ToolStep step)? value;
}

String? _arg(ToolStep s, String key) => stepValue(s.arguments[key]);

/// What `read` opened: its title, found by the loop from the earlier result with that number.
String? _title(ToolStep s) => stepValue(s.title);

/// The tool name selects the template; the call's arguments fill it. Any tool not here is "Working…".
final Map<String, StepTemplate> kStepTemplates = {
  'search': StepTemplate('Searching your library for "{}"…', 'Searched your library for "{}"',
      presentBare: 'Searching your library…', pastBare: 'Searched your library', value: (s) => _arg(s, 'query')),
  'read': StepTemplate('Reading {}…', 'Read {}', presentBare: 'Reading a source…', pastBare: 'Read a source', value: _title),
  'calculate': const StepTemplate('Calculating…', 'Calculated', presentBare: 'Calculating…', pastBare: 'Calculated'),
  'nearby': StepTemplate('Searching nearby for: {}…', 'Searched nearby for: {}',
      presentBare: 'Looking for places near you…',
      pastBare: 'Looked for places near you',
      value: (s) => _arg(s, 'category')?.replaceAll('_', ' ') ?? _arg(s, 'query')),
  'navigate': StepTemplate('Planning a route to {}…', 'Planned a route to {}',
      presentBare: 'Planning a route…', pastBare: 'Planned a route', value: (s) => _arg(s, 'to') ?? _arg(s, 'to_type')?.replaceAll('_', ' ')),
  'locate': const StepTemplate('Finding where you are…', 'Found where you are',
      presentBare: 'Finding where you are…', pastBare: 'Found where you are'),
  'act': StepTemplate('Running {}…', 'Ran {}',
      presentBare: 'Running an action…', pastBare: 'Ran an action', value: (s) => _title(s) ?? _arg(s, 'action')),
};

const String kWorkingLine = 'Working…';
const String kFinishedStepLine = 'Finished a step';

/// The line for a step that is running (ends with an ellipsis).
String stepPresent(ToolStep step) {
  final t = kStepTemplates[step.tool];
  if (t == null) return kWorkingLine;
  final v = t.value?.call(step);
  return v == null ? t.presentBare : t.present.replaceFirst('{}', v);
}

/// The line for a step that finished: the same words in the past tense, no trailing ellipsis.
String stepPast(ToolStep step) {
  final t = kStepTemplates[step.tool];
  if (t == null) return kFinishedStepLine;
  final v = t.value?.call(step);
  return v == null ? t.pastBare : t.past.replaceFirst('{}', v);
}
