import 'package:flutter/material.dart';

import '../../desktop/desktop.dart';
import '../../desktop/hover_row.dart';
import '../../desktop/notebook_chips.dart';
import '../../layout/adaptive.dart';

import '../../notebook/notebook_model.dart';
import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../notebook/templates.dart';
import '../../theme.dart';
import '../pin_screen.dart';
import '../settings/widgets.dart' show Part, SettingsRow;
import 'connections_screen.dart';
import 'notebook_editor.dart';
import 'notebook_screen.dart';
import 'notebook_search_screen.dart';
import 'quick_add_sheet.dart';
import 'repeater_list_screen.dart';
import '../../maps/ui/layer_sheet.dart' show addMapFile;
import '../../maps/user_layers.dart' show UserLayer;

/// The shape a template's icon names.
IconData templateIcon(String icon) => switch (icon) {
      'diamond' => Icons.diamond_outlined,
      'square' => Icons.square_outlined,
      'triangle' => Icons.change_history,
      _ => Icons.circle_outlined,
    };

/// Notebooks: the shelf of the user's notebooks (a fresh install has the Journal) and of each imported repeater list ("Repeaters:
/// [name]"), "Log again" for the logs used last, search across all of them, and + for New notebook and Add from a file (the same
/// sheet as Maps > Layers > My layers).
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
    widget.deps.connections?.addListener(_onSync);
    widget.deps.connections?.syncAll();
  }

  @override
  void dispose() {
    widget.deps.connections?.removeListener(_onSync);
    super.dispose();
  }

  /// Notes imported from Obsidian or Logseq by their tag: "2 notes added from Obsidian" [Show].
  void _onSync() {
    final c = widget.deps.connections;
    if (c == null || !mounted) return;
    final news = c.takeImported();
    if (news.isEmpty) return;
    final titles = [for (final x in news) ...x.titles];
    final apps = {for (final x in news) x.app}.join(' and ');
    final books = {for (final x in news) ...x.books};
    final book = books.length == 1 ? nb.notebook(books.single) : null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      key: const ValueKey('imported-snack'),
      persist: false,
      content: Text(titles.length == 1 ? 'Added from $apps: ${titles.single}.' : '${titles.length} notes added from $apps'),
      action: book == null ? null : SnackBarAction(label: 'Show', onPressed: () => _open(book)),
    ));
  }

  /// The shelf's context inside the two panes (a tablet opens a notebook beside the shelf).
  BuildContext? _pane;

  void _open(Notebook n) => openDetail(_pane ?? context, key: 'notebook-${n.id}', builder: (_) => NotebookScreen(deps: widget.deps, notebookId: n.id));

  void _quickAdd(Notebook n) => showQuickAdd(context, notebook: nb, log: n, places: widget.deps.places, now: widget.deps.now);

  void _openRepeaters(String listId) =>
      openDetail(_pane ?? context, key: 'repeaters-$listId', builder: (_) => RepeaterListScreen(deps: widget.deps, listId: listId));

  Future<void> _add() async {
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size ?? MediaQuery.sizeOf(context);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(size.width - 220, kToolbarHeight + MediaQuery.paddingOf(context).top, 8, 0),
      items: [
        const PopupMenuItem(key: ValueKey('new-notebook'), value: 'new', child: Text('New notebook')),
        const PopupMenuItem(key: ValueKey('notebooks-add-file'), value: 'file', child: Text('Add from a file')),
      ],
    );
    if (!mounted) return;
    if (choice == 'new') _new();
    if (choice == 'file') await addMapFile(context, notebooks: nb, userLayers: widget.deps.userLayers, onShowList: _openRepeaters);
  }

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
  Widget build(BuildContext context) => TwoPane(
    id: 'notebooks',
    listName: 'Notebooks',
    // A tablet shows the shelf across the page until a notebook is opened beside it (no empty pane).
    // (On the Linux desktop the detail pane is always beside the 300-wide shelf, with "Choose an item" until one is opened.)
    listAloneUntilChosen: !isLinuxDesktop(context),
    list: Builder(
      builder: (c) {
        _pane = c;
        return _shelf(c);
      },
    ),
  );

  Widget _shelf(BuildContext context) {
    final k = context.t;
    final hasMenu = widget.deps.connections != null || widget.deps.pin != null;
    // The Linux desktop: from 1280 the 300-wide shelf is permanent, so it has no hide button. At 1024 to 1279 the button stays and
    // Search moves into the overflow menu (or, with no menu, the title is a little smaller) so the title is not cut.
    final wide = isLinuxWide(context);
    final narrow = isLinuxDesktop(context) && !wide;
    final searchInMenu = narrow && hasMenu;
    void openSearch() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NotebookSearchScreen(deps: widget.deps)));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notebooks'),
        titleTextStyle: narrow && !hasMenu ? Theme.of(context).appBarTheme.titleTextStyle?.copyWith(fontSize: 18) : null,
        actions: [
          if (!wide) ?paneHideButton(context),
          IconButton(key: const ValueKey('notebooks-add'), tooltip: 'Add', icon: const Icon(Icons.add), onPressed: _add),
          if (!searchInMenu) IconButton(
            key: const ValueKey('notebooks-search'),
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: openSearch,
          ),
          if (hasMenu)
            PopupMenuButton<String>(
              key: const ValueKey('notebooks-menu'),
              onSelected: (c) {
                if (c == 'search') return openSearch();
                final d = widget.deps;
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => c == 'pin' ? AppPinScreen(pin: d.pin!) : ConnectionsScreen(connections: d.connections!, shareAvailable: d.shareAvailable?.call() ?? false),
                ));
              },
              itemBuilder: (_) => [
                if (searchInMenu) const PopupMenuItem(value: 'search', child: Text('Search')),
                if (widget.deps.connections != null) const PopupMenuItem(value: 'connections', child: Text('Connections')),
                if (widget.deps.pin != null) const PopupMenuItem(value: 'pin', child: Text('App PIN')),
              ],
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([nb, ?widget.deps.userLayers]),
        builder: (context, _) {
          if (nb.loading) return const Center(child: CircularProgressIndicator());
          if (nb.error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Notebooks could not open. Your entries are still on this device.', textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: k.text)),
                    const SizedBox(height: 12),
                    FilledButton(key: const ValueKey('notebooks-retry'), onPressed: nb.reload, child: const Text('Try again')),
                  ],
                ),
              ),
            );
          }
          final now = widget.deps.now();
          final again = [for (final n in nb.logs) if (n.entryCount > 0) n].take(3).toList();
          // The Linux desktop: flat rows across the whole shelf (so the hairline and the chosen row's bar reach its edges); the
          // "Log again" block and the empty note keep the 16-pixel side margin.
          final desk = isLinuxDesktop(context);
          Widget inset(Widget w) => desk ? Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: w) : w;
          return LayoutBuilder(builder: (context, cts) => ListView(
            padding: (desk ? EdgeInsets.zero : ContentWidth.padFor(cts.maxWidth)).copyWith(top: 8, bottom: 96),
            children: [
              if (again.isNotEmpty) ...[
                inset(Text('Log again', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.secondary))),
                const SizedBox(height: 6),
                // The Linux desktop shows them as one row that scrolls sideways; anywhere else they wrap.
                LogAgainChips(
                  chips: [
                    for (final n in again)
                      ActionChip(key: ValueKey('again-${n.id}'), avatar: const Icon(Icons.add, size: 18), label: Text(n.name), onPressed: () => _quickAdd(n)),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (desk)
                for (final n in nb.notebooks)
                  HoverRow(
                    key: ValueKey('notebook-${n.id}'),
                    builder: (context, active) => SettingsRow(
                      leading: Icon(templateIcon(_templates?.byId(n.template)?.icon ?? ''), color: k.accent),
                      title: n.name,
                      status: [Part(_line(n, now))],
                      statusLines: 2,
                      selected: isPaneSelected(context, 'notebook-${n.id}'),
                      onTap: () => _open(n),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (n.map && n.placeCount > 0) Text('on map', style: TextStyle(fontSize: 13, color: k.secondary)),
                          if (n.isLog)
                            RevealAction(
                              shown: active,
                              child: IconButton(
                                key: ValueKey('quick-${n.id}'),
                                tooltip: 'Add entry',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: () => _quickAdd(n),
                              ),
                            ),
                        ],
                      ),
                    ),
                  )
              else
              for (final n in nb.notebooks)
                Card(
                  key: ValueKey('notebook-${n.id}'),
                  color: isPaneSelected(context, 'notebook-${n.id}') ? Color.alphaBlend(k.accent.withValues(alpha: 0.16), k.surface) : null,
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
              if (desk)
                for (final l in widget.deps.userLayers?.repeaterLists ?? const <UserLayer>[])
                  SettingsRow(
                    key: ValueKey('repeaters-${l.id}'),
                    leading: Icon(Icons.cell_tower, color: k.accent),
                    title: 'Repeaters: ${l.name}',
                    status: [Part(l.count == 1 ? '1 repeater' : '${l.count} repeaters')],
                    statusLines: 2,
                    selected: isPaneSelected(context, 'repeaters-${l.id}'),
                    trailing: l.visible ? Text('on map', style: TextStyle(fontSize: 13, color: k.secondary)) : null,
                    onTap: () => _openRepeaters(l.id),
                  )
              else
              for (final l in widget.deps.userLayers?.repeaterLists ?? const <UserLayer>[])
                Card(
                  key: ValueKey('repeaters-${l.id}'),
                  color: isPaneSelected(context, 'repeaters-${l.id}') ? Color.alphaBlend(k.accent.withValues(alpha: 0.16), k.surface) : null,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    minTileHeight: 64,
                    leading: Icon(Icons.cell_tower, color: k.accent),
                    title: Text('Repeaters: ${l.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                    subtitle: Text(l.count == 1 ? '1 repeater' : '${l.count} repeaters', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: l.visible ? Text('on map', style: TextStyle(fontSize: 13, color: k.secondary)) : null,
                    onTap: () => _openRepeaters(l.id),
                  ),
                ),
              if (nb.notebooks.isEmpty && (widget.deps.userLayers?.repeaterLists.isEmpty ?? true))
                inset(Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text('No notebooks yet. Make one with New notebook.', textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: k.secondary)),
                )),
            ],
          ));
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
