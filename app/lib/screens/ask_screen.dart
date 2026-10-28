import 'package:flutter/material.dart';

import '../app_state.dart';
import '../chat/answer_markdown.dart';
import '../chat/answer_reports.dart';
import '../chat/chat_controller.dart';
import '../chat/tool_loop.dart';
import '../chat/navigation_action.dart';
import '../browse/zim_urls.dart';
import '../history/share.dart';
import '../layout/layout_state.dart';
import '../location/location_service.dart';
import '../theme.dart';
import 'answer_reports_ui.dart';
import 'history_drawer.dart';
import 'models_screen.dart';

class AskScreen extends StatefulWidget {
  const AskScreen({
    super.key,
    required this.app,
    required this.chat,
    this.onOpenSource,
    this.onOpenNavigation,
    this.share = shareMarkdown,
    this.layout,
    this.location,
    this.reports,
  });

  /// Where "Report this answer" keeps its reports (on this phone); the app's store when null.
  final AnswerReports? reports;

  /// Where a chat's "Add to Home" puts its shortcut.
  final LayoutState? layout;
  final LocationService? location;

  final AppState app;
  final ChatController chat;
  final ShareMarkdown share;

  /// Opens the article a citation points at (a `zim:` address) in Browse.
  final void Function(String address)? onOpenSource;
  final void Function(NavigationAction action)? onOpenNavigation;

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

  Future<void> _report(ChatMessage m, String question) async {
    final r = await showReportSheet(context);
    if (r == null || !mounted) return;
    final active = widget.app.active;
    await (widget.reports ?? AnswerReports.shared).add(AnswerReport(
      at: DateTime.now(),
      question: question,
      answer: m.text,
      model: active == null ? 'unknown model' : widget.app.displayName(active),
      reason: r.reason,
      note: r.note,
      sources: [for (final s in m.sources) s.result.title],
    ));
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(content: Text('Report saved on this phone. Find it in Settings > Assistant.')));
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


  Future<void> _useLocation() async {
    final location = widget.location;
    if (location == null) return;
    var explained = false;
    if (!location.enabled) {
      final enable = await _explainLocation();
      if (!enable || !mounted) return;
      await location.setEnabled(true);
      explained = true;
    }
    final ok = location.streamHeld
        ? await location.prepareForChat(isCancelled: () => !mounted) != null
        : await location.request(explain: explained ? () async => true : _explainLocation);
    if (!mounted) return;
    final text = ok ? 'Location ready for your next question.' : switch (location.problem) {
      LocationProblem.permissionBlocked => "Location is blocked. You can allow it in your phone's settings.",
      LocationProblem.permissionDenied => 'Cache was not allowed to use your location.',
      LocationProblem.serviceOff => "Your phone's location is switched off.",
      LocationProblem.off => 'Location is off.',
      LocationProblem.noFix => 'Could not get a position yet. You can still chat.',
      null => 'Location was not changed. You can still chat.',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      action: switch (location.problem) {
        LocationProblem.permissionBlocked => SnackBarAction(label: 'Settings', onPressed: location.openAppSettings),
        LocationProblem.serviceOff => SnackBarAction(label: 'Settings', onPressed: location.openLocationSettings),
        _ => null,
      },
    ));
  }

  Future<bool> _explainLocation() async => await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Use your location?'),
      content: const Text('Cache uses your location to find nearby places. You can turn location off in Settings.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
      ],
    ),
  ) == true;

  void _openModels() => openModels(context, widget.app);

  Future<void> _shareChat() async {
    final id = widget.chat.activeId;
    final md = id == null ? null : widget.chat.exportMarkdown(id);
    final title = id == null ? null : widget.chat.store?.get(id)?.title;
    if (md != null) await widget.share(title ?? 'Chat', md);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      drawer: HistoryDrawer(chat: widget.chat, layout: widget.layout),
      appBar: AppBar(
        titleSpacing: 0,
        leading: Builder(
          builder: (ctx) => IconButton(
            tooltip: 'Chats',
            iconSize: 26,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
            icon: const Icon(Icons.menu),
          ),
        ),
        title: ListenableBuilder(
          listenable: widget.app,
          builder: (context, _) {
            final app = widget.app;
            final name = app.loading != null
                ? 'Loading…'
                : app.active == null
                ? 'No model'
                : app.displayName(app.active!);
            return InkWell(
              onTap: _openModels,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: app.active == null && app.loading == null
                              ? k.warning
                              : k.text,
                        ),
                      ),
                    ),
                    Icon(Icons.arrow_drop_down, color: k.secondary),
                  ],
                ),
              ),
            );
          },
        ),
        actions: [
          ListenableBuilder(
            listenable: widget.chat,
            builder: (context, _) => widget.chat.activeId == null || widget.chat.busy
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Share chat',
                    iconSize: 26,
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: _shareChat,
                    icon: const Icon(Icons.ios_share),
                  ),
          ),
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
                    itemBuilder: (_, i) => msgs[i].isUser
                        ? _UserBubble(msgs[i].text)
                        : _AssistantBlock(
                            msgs[i],
                            onOpenSource: widget.onOpenSource,
                            onOpenNavigation: widget.onOpenNavigation,
                            onReport: () => _report(msgs[i], i > 0 && msgs[i - 1].isUser ? msgs[i - 1].text : ''),
                          ),
                  );
                },
              ),
            ),

            if (widget.location case final location?)
              ListenableBuilder(
                listenable: location,
                builder: (context, _) => Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: location.busy || widget.chat.busy ? null : _useLocation,
                    icon: const Icon(Icons.my_location, size: 18),
                    label: Text(location.fix == null ? 'Use my location' : 'Location ready'),
                  ),
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
                  decoration: InputDecoration(
                    hintText: ready ? 'Ask anything' : 'No model',
                  ),
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
                        style: IconButton.styleFrom(
                          backgroundColor: k.emergency,
                          foregroundColor: k.background,
                        ),
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
        decoration: BoxDecoration(
          color: k.surface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 18, height: 1.35, color: k.text),
        ),
      ),
    );
  }
}

