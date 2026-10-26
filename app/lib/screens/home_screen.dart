import 'package:flutter/material.dart';

import '../brand.dart';
import '../layout/edit_home_screen.dart';
import '../layout/layout_state.dart';
import '../theme.dart';

/// Home: the blocks the person chose, in the order they chose (Ask box, Weather, Alerts, Shortcuts by default), a gear
/// for Settings at the top right, and "Edit Home" at the bottom.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.layout,
    required this.onOpenAsk,
    required this.onOpenSettings,
    required this.onOpenShortcut,
  });

  final LayoutState layout;
  final VoidCallback onOpenAsk;
  final VoidCallback onOpenSettings;
  final void Function(Shortcut) onOpenShortcut;

  void _editHome(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditHomeScreen(layout: layout)));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const BrandWordmark(height: 30),
        actions: [
          IconButton(
            key: const ValueKey('home-settings'),
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: onOpenSettings,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: layout,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            for (final b in layout.visibleBlocks) ...[
              switch (b) {
                HomeBlock.ask => _askBox(k),
                HomeBlock.weather => _InfoCard(tile: BrandTile.weather, title: 'Weather', value: 'Not set up yet'),
                HomeBlock.alerts => _InfoCard(tile: BrandTile.alerts, title: 'Alerts', value: 'Not set up yet'),
                HomeBlock.shortcuts => _shortcuts(context, k),
              },
              const SizedBox(height: 16),
            ],
            Align(
              alignment: Alignment.center,
              child: TextButton(
                key: const ValueKey('edit-home'),
                onPressed: () => _editHome(context),
                child: const Text('Edit Home', style: TextStyle(fontSize: 17)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _askBox(CacheTokens k) => InkWell(
        key: const ValueKey('home-ask'),
        onTap: onOpenAsk,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(28)),
          child: Row(
            children: [
              Icon(Icons.search, color: k.secondary),
              const SizedBox(width: 12),
              Expanded(child: Text('Ask anything', style: TextStyle(fontSize: 18, color: k.secondary))),
            ],
          ),
        ),
      );

  Widget _shortcuts(BuildContext context, CacheTokens k) {
    final items = layout.shortcuts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Shortcuts', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (items.isEmpty)
          Text(
            'Nothing here yet. Use "Add to Home" on a module, a place on the map, a Library page or a chat.',
            style: TextStyle(fontSize: 16, color: k.secondary),
          )
        else
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: 132,
            ),
            children: [
              for (final s in items)
                ShortcutCard(
                  key: ValueKey('shortcut-${s.key}'),
                  shortcut: s,
                  onTap: () => onOpenShortcut(s),
                  onLongPress: () => _manage(context, s),
                ),
            ],
          ),
      ],
    );
  }

  /// Long press on a card: remove it, or move it earlier or later.
  Future<void> _manage(BuildContext context, Shortcut s) async {
    final i = layout.shortcuts.indexWhere((x) => x.key == s.key);
    final last = layout.shortcuts.length - 1;
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
                child: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: ctx.t.text)),
              ),
            ),
            if (i > 0)
              ListTile(minTileHeight: 56, leading: Icon(Icons.arrow_back, color: ctx.t.text), title: const Text('Move earlier', style: TextStyle(fontSize: 18)), onTap: () => Navigator.pop(ctx, 'earlier')),
            if (i >= 0 && i < last)
              ListTile(minTileHeight: 56, leading: Icon(Icons.arrow_forward, color: ctx.t.text), title: const Text('Move later', style: TextStyle(fontSize: 18)), onTap: () => Navigator.pop(ctx, 'later')),
            ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.delete_outline, color: ctx.t.emergency),
              title: Text('Remove from Home', style: TextStyle(fontSize: 18, color: ctx.t.emergency)),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'earlier':
        layout.nudgeShortcut(s, -1);
      case 'later':
        layout.nudgeShortcut(s, 1);
      case 'remove':
        layout.removeShortcut(s);
    }
  }
}

/// A shortcut card: the module's painted tile (or an icon for the rest), the name and what it is.
class ShortcutCard extends StatelessWidget {
  const ShortcutCard({super.key, required this.shortcut, required this.onTap, required this.onLongPress});

  final Shortcut shortcut;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = shortcut;
    final Widget art = switch (s.kind) {
      ShortcutKind.module => BrandTileImage(s.module!.tile, size: 48),
      ShortcutKind.chat => const BrandTileImage(BrandTile.chat, size: 48),
      ShortcutKind.page => const BrandTileImage(BrandTile.library, size: 48),
      ShortcutKind.place => SizedBox(height: 48, width: 48, child: Icon(Icons.place_outlined, size: 34, color: k.accent)),
    };
    return Material(
      color: k.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              art,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                  if (s.subtitle.isNotEmpty)
                    Text(s.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.tile, required this.title, required this.value});

  final BrandTile tile;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          BrandTileImage(tile, size: 48),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                const SizedBox(height: 2),
                Text(value, style: TextStyle(fontSize: 15, color: k.secondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
