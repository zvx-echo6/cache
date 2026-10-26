import 'package:flutter/material.dart';

import '../theme.dart';
import 'layout_state.dart';

/// Edit Home: an on/off switch per block, drag to reorder, and Reset to default.
class EditHomeScreen extends StatelessWidget {
  const EditHomeScreen({super.key, required this.layout});

  final LayoutState layout;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Home')),
      body: ListenableBuilder(
        listenable: layout,
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: ReorderableListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                onReorderItem: layout.moveBlock,
                children: [
                  for (final b in layout.blockOrder)
                    Padding(
                      key: ValueKey('block-${b.name}'),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Material(
                        color: k.surface,
                        borderRadius: BorderRadius.circular(16),
                        child: SwitchListTile(
                          secondary: ReorderableDragStartListener(
                            index: layout.blockOrder.indexOf(b),
                            child: Icon(Icons.drag_handle, color: k.secondary),
                          ),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
                          title: Text(b.label, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
                          subtitle: b.note == null ? null : Text(b.note!, style: TextStyle(fontSize: 14, color: k.secondary)),
                          value: layout.isOn(b),
                          onChanged: (v) => layout.setBlockOn(b, v),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: layout.resetBlocks,
                    child: const Text('Reset to default'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
