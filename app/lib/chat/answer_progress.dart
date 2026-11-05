import 'package:flutter/material.dart';

import '../theme.dart';
import 'answer_markdown.dart';
import 'tool_loop.dart';

/// One stable response: progress stays in place and streamed work is appended,
/// including a model preamble that is later followed by a tool call.
class AnswerProgress extends StatelessWidget {
  const AnswerProgress({
    super.key,
    required this.phase,
    this.activeTool,
    this.notes = const [],
    this.text = '',
    this.failed = false,
  });

  final TurnPhase phase;
  final String? activeTool;
  final List<String> notes;
  final String text;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final done = phase == TurnPhase.done;
    final status = switch (phase) {
      TurnPhase.starting => 'Starting…',
      TurnPhase.searching => switch (activeTool) {
        'search' => 'Looking this up…',
        'read' => 'Reading from source…',
        _ => 'Working…',
      },
      TurnPhase.done => failed || text.isEmpty ? null : 'Answer delivered',
      _ => 'Preparing answer…',
    };
    // Promotion of the current text into notes leaves this rendered text intact.
    final visible = [...notes, if (text.isNotEmpty) text].join('\n\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status != null)
          Padding(
            key: const ValueKey('answer-progress'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: done
                      ? Icon(Icons.check, size: 14, color: k.secondary)
                      : CircularProgressIndicator(
                          strokeWidth: 2,
                          color: k.secondary,
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    status,
                    style: TextStyle(fontSize: 15, color: k.secondary),
                  ),
                ),
              ],
            ),
          ),
        if (visible.isNotEmpty) AnswerMarkdown(visible),
      ],
    );
  }
}
