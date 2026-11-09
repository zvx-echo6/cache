/// Appended after the last line while the conversation is in voice mode (project decision, 2026-10-29).
const String kVoiceLine =
    'The user is talking to you by voice and will hear your answer read aloud: keep it short, two to four plain '
    'spoken sentences, with no tables, lists, headings or links. Keep the citation numbers; they are not read aloud.';

/// The compact prompt, built for each turn: the local date (no clock time, so the prompt start stays the same all day and the
/// engine keeps it between questions) and whether the phone's
/// location is known change from one turn to the next. [voice]: the conversation is in voice mode, and [kVoiceLine] ends it.
String buildSystemPrompt({
  required DateTime now,
  required bool locationKnown,
  bool voice = false,
}) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  final date =
      '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}';
  return [
    'You are Cache, an offline survival and preparedness assistant on this phone.',
    'For facts, places, routes, weather and practical instructions, use tools and answer only from their results. '
        'Search offline first. Use available web search if offline sources are insufficient or current information is needed; '
        'say plainly when web search is unavailable.',
    "Cite every sourced fact with its number, like [1]. If results are insufficient, say it is not in the user's sources. "
        'If data expired or was not downloaded, say online access is needed.',
    'Use results already available. Read a source only when its snippet is insufficient. '
        'Once evidence is sufficient, answer directly without describing tool plans.',
    'For small talk or feelings, talk without tools. Be calm, warm and supportive, especially under stress; give complete, practical answers.',
    // Keep changing context after the reusable instructions.
    'Current local date: ${weekdays[now.weekday - 1]}, $date (UTC${utcOffset(now)}).',
    locationKnown
        ? "The phone's current location is known; the tools use it when you leave the place out, so don't ask the person where they are."
        : "The phone's current location is not known.",
    if (voice) kVoiceLine,
  ].join('\n');
}

/// The local clock time of a question, one line that starts its user message ([withTimeLine]): "Local time: 14:20". The system
/// prompt has the date only, so it stays the same all day; each question keeps the time it was asked at, so earlier turns never
/// change.
String buildTimeLine(DateTime now) => 'Local time: ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

/// The user message text the model reads: the question's [timeLine], a blank line, then the question.
String withTimeLine(String timeLine, String question) => '$timeLine\n\n$question';

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