class _AssistantBlock extends StatefulWidget {
  const _AssistantBlock(this.msg, {this.onOpenSource, this.onOpenNavigation, this.onReport});

  final ChatMessage msg;
  final VoidCallback? onReport;
  final void Function(String address)? onOpenSource;
  final void Function(NavigationAction action)? onOpenNavigation;

  @override
  State<_AssistantBlock> createState() => _AssistantBlockState();
}

class _AssistantBlockState extends State<_AssistantBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final m = widget.msg;
    final showText =
        m.phase == TurnPhase.answering || m.phase == TurnPhase.done;
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
          if (showText && m.text.isNotEmpty) AnswerMarkdown(m.text),
          for (final action in m.navigationActions)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (m.navigationActions.length > 1)
                    Text(action.route?.destinationName.isNotEmpty == true
                        ? 'To ${action.route!.destinationName}'
                        : 'Route ${m.navigationActions.indexOf(action) + 1}'),
                  if (action.route == null)
                    const Text('Navigation unavailable: this route snapshot is no longer available.')
                  else
                    Semantics(
                      label: m.navigationActions.length > 1 ? 'To ${action.route!.destinationName}' : null,
                      child: OutlinedButton.icon(
                        onPressed: widget.onOpenNavigation == null ? null : () => widget.onOpenNavigation!(action),
                        icon: const Icon(Icons.directions_outlined),
                        label: const Text('Open navigation'),
                      ),
                    ),
                ],
              ),
            ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: k.secondary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    status,
                    style: TextStyle(fontSize: 15, color: k.secondary),
                  ),
                ],
              ),
            ),
          if (m.error != null)
            Text(m.error!, style: TextStyle(fontSize: 16, color: k.emergency)),
          if (m.isDone && m.error == null && m.text.isNotEmpty)
            _sourcesRow(context, m),
          if (m.isDone && m.error == null && m.text.isNotEmpty && widget.onReport != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('report-answer'),
                onPressed: widget.onReport,
                icon: Icon(Icons.flag_outlined, size: 18, color: k.secondary),
                label: Text('Report this answer', style: TextStyle(fontSize: 14, color: k.secondary)),
              ),
            ),
          if (m.isDone && m.error == null && m.text.isEmpty && m.navigationActions.isEmpty)
            Text(
              'No answer was produced.',
              style: TextStyle(fontSize: 15, color: k.secondary),
            ),
        ],
      ),
    );
  }

  Widget _sourcesRow(BuildContext context, ChatMessage m) {
    final k = context.t;
    if (m.sources.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'Not from your sources',
          style: TextStyle(fontSize: 14, color: k.secondary),
        ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: k.surface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.menu_book_outlined, size: 18, color: k.accent),
                    const SizedBox(width: 8),
                    Text(
                      n == 1 ? '1 source' : '$n sources',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: k.accent,
                      ),
                    ),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: k.accent,
                    ),
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
              decoration: BoxDecoration(
                color: k.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap:
                    widget.onOpenSource != null &&
                        isZimAddress(s.result.address)
                    ? () => widget.onOpenSource!(s.result.address)
                    : null,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '[${s.id}] ${s.result.title}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: k.text,
                        ),
                      ),
                      if (s.result.snippet.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            s.result.snippet,
                            style: TextStyle(fontSize: 14, color: k.secondary),
                          ),
                        ),
                      if (isZimAddress(s.result.address))
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Open the article',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: k.accent,
                            ),
                          ),
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
