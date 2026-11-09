import 'package:flutter/material.dart';

import '../app_state.dart';
import '../chat/chat_controller.dart';
import '../history/conversation_store.dart';
import '../models/model_downloads.dart';
import '../theme.dart';
import 'settings/widgets.dart' show GroupLabel;
import '../layout/adaptive.dart' show ContentWidth;

/// A chat model is on its way to this device (downloading or being copied in), with how far it has got (0..1, null when not known).
({double? fraction})? modelArriving(AppState app, [ModelDownloads? downloads]) {
  final d = downloads ?? ModelDownloads.shared;
  final f = d?.current;
  if (d != null && f != null && !d.isSearchModel(f)) return (fraction: d.total > 0 ? d.done / d.total : null);
  if (app.copyProgress != null) return (fraction: app.copyProgress);
  return null;
}

/// The Modules tile's line under "Ask" with no model: "Needs a model", or "Model downloading 40%" while one comes.
String askOffDetail(AppState app, [ModelDownloads? downloads]) {
  final coming = modelArriving(app, downloads);
  if (coming == null) return 'Needs a model';
  final f = coming.fraction;
  return f == null ? 'Model downloading' : 'Model downloading ${(f * 100).clamp(0, 100).toStringAsFixed(0)}%';
}

/// The small note Ask shows with no model on this device: one line and one button. While a model downloads it says Ask turns on
/// when it is ready, with "See download". [onClose] adds "Close" (a cache:// link opened it over another screen).
class AskOffNote extends StatelessWidget {
  const AskOffNote({super.key, required this.app, required this.onChooseModel, this.downloads, this.onClose});

  final AppState app;
  final ModelDownloads? downloads;

  /// Opens Models ("Choose a model", and "See download", whose row is there).
  final VoidCallback onChooseModel;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final d = downloads ?? ModelDownloads.shared;
    return ListenableBuilder(
      listenable: Listenable.merge([app, ?d]),
      builder: (context, _) {
        final coming = modelArriving(app, d) != null;
        return Container(
          key: const ValueKey('ask-off-note'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                coming ? 'A model is downloading. Ask turns on when it is ready.' : 'Ask needs a model on this device.',
                style: TextStyle(fontSize: 16, color: k.text),
              ),
              const SizedBox(height: 8),
              // Wraps: a large text size or a narrow window puts Close under the button.
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    key: const ValueKey('ask-off-choose'),
                    onPressed: onChooseModel,
                    child: Text(coming ? 'See download' : 'Choose a model'),
                  ),
                  if (onClose != null) TextButton(key: const ValueKey('ask-off-close'), onPressed: onClose, child: const Text('Close')),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Ask with no model on this device: the note, then the saved chats, which stay readable (a tap opens one read-only).
class AskOffPage extends StatefulWidget {
  const AskOffPage({super.key, required this.app, required this.chat, required this.onChooseModel, this.onOpenChat, this.downloads, this.onClose});

  final AppState app;
  final ChatController chat;
  final ModelDownloads? downloads;
  final VoidCallback onChooseModel;

  /// Opens a saved chat (read-only); null leaves the list out.
  final void Function(int id)? onOpenChat;

  /// "Close" in the note (a cache:// link opened the page).
  final VoidCallback? onClose;

  @override
  State<AskOffPage> createState() => _AskOffPageState();
}

class _AskOffPageState extends State<AskOffPage> {
  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      key: const ValueKey('ask-off'),
      appBar: AppBar(title: const Text('Ask')),
      body: ValueListenableBuilder<int>(
        valueListenable: widget.chat.historyRevision,
        builder: (context, _, _) {
          final open = widget.onOpenChat;
          final chats = open == null ? const <Conversation>[] : widget.chat.store?.list() ?? const <Conversation>[];
          return LayoutBuilder(builder: (context, cts) => ListView(
            padding: ContentWidth.padFor(cts.maxWidth, min: 16).copyWith(top: 12, bottom: 24),
            children: [
              AskOffNote(app: widget.app, downloads: widget.downloads, onChooseModel: widget.onChooseModel, onClose: widget.onClose),
              if (chats.isNotEmpty) ...[
                const SizedBox(height: 20),
                const GroupLabel('Saved chats'),
                for (final c in chats)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Material(
                      color: k.surface,
                      borderRadius: BorderRadius.circular(12),
                      child: ListTile(
                        key: ValueKey('saved-chat-${c.id}'),
                        minTileHeight: 56,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, color: k.text)),
                        trailing: c.pinned ? Icon(Icons.push_pin, size: 18, color: k.secondary) : Icon(Icons.chevron_right, color: k.secondary),
                        onTap: () => open!(c.id),
                      ),
                    ),
                  ),
              ],
            ],
          ));
        },
      ),
    );
  }
}

/// The Ask module, behind the one rule (Ask is available when a chat model is on this device). With one: [ask]. With none: a
/// conversation on screen stays, read-only (a model deleted under it, a saved chat or a chat shortcut opened); otherwise the
/// note and the saved chats. A model that arrives makes the open chat live again.
class AskGate extends StatefulWidget {
  const AskGate({super.key, required this.app, required this.chat, required this.ask, required this.onChooseModel, required this.onLeave, this.downloads});

  final AppState app;
  final ChatController chat;
  final ModelDownloads? downloads;

  /// Builds the Ask screen; read-only (no model) with [onBack] to leave the chat.
  final Widget Function({required bool readOnly, VoidCallback? onBack}) ask;
  final VoidCallback onChooseModel;

  /// Back from a chat that was not opened from the saved list (it was on screen when the model went, or a Home shortcut opened
  /// it): Home.
  final VoidCallback onLeave;

  @override
  State<AskGate> createState() => _AskGateState();
}

class _AskGateState extends State<AskGate> {
  bool _fromList = false;
  late bool _was = widget.app.askAvailable;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onApp);
  }

  @override
  void dispose() {
    widget.app.removeListener(_onApp);
    super.dispose();
  }

  void _onApp() {
    final now = widget.app.askAvailable;
    // The last model went while an answer was being written: it stops and keeps what it had written.
    if (_was && !now && widget.chat.busy) widget.chat.stop();
    _was = now;
  }

  void _back() {
    final fromList = _fromList;
    _fromList = false;
    widget.chat.newChat();
    if (!fromList) widget.onLeave();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.app, widget.chat]),
    builder: (context, _) {
      if (widget.app.askAvailable) return widget.ask(readOnly: false);
      if (widget.chat.activeId != null || widget.chat.messages.isNotEmpty) return widget.ask(readOnly: true, onBack: _back);
      return AskOffPage(
        app: widget.app,
        chat: widget.chat,
        downloads: widget.downloads,
        onChooseModel: widget.onChooseModel,
        onOpenChat: (id) {
          _fromList = true;
          widget.chat.openConversation(id);
        },
      );
    },
  );
}
