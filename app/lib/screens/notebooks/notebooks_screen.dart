import 'package:flutter/material.dart';

import '../../notebook/notebook_model.dart';
import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../notebook/templates.dart';
import '../../theme.dart';
import '../pin_screen.dart';
import 'connections_screen.dart';
import 'notebook_editor.dart';
import 'notebook_screen.dart';
import 'notebook_search_screen.dart';
import 'quick_add_sheet.dart';

/// The shape a template's icon names.
IconData templateIcon(String icon) => switch (icon) {
      'diamond' => Icons.diamond_outlined,
      'square' => Icons.square_outlined,
      'triangle' => Icons.change_history,
      _ => Icons.circle_outlined,
    };

/// Notebooks: the shelf of the user's notebooks (a fresh install has the Journal), "Log again" for the logs used last, search
/// across all of them, and New notebook.
class NotebooksScreen extends StatefulWidget {
  const NotebooksScreen({super.key, required this.deps, this.templates});

  final NotebookDeps deps;

  /// The templates (tests pass them; the app reads its assets).
  final Templates? templates;

  @override
  State<NotebooksScreen> createState() => _NotebooksScreenState();
}

class _NotebooksScreenState extends State<NotebooksScreen> {
  NotebookState get nb => widget.deps.notebook;
  Templates? _templates;

  @override
  void initState() {
    super.initState();
    _templates = widget.templates;
    if (_templates == null) {
      loadTemplates().then((t) {
        if (mounted) setState(() => _templates = t);
      }).catchError((_) {});
    }
    nb.start();
    widget.deps.connections?.syncAll();
  }

  void _open(Notebook n) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NotebookScreen(deps: widget.deps, notebookId: n.id)));

  void _quickAdd(Notebook n) => showQuickAdd(context, notebook: nb, log: n, places: widget.deps.places, now: widget.deps.now);

  void _new() {
    final t = _templates;
    if (t == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NewNotebookScreen(deps: widget.deps, templates: t)));
  }

  String _line(Notebook n, DateTime now) {
    final t = _templates?.byId(n.template);
    final parts = <String>[t?.name ?? 'Notebook'];
    if (n.isLog) {
      final cue = dueCue(n, now);
      final last = lastDoneText(n, now);
      parts.add(cue != null && cue.overdue ? cue.text : last);
    } else {
      parts.add(t?.count(n.entryCount) ?? '${n.entryCount} ${n.entryCount == 1 ? 'entry' : 'entries'}');
      if (n.fileCount > 0) parts.add(n.fileCount == 1 ? '1 document' : '${n.fileCount} documents');
    }
    if (n.private) parts.add('private');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notebooks'),
        actions: [
          IconButton(
            key: const ValueKey('notebooks-search'),
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NotebookSearchScreen(deps: widget.deps))),
          ),
          if (widget.deps.connections != null || widget.deps.pin != null)
            PopupMenuButton<String>(
              key: const ValueKey('notebooks-menu'),
              onSelected: (c) {
                final d = widget.deps;
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => c == 'pin' ? AppPinScreen(pin: d.pin!) : ConnectionsScreen(connections: d.connections!, shareAvailable: d.shareAvailable?.call() ?? false, folders: d.folders),
                ));
              },
              itemBuilder: (_) => [
                if (widget.deps.connections != null) const PopupMenuItem(value: 'connections', child: Text('Connections')),
                if (widget.deps.pin != null) const PopupMenuItem(value: 'pin', child: Text('App PIN')),
              ],
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('new-notebook'),
        onPressed: _new,
        icon: const Icon(Icons.add),
        label: const Text('New notebook'),
      ),
      body: ListenableBuilder(
        listenable: nb,
        builder: (context, _) {
          if (nb.loading) return const Center(child: CircularProgressIndicator());
          if (nb.error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Notebooks could not open. Your entries are still on this phone.', textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: k.text)),
                    const SizedBox(height: 12),
                    FilledButton(key: const ValueKey('notebooks-retry'), onPressed: nb.reload, child: const Text('Try again')),
                  ],
                ),
              ),
            );
          }
          final now = widget.deps.now();
          final again = [for (final n in nb.logs) if (n.entryCount > 0) n].take(3).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              if (again.isNotEmpty) ...[
                Text('Log again', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.secondary)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final n in again)
                      ActionChip(key: ValueKey('again-${n.id}'), avatar: const Icon(Icons.add, size: 18), label: Text(n.name), onPressed: () => _quickAdd(n)),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              for (final n in nb.notebooks)
                Card(
                  key: ValueKey('notebook-${n.id}'),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    minTileHeight: 64,
                    leading: Icon(templateIcon(_templates?.byId(n.template)?.icon ?? ''), color: k.accent),
                    title: Text(n.name, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                    subtitle: Text(_line(n, now), maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (n.map && n.placeCount > 0) Text('on map', style: TextStyle(fontSize: 13, color: k.secondary)),
                        if (n.isLog)
                          IconButton(key: ValueKey('quick-${n.id}'), tooltip: 'Add entry', icon: const Icon(Icons.add_circle_outline), onPressed: () => _quickAdd(n)),
                      ],
                    ),
                    onTap: () => _open(n),
                  ),
                ),
              if (nb.notebooks.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text('No notebooks yet. Make one with New notebook.', textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: k.secondary)),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// New notebook: "Start from" the templates (Journal, Log, Notes, Places: data, each with what it is for), then the starter
