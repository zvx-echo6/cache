/// Appended after the last line while the conversation is in voice mode (project decision, 2026-10-29).
const String kVoiceLine = 'The user is talking to you by voice and will hear your answer read aloud: keep it short, two to four plain '
    'spoken sentences, with no tables, lists, headings or links. Keep the citation numbers; they are not read aloud.';

/// The system prompt, built for each turn (the approved template): the local date and time and whether the phone's
/// location is known change from one turn to the next. [voice]: the conversation is in voice mode, and [kVoiceLine] ends it.
String buildSystemPrompt({required DateTime now, required bool locationKnown, bool voice = false}) {
  const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}';
  final time = '${two(now.hour)}:${two(now.minute)}';
  return [
    'You are Cache, an offline survival and preparedness assistant running on this phone.',
    'Current local date and time: ${weekdays[now.weekday - 1]}, $date $time (UTC${utcOffset(now)}).',
    locationKnown
        ? "The phone's current location is known; the tools use it when you leave the place out, so don't ask the person where they are."
        : "The phone's current location is not known.",
    'Use your tools to look things up before answering questions about facts, places, routes, weather or how to do things. '
        'Answer facts only from tool results, not from memory. Search the offline sources first. '
        'Use web search only when it is available and the offline sources don\'t cover the question, or the question needs current information; '
        'if you can\'t search the web, say so plainly.',
    'Cite every fact you take from a tool result with its number in square brackets, like [1]. '
        'If your tools find nothing useful, say it is not in the user\'s sources. '
        'If a tool says its data has expired or was never downloaded, say plainly that you need to go online for more.',
    'For small talk or feelings, just talk; no tools needed. '
        'Be calm, warm and supportive, especially when the person is stressed or alone, and give complete, practical answers.',
    if (voice) kVoiceLine,
  ].join('\n');
}

/// "+HH:MM" or "-HH:MM", the UTC offset of [t].
String utcOffset(DateTime t) {
  final o = t.timeZoneOffset;
  final m = o.inMinutes.abs();
  return '${o.isNegative ? '-' : '+'}${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

/// ISO 8601 with the local UTC offset, the form the core takes for "now" and "fixed_at": 2026-10-25T14:20:05-06:00.
String isoWithOffset(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}${utcOffset(t)}';
}
