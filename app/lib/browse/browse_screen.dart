import 'dart:io';

import 'package:flutter/material.dart';

import '../layout/layout_state.dart';
import '../layout/modules_screen.dart' as modules show addToHome;
import '../screens/hold.dart';
import '../screens/libraries_screen.dart';
import '../sources/libraries_state.dart';
import '../sources/sources_state.dart';
import '../theme.dart';
import '../video/format.dart';
import 'catalogue_screen.dart' show AddToLibraryScreen;
import 'browse_state.dart';
import 'library_actions.dart';
import 'reader_screen.dart';
import 'zim_urls.dart';

/// The Library module: one list of everything (Kiwix ZIMs and your own libraries), each with its icon, name, a short description and
/// its size, and a badge only for an exception. Tap opens an item; press and hold opens its menu. "Add to Library" is the one way
/// to add anything.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({
    super.key,
    required this.browse,
    required this.active,
    this.layout,
  });

  final BrowseState browse;

  /// Where "Add to Home" puts its shortcut (offered only when this is given).
  final LayoutState? layout;

  /// True while the Library is the screen showing.
  final bool active;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  bool _checked = false;

  BrowseState get b => widget.browse;
  SourcesState get sources => b.sources;
  LibrariesState? get libs => b.libraries;

  @override
  void initState() {
    super.initState();
    b.addListener(_onBrowse);
    _maybeCheck();
  }

  @override
  void didUpdateWidget(BrowseScreen old) {
    super.didUpdateWidget(old);
    _maybeCheck();
    _onBrowse();
  }

  @override
  void dispose() {
    b.removeListener(_onBrowse);
    super.dispose();
  }

  /// Looks for updates once, the first time the tab is shown and there are ZIMs to check.
  void _maybeCheck() {
    if (!widget.active || _checked || sources.zims.isEmpty) return;
    _checked = true;
    b.checkUpdates();
  }

  /// A citation asked for an article.
  void _onBrowse() {
    final a = b.requestedAddress;
    if (a == null || !widget.active) return;
    b.requestedAddress = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openAddress(a));
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  void _openAddress(String address) {
    final id = zimIdOfAddress(address);
    final z = id == null ? null : sources.zimById(id);
    if (z == null) {
      _say('That source is not on this phone any more.');
      return;
    }
    _openZim(z, address: address);
  }

  void _openZim(ZimFile z, {String? address}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ZimReaderScreen(
          sources: sources,
          zim: z,
          address: address,
          layout: widget.layout,
          itemMenu: (ctx, addPage) => showLibraryMenu(ctx, _zimActions(z, addToHome: addPage)),
        ),
      ),
    );
  }

  void _openLibrary(LibraryItem l) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LibraryItemScreen(libraries: libs!, item: l, menu: (ctx) => showLibraryMenu(ctx, _libraryActions(l)))));
  }

  int? get _free => b.downloader.freeSpace(sources.zimsDir?.path ?? '.');

  LibraryActions _zimActions(ZimFile z, {VoidCallback? addToHome}) {
    final id = sources.idOf(z);
    final layout = widget.layout;
    return LibraryActions(
      title: sources.titleOf(z),
      bytes: z.size,
      free: _free,
      checkUpdate: sources.originOf(z) == null
          ? null
          : () async {
              await b.checkUpdates();
              if (!mounted) return;
              final u = b.updates[z.path];
              _say(b.updateError ?? (u == null ? '${sources.titleOf(z)} is up to date' : 'Update ready: ${u.release}, ${formatBytes(u.size)}'));
            },
      changeIcon: () async {
        final dest = File('${z.path}.icon.png');
        if (await pickIconInto(dest)) {
          await FileImage(dest).evict();
          if (mounted) setState(() {});
        } else if (mounted) {
          _say('Choose a picture (PNG, JPEG, WebP or GIF).');
        }
      },
      addToHome: addToHome ??
          (layout == null || id == null
              ? null
              : () async {
                  final address = await sources.zimMainPage(id);
                  if (mounted) modules.addToHome(context, layout, Shortcut.page(address: address, title: sources.titleOf(z), library: 'Library'));
                }),
      delete: () => sources.remove(z),
    );
  }

  LibraryActions _libraryActions(LibraryItem l) => LibraryActions(
    title: libs!.titleOf(l),
    bytes: l.size,
    free: _free,
    changeIcon: () async {
      final dest = File('${l.dir.path}${Platform.pathSeparator}icon.png');
      if (await pickIconInto(dest)) {
        await FileImage(dest).evict();
        if (mounted) setState(() {});
      } else if (mounted) {
        _say('Choose a picture (PNG, JPEG, WebP or GIF).');
      }
    },
    // The guide that ships in the app is always there.
    delete: libs!.isGuide(l) ? null : () => libs!.remove(l),
  );

  void _add() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AddToLibraryScreen(browse: b)));

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('Library')),
      body: ListenableBuilder(
        listenable: Listenable.merge([b, sources, ?libs]),
        builder: (context, _) {
          _maybeCheck();
          final transfers = b.transfers.values.toList();
          final task = libs?.task;
          final items = sources.zims.length + (libs?.libraries.length ?? 0);
          final empty = items == 0 && transfers.isEmpty && task == null;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              if (empty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                  child: Text(
                    sources.unavailable ?? 'Nothing in your library yet. Add Wikipedia, medical guides, survival manuals or your own library, and read them with no signal.',
                    key: const ValueKey('library-empty'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: k.secondary),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text('Icons come from each source\'s website; change one from the hold menu.', style: TextStyle(fontSize: 12, color: k.secondary)),
                ),
              for (final t in transfers) _transferRow(k, t),
              if (task != null) _taskRow(k, task),
              for (final z in sources.zims) _zimRow(k, z),
              for (final l in libs?.libraries ?? const <LibraryItem>[]) _libraryRow(k, l),
              if (b.updateError != null && items > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text("Couldn't check for updates: ${b.updateError}", style: TextStyle(fontSize: 12, color: k.warning)),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const ValueKey('add-to-library'),
                  onPressed: _add,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add to Library'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _zimRow(CacheTokens k, ZimFile z) {
    final phase = sources.phaseOf(z);
    final update = b.updates[z.path];
    final o = sources.originOf(z);
    final Widget? badge = switch (phase) {
      ZimPhase.indexing => RowBadge(sources.indexFraction(z) == null ? 'Indexing' : 'Indexing ${(sources.indexFraction(z)! * 100).toStringAsFixed(0)}%', color: k.secondary),
      ZimPhase.failed => RowBadge("Can't be read", color: k.warning),
      ZimPhase.waiting when sources.coreReady => RowBadge('Waiting to index', color: k.secondary),
      _ when update != null && !b.transfers.containsKey(update.id) =>
        RowBadge('Update ready', color: k.accent, onTap: () => downloadZim(context, b, update, replaces: z)),
      _ => null,
    };
    final canOpen = sources.idOf(z) != null && phase != ZimPhase.failed;
    return LibraryRow(
      key: ValueKey('zim-${z.fileName}'),
      icon: sources.iconOf(z),
      title: sources.titleOf(z),
      detail: [if (o != null && o.summary.isNotEmpty) o.summary, formatBytes(z.size)].join(' · '),
      badge: badge,
      onTap: canOpen ? () => _openZim(z) : null,
      onHold: () => showLibraryMenu(context, _zimActions(z)),
    );
  }

  Widget _libraryRow(CacheTokens k, LibraryItem l) {
    final s = libs!;
    final phase = s.phaseOf(l);
    final icon = File('${l.dir.path}${Platform.pathSeparator}icon.png');
    final Widget? badge = switch (phase) {
      LibraryPhase.indexing => RowBadge(s.indexFraction(l) == null ? 'Building index' : 'Building index ${(s.indexFraction(l)! * 100).toStringAsFixed(0)}%', color: k.secondary),
      LibraryPhase.failed => RowBadge("Can't be opened", color: k.warning),
      LibraryPhase.opening => RowBadge('Opening', color: k.secondary),
      _ => null,
    };
    final n = s.docsOf(l);
    return LibraryRow(
      key: ValueKey('library-${l.folderName}'),
      icon: icon.existsSync() ? icon : null,
      title: s.titleOf(l),
      detail: ['Your own', if (n > 0) '$n ${n == 1 ? 'entry' : 'entries'}', formatBytes(l.size)].join(' · '),
      badge: badge,
      onTap: () => _openLibrary(l),
      onHold: () => showLibraryMenu(context, _libraryActions(l)),
    );
  }

  Widget _transferRow(CacheTokens k, ZimTransfer t) {
    final e = t.entry;
    final waiting = t.phase == TransferPhase.blockedByMobileData;
    final paused = t.phase == TransferPhase.paused;
    final failed = t.phase == TransferPhase.failed;
    final line = switch (t.phase) {
      TransferPhase.blockedByMobileData => 'Waiting for Wi-Fi · ${formatBytes(e.size)}',
      TransferPhase.paused => 'Paused · ${formatBytes(t.done)} of ${formatBytes(t.total)}',
      TransferPhase.failed => t.error ?? 'The download stopped',
      TransferPhase.starting => 'Starting…',
      TransferPhase.verifying => 'Checking the file…',
      TransferPhase.adding => 'Adding to your library…',
      TransferPhase.downloading => '${formatBytes(t.done)} of ${formatBytes(t.total)}',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.replaces == null ? e.title : 'Updating ${e.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                        Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: failed || waiting ? k.warning : k.secondary)),
                      ],
                    ),
                  ),
                  if (waiting)
                    TextButton(key: const ValueKey('download-now'), onPressed: () => b.download(e, replaces: t.replaces, allowMobile: true), child: const Text('Download now'))
                  else if (failed)
                    TextButton(onPressed: () => b.download(e, replaces: t.replaces), child: const Text('Try again'))
                  else if (paused)
                    IconButton(key: const ValueKey('resume-download'), tooltip: 'Resume', icon: const Icon(Icons.play_arrow), onPressed: () => b.resume(e))
                  else if (t.phase == TransferPhase.downloading || t.phase == TransferPhase.starting)
                    IconButton(key: const ValueKey('pause-download'), tooltip: 'Pause', icon: const Icon(Icons.pause), onPressed: () => b.pause(e)),
                  IconButton(key: const ValueKey('cancel-download'), tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: () => b.cancel(e)),
                ],
              ),
              if (!waiting && !failed)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 2),
                  child: LinearProgressIndicator(value: t.phase == TransferPhase.downloading || paused ? t.fraction : null, minHeight: 3),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _taskRow(CacheTokens k, AddTask t) {
    final s = libs!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Adding ${t.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                    Text(t.running ? addStepText(t) : t.error!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.running ? k.secondary : k.warning)),
                    if (t.running) Padding(padding: const EdgeInsets.only(top: 4, right: 8), child: LinearProgressIndicator(value: t.fraction, minHeight: 3)),
                  ],
                ),
              ),
              if (t.running)
                IconButton(key: const ValueKey('cancel-add'), tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: s.cancelAdd)
              else
                IconButton(tooltip: 'Dismiss', icon: const Icon(Icons.close), onPressed: s.dismissTask),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row of the Library: the icon (the source's own, or a letter), the name on one line, the description and size on one line,
/// and a badge for an exception. The size always stays visible; a long name ends in an ellipsis.
class LibraryRow extends StatelessWidget {
  const LibraryRow({super.key, required this.title, required this.detail, this.icon, this.badge, this.onTap, this.onHold});

  final String title;
  final String detail;
  final File? icon;
  final Widget? badge;
  final VoidCallback? onTap;
  final VoidCallback? onHold;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Holdable(
        onTap: onTap,
        onHold: onHold,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                LetterIcon(title: title, file: icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                      Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                    ],
                  ),
                ),
                if (badge != null) ...[const SizedBox(width: 8), badge!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small square icon: the picture when there is one, else the first letter of the name.
class LetterIcon extends StatelessWidget {
  const LetterIcon({super.key, required this.title, this.file, this.size = 32});

  final String title;
  final File? file;
  final double size;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final letter = title.isEmpty ? '?' : title.characters.first.toUpperCase();
    final fallback = Center(child: Text(letter, style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: k.accent)));
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        color: k.background,
        child: file == null ? fallback : Image.file(file!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}

/// One of your own libraries, opened: what it holds, with the same menu as the list behind "...".
class LibraryItemScreen extends StatelessWidget {
  const LibraryItemScreen({super.key, required this.libraries, required this.item, required this.menu});

  final LibrariesState libraries;
  final LibraryItem item;
  final Future<void> Function(BuildContext context) menu;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = libraries;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final l = s.libraries.where((x) => x.dir.path == item.dir.path).firstOrNull ?? item;
        final whole = s.wholeLibraryOnly(l);
        final rows = <(String, String)>[
          ('Entries', '${s.docsOf(l)}'),
          if (s.versionOf(l) != null) ('Version', s.versionOf(l)!),
          ('Size', formatBytes(l.size)),
          if (s.modelOf(l) != null) ('Search model', s.modelOf(l)!),
          if (whole == true) ('Updates', 'Whole library only'),
          if (s.failureOf(l) != null) ('Problem', s.failureOf(l)!),
        ];
        return Scaffold(
          appBar: AppBar(
            title: Text(s.titleOf(l), maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [IconButton(key: const ValueKey('item-menu'), tooltip: 'More', icon: const Icon(Icons.more_horiz), onPressed: () => menu(context))],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 120, child: Text(r.$1, style: TextStyle(fontSize: 14, color: k.secondary))),
                      Expanded(child: Text(r.$2, style: TextStyle(fontSize: 14, color: k.text))),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Text('Cache searches and cites this library when you ask.', style: TextStyle(fontSize: 13, color: k.secondary)),
              if (whole == true) ...[
                const SizedBox(height: 8),
                Text('Its entries do not say which document they came from, so a newer copy replaces the whole library.', style: TextStyle(fontSize: 13, color: k.secondary)),
              ],
            ],
          ),
        );
      },
    );
  }
}