/// logs. A template opens the notebook editor; a starter log is made at once and opens its quick add.
class NewNotebookScreen extends StatefulWidget {
  const NewNotebookScreen({super.key, required this.deps, required this.templates});

  final NotebookDeps deps;
  final Templates templates;

  @override
  State<NewNotebookScreen> createState() => _NewNotebookScreenState();
}

class _NewNotebookScreenState extends State<NewNotebookScreen> {
  bool _starters = false;
  bool _busy = false;

  NotebookState get nb => widget.deps.notebook;

  Future<void> _fromTemplate(NotebookTemplate t) async {
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => NotebookEditor(notebook: nb, template: t)));
    if (made == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _starter(NotebookTemplate t) async {
    final existing = nb.notebooks.where((n) => n.templateRef == t.ref || n.name.toLowerCase() == t.name.toLowerCase()).firstOrNull;
    if (existing != null) {
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => NotebookScreen(deps: widget.deps, notebookId: existing.id)));
      return;
    }
    setState(() => _busy = true);
    try {
      final log = await nb.saveNotebook(template: t.template, def: t.def, private: t.private, map: false, templateRef: t.ref);
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pushReplacement(MaterialPageRoute<void>(builder: (_) => NotebookScreen(deps: widget.deps, notebookId: log.id)));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = nav.context;
        if (ctx.mounted) showQuickAdd(ctx, notebook: nb, log: log, places: widget.deps.places, now: widget.deps.now);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not make it: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final t = widget.templates;
    return Scaffold(
      appBar: AppBar(title: const Text('New notebook')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text('Start from', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.secondary)),
            for (final x in t.notebooks)
              Card(
                key: ValueKey('template-${x.id}'),
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: Icon(templateIcon(x.icon), color: k.accent),
                  title: Text(x.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  subtitle: Text(x.description),
                  onTap: () => _fromTemplate(x),
                ),
              ),
            if (t.starters.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  key: const ValueKey('starter-logs'),
                  leading: Icon(templateIcon('diamond'), color: k.accent),
                  title: const Text('Starter logs', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  subtitle: Text('${t.starters.length} ready-made: ${t.starters.take(3).map((s) => s.name.toLowerCase()).join(', ')}…'),
                  trailing: Icon(_starters ? Icons.expand_less : Icons.expand_more),
                  onTap: () => setState(() => _starters = !_starters),
                ),
              ),
              if (_starters)
                for (final g in t.startersByGroup.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                    child: Text(g.key.toUpperCase(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.secondary)),
                  ),
                  for (final s in g.value)
                    ListTile(
                      key: ValueKey('starter-${s.id}'),
                      title: Text(s.name),
                      subtitle: Text([for (final f in s.def.fields) f.label, if (s.private) 'private'].join(' · ')),
                      onTap: () => _starter(s),
                    ),
                ],
            ],
          ],
        ),
      ),
    );
  }
}
