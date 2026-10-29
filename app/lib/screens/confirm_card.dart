import 'package:flutter/material.dart';

import '../actions/confirm.dart';
import '../theme.dart';

/// "place" -> "Place", "route_id" -> "Route id": a field name as a label.
String fieldLabel(String name) {
  final t = name.replaceAll('_', ' ').trim();
  return t.isEmpty ? t : '${t[0].toUpperCase()}${t.substring(1)}';
}

/// What an action the assistant asked for will do, and the two buttons that decide it: the action's title and Cancel. Once decided
/// it shows the outcome instead of the buttons.
class ConfirmCardView extends StatelessWidget {
  const ConfirmCardView({super.key, required this.card, required this.onDecide, this.enabled = true});

  final ConfirmCard card;

  /// True to run the action, false to cancel it.
  final void Function(bool confirm) onDecide;

  /// False while the assistant is answering.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final outcome = switch (card.state) {
      ConfirmState.open => null,
      ConfirmState.running => 'Working…',
      ConfirmState.done => 'Done',
      ConfirmState.declined => 'Cancelled',
      ConfirmState.failed => card.error == null ? 'Could not do it' : 'Could not do it. ${card.error}',
      ConfirmState.dropped => 'Not done',
    };
    final open = card.state == ConfirmState.open && enabled;
    return Container(
      key: ValueKey('confirm-${card.confirmId}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(card.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: k.text)),
          for (final e in card.summary)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${fieldLabel(e.key)}: ${e.value}', style: TextStyle(fontSize: 14, height: 1.35, color: k.secondary)),
            ),
          const SizedBox(height: 4),
          if (outcome == null)
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: ValueKey('confirm-run-${card.confirmId}'),
                  onPressed: open ? () => onDecide(true) : null,
                  child: Text(card.title),
                ),
                TextButton(
                  key: ValueKey('confirm-cancel-${card.confirmId}'),
                  onPressed: open ? () => onDecide(false) : null,
                  child: const Text('Cancel'),
                ),
              ],
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                outcome,
                key: ValueKey('confirm-outcome-${card.confirmId}'),
                style: TextStyle(fontSize: 14, color: card.state == ConfirmState.failed ? k.emergency : k.secondary),
              ),
            ),
        ],
      ),
    );
  }
}
