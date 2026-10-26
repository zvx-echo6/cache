import 'package:flutter/material.dart';

import '../app_state.dart';
import '../chat/answer_markdown.dart';
import '../chat/chat_controller.dart';
import '../chat/tool_loop.dart';
import '../browse/zim_urls.dart';
import '../theme.dart';
import 'models_screen.dart';

class AskScreen extends StatefulWidget {
  const AskScreen({super.key, required this.app, required this.chat, this.onOpenSource});

  final AppState app;
  final ChatController chat;

  /// Opens the article a citation points at (a `zim:` address) in Browse.
  final void Function(String address)? onOpenSource;

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_scrollDown);
  }

  @override
  void dispose() {
    widget.chat.removeListener(_scrollDown);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.maxScrollExtent - pos.pixels < 400) {
        _scroll.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty || !widget.chat.canSend) return;
    _input.clear();
    widget.chat.send(text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _openModels() => openModels(context, widget.app);

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        titleSpacing: 16,
        title: ListenableBuilder(
          listenable: widget.app,
          builder: (context, _) {
            final app = widget.app;
            final name = app.loading != null
                ? 'Loading…'
                : app.active == null ? 'No model' : app.displayName(app.active!);
            return InkWell(
              onTap: _openModels,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: app.active == null && app.loading == null ? k.warning : k.text)),
                    ),
                    Icon(Icons.arrow_drop_down, color: k.secondary),
                  ],
                ),
              ),
            );
          },
        ),
        actions: [
          IconButton(
            tooltip: 'New chat',
            iconSize: 26,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: widget.chat.newChat,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: widget.chat,
                builder: (context, _) {
                  final msgs = widget.chat.messages;
                  if (msgs.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          widget.app.active == null
                              ? 'Choose a model at the top to start.'
                              : 'Ask a question. Cache looks in your sources before it answers.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 18, color: k.secondary),
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: msgs.length,
                    itemBuilder: (_, i) => msgs[i].isUser ? _UserBubble(msgs[i].text) : _AssistantBlock(msgs[i], onOpenSource: widget.onOpenSource),
                  );
                },
              ),
            ),
            _composer(context),
          ],
        ),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final k = context.t;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.chat, widget.app]),
      builder: (context, _) {
        final busy = widget.chat.busy;
        final ready = widget.app.active != null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: ready,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: 18),
                  decoration: InputDecoration(hintText: ready ? 'Ask anything' : 'No model'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 52,
                height: 52,
                child: busy
                    ? IconButton.filled(
                        tooltip: 'Stop',
                        onPressed: widget.chat.stop,
                        style: IconButton.styleFrom(backgroundColor: k.emergency, foregroundColor: k.background),
                        icon: const Icon(Icons.stop_rounded, size: 28),
                      )
                    : IconButton.filled(
                        tooltip: 'Send',
                        onPressed: ready ? _send : null,
                        icon: const Icon(Icons.arrow_upward_rounded, size: 28),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 4, left: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(18)),
        child: Text(text, style: TextStyle(fontSize: 18, height: 1.35, color: k.text)),
      ),
    );
  }
}

class _AssistantBlock extends StatefulWidget {
  const _AssistantBlock(this.msg, {this.onOpenSource});

  final ChatMessage msg;
  final void Function(String address)? onOpenSource;

  @override
  State<_AssistantBlock> createState() => _AssistantBlockState();
}

class _AssistantBlockState extends State<_AssistantBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final m = widget.msg;
    final showText = m.phase == TurnPhase.answering || m.phase == TurnPhase.done;
    final status = switch (m.phase) {
      TurnPhase.thinking => 'Thinking…',
      TurnPhase.searching => 'Searching your sources…',
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showText && m.text.isNotEmpty)
            AnswerMarkdown(m.text),
          if (status != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: k.secondary)),
                  const SizedBox(width: 10),
                  Text(status, style: TextStyle(fontSize: 15, color: k.secondary)),
                ],
              ),
            ),
          if (m.error != null)
            Text(m.error!, style: TextStyle(fontSize: 16, color: k.emergency)),
          if (m.isDone && m.error == null && m.text.isNotEmpty) _sourcesRow(context, m),
          if (m.isDone && m.error == null && m.text.isEmpty)
            Text('No answer was produced.', style: TextStyle(fontSize: 15, color: k.secondary)),
        ],
      ),
    );
  }

  Widget _sourcesRow(BuildContext context, ChatMessage m) {
    final k = context.t;
    if (m.sources.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('Not from your sources', style: TextStyle(fontSize: 14, color: k.secondary)),
      );
    }
    final n = m.sources.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => setState(() => _open = !_open),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(20)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.menu_book_outlined, size: 18, color: k.accent),
                    const SizedBox(width: 8),
                    Text(n == 1 ? '1 source' : '$n sources',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.accent)),
                    Icon(_open ? Icons.expand_less : Icons.expand_more, size: 20, color: k.accent),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_open)
          for (final s in m.sources)
            Container(
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(12)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onOpenSource != null && isZimAddress(s.result.address)
                    ? () => widget.onOpenSource!(s.result.address)
                    : null,
                child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('[${s.id}] ${s.result.title}',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
                  if (s.result.snippet.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(s.result.snippet, style: TextStyle(fontSize: 14, color: k.secondary)),
                    ),
                  if (isZimAddress(s.result.address))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Open the article', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.accent)),
                    ),
                ],
              ),
              ),
              ),
            ),
      ],
    );
  }
}
