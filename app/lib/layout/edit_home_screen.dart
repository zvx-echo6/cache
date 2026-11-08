import 'package:flutter/material.dart';

import '../discover/discover_state.dart';
import '../theme.dart';
import 'adaptive.dart' show ContentWidth;
import 'layout_state.dart';

/// Edit Home: an on/off switch per block, drag to reorder, and Reset to default.
class EditHomeScreen extends StatelessWidget {
  const EditHomeScreen({super.key, required this.layout});

  final LayoutState layout;

  /// Once Discover's first run is done its card has the Set up block's place, and the block is called Discover.
  static bool get _discover => DiscoverState.shared?.firstRunDone ?? false;
  static String _label(HomeBlock b) => b == HomeBlock.setup && _discover ? 'Discover' : b.label;
  static String? _note(HomeBlock b) => b == HomeBlock.setup && _discover ? 'Activities, libraries and maps' : b.note;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Home')),
      body: ListenableBuilder(
        listenable: layout,
        // Reset to default ends the list (it scrolls with the rows, so a short window keeps its whole height for them); a wide
        // window keeps the rows to the content width, centred.
        builder: (context, _) => LayoutBuilder(
          builder: (context, c) => ReorderableListView(
            padding: ContentWidth.padFor(c.maxWidth).copyWith(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom),
            onReorderItem: layout.moveBlock,
            footer: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: layout.resetBlocks,
                  child: const Text('Reset to default'),
                ),
              ),
            ),
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
                      title: Text(_label(b), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
                      subtitle: _note(b) == null ? null : Text(_note(b)!, style: TextStyle(fontSize: 14, color: k.secondary)),
                      value: layout.isOn(b),
                      onChanged: (v) => layout.setBlockOn(b, v),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
