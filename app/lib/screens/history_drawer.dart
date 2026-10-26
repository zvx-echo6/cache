import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../history/conversation_store.dart';
import '../history/date_groups.dart';
import '../history/share.dart';
import '../layout/layout_state.dart';
import '../layout/modules_screen.dart' show addToHome;
import '../theme.dart';

/// The list of past conversations, opened from the Ask top bar: New chat, a search box, then Pinned and
/// the conversations grouped by date.
class HistoryDrawer extends StatefulWidget {
  const HistoryDrawer({super.key, required this.chat, this.now, this.share = shareMarkdown, this.layout, this.width, this.onChosen});

  final ChatController chat;

  /// The drawer's width (the Material default when null); Settings shows the list as a page, so it asks for all the width.
  final double? width;

  /// Called after a chat was opened or a new one started from the list, once the list has closed (Settings uses it to bring Ask forward).
  final VoidCallback? onChosen;

  /// Where "Add to Home" puts a chat shortcut; the item is hidden when null.
  final LayoutState? layout;

  /// The clock for the date groups (a test hook).
  final DateTime Function()? now;
  final ShareMarkdown share;

  @override
  State<HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<HistoryDrawer> {
  final _query = TextEditingController();
  List<Conversation> _all = const [];
  List<SearchHit> _hits = const [];

  @override
  void initState() {
    super.initState();
    widget.chat.historyRevision.addListener(_reload);
    widget.chat.addListener(_rebuild);
    _reload();
  }

  @override
  void dispose() {
    widget.chat.historyRevision.removeListener(_reload);
    widget.chat.removeListener(_rebuild);
    _query.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _reload() {
    final store = widget.chat.store;
    if (!mounted) return;
    setState(() {
      _all = store?.list() ?? const [];
      _hits = store == null ? const [] : store.search(_query.text);
    });
  }

  void _open(int id) {
    widget.chat.openConversation(id);
    Navigator.of(context).pop();
    widget.onChosen?.call();
  }

  void _newChat() {
    widget.chat.newChat();
    Navigator.of(context).pop();
    widget.onChosen?.call();
  }

  Future<void> _longPress(Conversation c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetTile(ctx, Icons.edit_outlined, 'Rename', 'rename'),
            _sheetTile(ctx, c.pinned ? Icons.push_pin : Icons.push_pin_outlined, c.pinned ? 'Unpin' : 'Pin', 'pin'),
            _sheetTile(ctx, Icons.ios_share, 'Share as Markdown', 'share'),
            if (widget.layout != null) _sheetTile(ctx, Icons.add_home_outlined, 'Add to Home', 'home'),
            _sheetTile(ctx, Icons.delete_outline, 'Delete', 'delete', color: ctx.t.emergency),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        final title = await _askTitle(c.title);
        if (title != null) await widget.chat.renameConversation(c.id, title);
      case 'pin':
        widget.chat.setPinned(c.id, !c.pinned);
      case 'home':
        addToHome(context, widget.layout!, Shortcut.chat(id: c.id, title: c.title));
      case 'share':
        final md = widget.chat.exportMarkdown(c.id);
        if (md != null) await widget.share(c.title, md);
      case 'delete':
        final messenger = ScaffoldMessenger.of(context);
        widget.chat.deleteConversation(c.id);
        Navigator.of(context).pop();
        messenger.hideCurrentSnackBar();
        messenger
            .showSnackBar(SnackBar(
              content: const Text('Chat deleted'),
              persist: false, // a snack bar with an action would otherwise stay until dismissed
              duration: const Duration(seconds: 6),
              action: SnackBarAction(label: 'Undo', onPressed: () => widget.chat.undoDelete(c.id)),
            ))
            .closed
            .then((reason) {
          if (reason != SnackBarClosedReason.action) widget.chat.purgeConversation(c.id);
        });
    }
  }

  Widget _sheetTile(BuildContext ctx, IconData icon, String label, String value, {Color? color}) => ListTile(
        minTileHeight: 56,
        leading: Icon(icon, color: color ?? ctx.t.text),
        title: Text(label, style: TextStyle(fontSize: 18, color: color ?? ctx.t.text)),
        onTap: () => Navigator.pop(ctx, value),
      );

  Future<String?> _askTitle(String current) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: 18),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final searching = _query.text.trim().isNotEmpty;
    return Drawer(
      width: widget.width,
      backgroundColor: k.background,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                controller: _query,
                onChanged: (_) => _reload(),
                style: const TextStyle(fontSize: 18),
                decoration: InputDecoration(
                  hintText: 'Search chats',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: searching
                      ? IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _query.clear();
                            _reload();
                          },
                        )
                      : null,
                ),
              ),
            ),
            ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.add_comment_outlined, color: k.accent),
              title: Text('New chat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.accent)),
              onTap: _newChat,
            ),
            Expanded(child: searching ? _results(context) : _grouped(context)),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: context.t.secondary)),
        ),
      );

  Widget _grouped(BuildContext context) {
    final k = context.t;
    if (_all.isEmpty) return _empty(context, 'No chats yet');
    final groups = groupConversations(_all, (widget.now ?? DateTime.now)());
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        for (final g in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(g.label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: k.secondary)),
          ),
          for (final c in g.items) _tile(context, c),
        ],
      ],
    );
  }

  Widget _results(BuildContext context) {
    if (_hits.isEmpty) return _empty(context, 'No chats match');
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      children: [for (final h in _hits) _tile(context, h.conversation, snippet: h.snippet)],
    );
  }

  Widget _tile(BuildContext context, Conversation c, {String snippet = ''}) {
    final k = context.t;
    final active = c.id == widget.chat.activeId;
    return ListTile(
      key: ValueKey('chat-${c.id}'),
      minTileHeight: 56,
      selected: active,
      selectedTileColor: k.surface,
      title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, color: k.text)),
      subtitle: snippet.isEmpty
          ? null
          : Text(snippet, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
      trailing: c.pinned ? Icon(Icons.push_pin, size: 18, color: k.secondary) : null,
      onTap: () => _open(c.id),
      onLongPress: () => _longPress(c),
    );
  }
}
