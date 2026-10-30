import 'package:flutter/material.dart';

import '../../theme.dart';

/// Asks before a saved place is removed. True when the person said Remove.
Future<bool> confirmRemovePlace(BuildContext context, String name) async => await showDialog<bool>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text('Remove $name?'),
    content: const Text('It is taken off your saved places, and its weather and alerts are no longer kept.'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
      TextButton(key: const ValueKey('confirm-remove-place'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
    ],
  ),
) == true;

/// The square tick box at the end of a row. The row is what is tapped.
class CheckSquare extends StatelessWidget {
  const CheckSquare({super.key, required this.label, required this.checked});

  final String label;
  final bool checked;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      label: label,
      checked: checked,
      child: ExcludeSemantics(
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: checked ? k.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: checked ? k.accent : k.secondary, width: 2),
          ),
          child: checked ? Icon(Icons.check, size: 18, color: k.background) : null,
        ),
      ),
    );
  }
}
