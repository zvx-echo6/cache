import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.app, required this.onOpenAsk});

  final AppState app;
  final VoidCallback onOpenAsk;

  void _comingSoon(BuildContext context) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(const SnackBar(content: Text('Coming soon')));
  }

  Future<void> _pickTheme(BuildContext context) async {
    final chosen = await showDialog<CacheThemeId>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Theme'),
        children: [
          for (final id in CacheThemeId.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, id),
              padding: EdgeInsets.zero,
              child: ListTile(
                minTileHeight: 56,
                leading: Icon(id == app.theme ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: ctx.t.accent),
                title: Text(id.label, style: const TextStyle(fontSize: 18)),
                subtitle: Text(id.hint),
              ),
            ),
        ],
      ),
    );
    if (chosen != null) app.setTheme(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('CACHE', style: TextStyle(letterSpacing: 2)),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Menu',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'theme') _pickTheme(context);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'theme', height: 52, child: Text('Theme')),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            InkWell(
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
                    Expanded(
                      child: Text('Ask anything', style: TextStyle(fontSize: 18, color: k.secondary)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _QuickAction(icon: Icons.local_hospital_outlined, label: 'Hospital', color: k.emergency, onTap: () => _comingSoon(context)),
                _QuickAction(icon: Icons.healing_outlined, label: 'First aid', color: k.emergency, onTap: () => _comingSoon(context)),
                _QuickAction(icon: Icons.water_drop_outlined, label: 'Water', color: k.accent, onTap: () => _comingSoon(context)),
                _QuickAction(icon: Icons.navigation_outlined, label: 'Navigate', color: k.accent, onTap: () => _comingSoon(context)),
              ],
            ),
            const SizedBox(height: 28),
            Text('On this phone', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _cards(context),
          ],
        ),
      ),
    );
  }

  Widget _cards(BuildContext context) {
    final k = context.t;
    final String modelValue;
    final Color modelColor;
    if (app.loading != null) {
      modelValue = 'Loading…';
      modelColor = k.secondary;
    } else if (app.active != null) {
      modelValue = 'Ready';
      modelColor = k.ok;
    } else {
      modelValue = 'No model';
      modelColor = k.warning;
    }
    final cards = [
      _StatusCard(icon: Icons.memory, title: app.active == null ? 'Model' : app.displayName(app.active!), value: modelValue, valueColor: modelColor),
      const _StatusCard(icon: Icons.menu_book_outlined, title: 'Reading', value: 'Not set up yet'),
      const _StatusCard(icon: Icons.map_outlined, title: 'Maps', value: 'Not set up yet'),
      const _StatusCard(icon: Icons.cloud_outlined, title: 'Weather', value: 'Not set up yet'),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.45,
      children: cards,
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: k.surface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 84),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 28, color: color),
                  const SizedBox(height: 6),
                  Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: k.text)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.icon, required this.title, required this.value, this.valueColor});

  final IconData icon;
  final String title;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: k.secondary),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontSize: 15, color: valueColor ?? k.secondary)),
            ],
          ),
        ],
      ),
    );
  }
}
