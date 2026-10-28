import 'package:flutter/material.dart';

import '../app_state.dart';
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

/// The Modules screen: a grid of app icons, each the module's line icon (the one the bottom bar shows) on a rounded square.
/// A tap opens the module; tap and hold offers Pin to bar / Unpin from bar and Add to Home. A dot under the name marks the
/// modules on the bar. Settings > Appearance makes the icons small (64 px, three across) or large (two across, each as wide
/// as its column, the size the module cards had; the grid scrolls).
class ModulesScreen extends StatelessWidget {
  const ModulesScreen({super.key, required this.layout, required this.app, required this.onOpen});

  final LayoutState layout;
  final AppState app;
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
        listenable: Listenable.merge([layout, app]),
        builder: (context, _) => LayoutBuilder(builder: (context, c) => _grid(context, k, c.maxWidth)),
      ),
    );
  }

  Widget _grid(BuildContext context, CacheTokens k, double width) {
    final large = app.largeModuleIcons;
    // Large: two columns 12 apart inside the 16 side margins, each square as wide as its column.
    final box = large ? ((width - 32 - 12) / 2).clamp(64.0, 240.0) : 64.0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: large ? 2 : 3,
            mainAxisSpacing: 20,
            crossAxisSpacing: 12,
            mainAxisExtent: box + 48,
          ),
          children: [
            for (final m in ModuleId.values)
              Semantics(
                button: true,
                label: layout.isPinned(m) ? '${m.label}, on the bar' : m.label,
                onLongPressHint: 'Options',
                excludeSemantics: true,
                child: InkWell(
                  key: ValueKey('module-${m.name}'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => onOpen(m),
                  onLongPress: () => _actions(context, m),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 4),
                      Container(
                        key: ValueKey('module-icon-${m.name}'),
                        width: box,
                        height: box,
                        decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(large ? 36 : 16)),
                        child: Icon(m.icon, size: large ? 80 : 32, color: k.secondary),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        m.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: large ? 18 : 15, fontWeight: large ? FontWeight.w600 : FontWeight.w500, color: k.text),
                      ),
                      const SizedBox(height: 4),
                      // On the bar: a small dot in the accent colour, as the bar's selected label is.
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: layout.isPinned(m) ? k.accent : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Text(
            'Tap and hold an icon for its options',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: k.secondary),
          ),
        ),
      ],
    );
  }
}
