import 'package:flutter/material.dart';

import '../brand.dart';
import '../theme.dart';
import 'layout_state.dart';
import 'modules.dart';

void _say(BuildContext context, String text) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text(text)));
}

/// Adds [s] to Home's Shortcuts and says so (or that it is already there).
void addToHome(BuildContext context, LayoutState layout, Shortcut s) {
  _say(context, layout.addShortcut(s) ? 'Added to Home' : 'Already on Home');
}

/// The Modules screen: a grid of big painted tiles. A tap opens the module; a long press (or the ⋮) offers
/// Pin to bar / Unpin from bar and Add to Home.
class ModulesScreen extends StatelessWidget {
  const ModulesScreen({super.key, required this.layout, required this.onOpen});

  final LayoutState layout;
  final void Function(ModuleId) onOpen;

  Future<void> _actions(BuildContext context, ModuleId m) async {
    final pinned = layout.isPinned(m);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(m.label, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: ctx.t.text)),
              ),
            ),
            ListTile(
              minTileHeight: 56,
              leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined, color: ctx.t.text),
              title: Text(pinned ? 'Unpin from bar' : 'Pin to bar', style: TextStyle(fontSize: 18, color: ctx.t.text)),
              onTap: () => Navigator.pop(ctx, pinned ? 'unpin' : 'pin'),
            ),
            ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.add_home_outlined, color: ctx.t.text),
              title: Text('Add to Home', style: TextStyle(fontSize: 18, color: ctx.t.text)),
              onTap: () => Navigator.pop(ctx, 'home'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'unpin':
        layout.unpin(m);
      case 'pin':
        if (!layout.pin(m)) await _barFull(context, m);
      case 'home':
        addToHome(context, layout, Shortcut.module(m));
    }
  }

  /// The bar holds 3; offers to replace one of them.
  Future<void> _barFull(BuildContext context, ModuleId m) async {
    final old = await showDialog<ModuleId>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('The bar is full (3 max)'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Replace one to pin ${m.label}.', style: TextStyle(fontSize: 16, color: ctx.t.secondary)),
          ),
          for (final p in layout.pinned)
            SimpleDialogOption(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.pop(ctx, p),
              child: ListTile(
                minTileHeight: 56,
                leading: Icon(p.icon, color: ctx.t.text),
                title: Text('Replace ${p.label}', style: const TextStyle(fontSize: 18)),
              ),
            ),
          SimpleDialogOption(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.pop(ctx),
            child: const ListTile(minTileHeight: 56, title: Text('Cancel', style: TextStyle(fontSize: 18))),
          ),
        ],
      ),
    );
    if (old != null) layout.replace(old, m);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Modules')),
      body: ListenableBuilder(
        listenable: layout,
        builder: (context, _) => GridView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: 196,
          ),
          children: [
            for (final m in ModuleId.values)
              Material(
                key: ValueKey('module-${m.name}'),
                color: k.surface,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => onOpen(m),
                  onLongPress: () => _actions(context, m),
                  child: Stack(
                    children: [
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            BrandTileImage(m.tile, size: 96),
                            const SizedBox(height: 8),
                            Text(m.label, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: k.text)),
                            if (layout.isPinned(m))
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text('On the bar', style: TextStyle(fontSize: 13, color: k.secondary)),
                              ),
                          ],
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          key: ValueKey('module-menu-${m.name}'),
                          tooltip: 'More for ${m.label}',
                          icon: Icon(Icons.more_vert, color: k.secondary),
                          onPressed: () => _actions(context, m),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
