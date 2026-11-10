import 'package:flutter/material.dart';

import '../theme.dart';
import 'answer_markdown.dart';
import 'progress_steps.dart';
import 'tool_loop.dart';

/// One stable response: progress stays in place and streamed work is appended,
/// including a model preamble that is later followed by a tool call.
class AnswerProgress extends StatefulWidget {
  const AnswerProgress({
    super.key,
    required this.phase,
    this.activeTool,
    this.activeStep,
    this.steps = const [],
    this.notes = const [],
    this.text = '',
    this.failed = false,
    this.queuePosition,
  });

  final TurnPhase phase;
  final String? activeTool;

  /// The tool call running now with its arguments; when null the line is made from [activeTool] alone.
  final ToolStep? activeStep;

  /// The tool calls that finished in this answer, oldest first: the trail of ticked steps above the current line.
  final List<ToolStep> steps;
  final List<String> notes;
  final String text;
  final bool failed;

  /// How many answers are ahead of this one on the server (1 is next); null when it runs or does not wait.
  final int? queuePosition;

  @override
  State<AnswerProgress> createState() => _AnswerProgressState();
}

class _AnswerProgressState extends State<AnswerProgress> {
  /// Set once the answer text has started: the trail stays one line from then on (a preamble that turns into a note does not
  /// open it again).
  bool _textStarted = false;

  /// The person opened the trail.
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _textStarted = widget.text.isNotEmpty;
  }

  @override
  void didUpdateWidget(AnswerProgress old) {
    super.didUpdateWidget(old);
    if (widget.text.isNotEmpty) _textStarted = true;
  }

  Widget _trail(BuildContext context, bool collapsed) {
    final k = context.t;
    final steps = widget.steps;
    final n = steps.length;
    final label = n == 1 ? '1 step' : '$n steps';
    final open = !collapsed || _expanded;
    final line = TextStyle(fontSize: 13, color: k.secondary);
    return Column(
      key: const ValueKey('answer-trail'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (collapsed)
          Semantics(
            button: true,
            expanded: _expanded,
            label: '$label, ${_expanded ? 'hide' : 'show'} steps',
            excludeSemantics: true,
            onTap: () => setState(() => _expanded = !_expanded),
            child: InkWell(
              key: const ValueKey('answer-trail-toggle'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: line),
                    const SizedBox(width: 4),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: k.secondary),
                  ],
                ),
              ),
            ),
          ),
        if (open)
          for (final s in steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.check, size: 13, color: k.secondary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(stepPast(s), style: line)),
                ],
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final (phase, activeTool, notes, text, failed, queuePosition) =
        (widget.phase, widget.activeTool, widget.notes, widget.text, widget.failed, widget.queuePosition);
    final done = phase == TurnPhase.done;
    final ahead = done ? null : queuePosition;
    final status = ahead != null
        ? (ahead > 1 ? 'Waiting for $ahead answers ahead to finish' : 'Waiting for another answer to finish')
        : switch (phase) {
      TurnPhase.starting => 'Starting…',
      TurnPhase.searching => widget.activeStep != null
          ? stepPresent(widget.activeStep!)
          : activeTool != null
              ? stepPresent(ToolStep(activeTool))
              : 'Preparing answer…',
      TurnPhase.done => failed || text.isEmpty ? null : 'Answer delivered',
      _ => 'Preparing answer…',
    };
    // Promotion of the current text into notes leaves this rendered text intact.
    final visible = [...notes, if (text.isNotEmpty) text].join('\n\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.steps.isNotEmpty) _trail(context, done || _textStarted),
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
