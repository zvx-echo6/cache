import 'dart:io';

import 'package:flutter/material.dart';

import '../layout/adaptive.dart';
import '../platform.dart' as plat;

import '../guide/guide_book.dart';
import '../guide/guide_reader.dart';
import '../layout/layout_state.dart';
import '../layout/modules_screen.dart' as modules show addToHome;
import '../screens/hold.dart';
import '../sources/libraries_state.dart';
import '../sources/sources_state.dart';
import '../theme.dart';
import '../video/format.dart';
import 'catalogue_screen.dart' show AddToLibraryScreen;
import 'browse_state.dart';
import 'zim_dl.dart';
import '../downloads/download_row.dart';
import 'library_actions.dart';
import 'reader_screen.dart';
import 'web/device_api.dart' show DeviceJob;
import 'web/device_flows.dart';
import 'web/device_library.dart' show kUploadedAgain;
import 'web/device_widgets.dart';
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
      _say('That source is not on this device any more.');
      return;
    }
    _openZim(z, address: address);
  }

  /// The list's context inside the two panes (a tablet opens items beside the list).
  BuildContext? _pane;

  void _openZim(ZimFile z, {String? address}) {
    openDetail(
      _pane ?? context,
      key: 'zim:${z.path}',
      builder: (_) => ZimReaderScreen(
          sources: sources,
          zim: z,
          address: address,
          layout: widget.layout,
          itemMenu: (ctx, addPage) => showLibraryMenu(ctx, _zimActions(z, addToHome: addPage)),
        ),
    );
  }

  /// The guide that ships in the app opens as a book: its chapters, links and search, with the library's usual menu.
  Future<void> _openGuideBook(LibraryItem l) async {
    final book = await GuideBook.load();
    if (!mounted) return;
    await Navigator.of(context).push(guideContentsRoute(book, menu: (ctx) async => showLibraryMenu(ctx, _libraryActions(l))));
  }

  void _openLibrary(LibraryItem l) {
    openDetail(_pane ?? context, key: 'library:${l.folderName}', builder: (_) => LibraryItemScreen(libraries: libs!, item: l, menu: (ctx) => showLibraryMenu(ctx, _libraryActions(l))));
  }

  int? get _free => b.device != null ? b.device!.spaceForDialog.usable : b.downloader.freeSpace(sources.zimsDir?.path ?? '.');

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
      // A picture is kept beside the file on the phone; the browser has no such file to change.
      changeIcon: b.device != null ? null : () async {
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
      again: b.device?.wasUploaded(z.fileName) == true ? kUploadedAgain : null,
    );
  }

  LibraryActions _libraryActions(LibraryItem l) => LibraryActions(
    title: libs!.titleOf(l),
    bytes: l.size,
    free: _free,
    changeIcon: b.device != null ? null : () async {
      final dest = File('${l.path}${Platform.pathSeparator}icon.png');
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

  /// A library package the device downloaded is added by the app, with the usual prompts.
  Future<void> _addPackage(DeviceJob job) async {
    final libraries = libs;
    final device = b.device;
    if (libraries == null || device == null) return;
    await addPackageOnDevice(context, libraries, job.name);
    // It no longer waits, whether it was added or not (a package that failed is deleted, as on a phone).
    await device.packageHandled(job);
  }

  void _add() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AddToLibraryScreen(browse: b)));

  @override
  Widget build(BuildContext context) {
    final pane = TwoPane(
      id: 'library',
      listName: 'Library',
      list: Builder(
        builder: (c) {
          _pane = c;
          return _list(c);
        },
      ),
    );
    final device = b.device;
    // In a browser a file dropped anywhere on the Library is added from this computer.
    return device == null
        ? pane
        : DropOverlay(onFile: (f) => addFromComputer(context, device: device, libraries: libs, dropped: f), child: pane);
  }

  Widget _list(BuildContext context) {
    final k = context.t;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('Library'), actions: [?paneHideButton(context)]),
      bottomNavigationBar: b.device == null ? null : DeviceStorageFooter(device: b.device!),
      body: ListenableBuilder(
        listenable: Listenable.merge([b, sources, ?libs]),
        builder: (context, _) {
          _maybeCheck();
          final transfers = b.transfers.values.toList();
          final task = libs?.task;
          final items = sources.zims.length + (libs?.libraries.length ?? 0);
          final empty = items == 0 && transfers.isEmpty && task == null && (b.device == null || (b.device!.jobs.isEmpty && b.device!.upload == null));
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              if (empty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                  child: Text(
                    sources.unavailable ??
                        (b.device == null
                            ? 'Nothing in your library yet. Add Wikipedia, medical guides, survival manuals or your own library, and read them with no signal.'
                            : 'Nothing in your library yet. Add Wikipedia, medical guides, survival manuals or your own library. They are kept on this device and work with no internet.'),
                    key: const ValueKey('library-empty'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: k.secondary),
                  ),
                )
              // In a browser the icons cannot be changed, so the line about changing them is left out; the line about what is going on stays.
              else if (b.device == null || b.device!.activityHint != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    b.device?.activityHint ?? 'Icons come from each source\'s website; change one from the hold menu.',
                    style: TextStyle(fontSize: 12, color: k.secondary),
                  ),
                ),
              if (b.device != null) DeviceLibraryTop(device: b.device!, onAddPackage: _addPackage),
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
    final icon = b.device != null ? null : File('${l.path}${Platform.pathSeparator}icon.png');
    final Widget? badge = switch (phase) {
      LibraryPhase.indexing => RowBadge(s.indexFraction(l) == null ? 'Building index' : 'Building index ${(s.indexFraction(l)! * 100).toStringAsFixed(0)}%', color: k.secondary),
      LibraryPhase.failed => RowBadge("Can't be opened", color: k.warning),
      LibraryPhase.opening => RowBadge('Getting ready', color: k.secondary),
      _ => null,
    };
    final n = s.docsOf(l);
    return LibraryRow(
      key: ValueKey('library-${l.folderName}'),
      icon: icon != null && icon.existsSync() ? icon : null,
      title: s.titleOf(l),
      // The guide ships inside the app; every other library is one the person added.
      detail: [s.isGuide(l) ? 'Built in' : 'Your own', if (n > 0) '$n ${n == 1 ? 'entry' : 'entries'}', formatBytes(l.size)].join(' · '),
      badge: badge,
      onTap: () => s.isGuide(l) ? _openGuideBook(l) : _openLibrary(l),
      onHold: () => showLibraryMenu(context, _libraryActions(l)),
    );
  }

  Widget _transferRow(CacheTokens k, ZimTransfer t) {
    final e = t.entry;
    return DownloadRow(
      key: ValueKey('transfer-${e.id}'),
      keyBase: 'transfer-${e.id}',
      title: t.replaces == null ? e.title : 'Updating ${e.title}',
      state: zimDl(t),
      actions: zimActions(context, b, e),
    );
  }

  Widget _taskRow(CacheTokens k, AddTask t) {
    final s = libs!;
    return DownloadRow(
      key: const ValueKey('add-task'),
      keyBase: 'add-task',
      title: 'Adding ${t.name}',
      state: addDl(t),
      actions: addActions(s, t),
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
    // A mouse has no hold: in a browser the menu opens from a "..." that shows while the pointer is over the row.
    final more = plat.isWeb && onHold != null;
    Widget content(bool hover) => ConstrainedBox(
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
                if (more) SizedBox(width: 36, height: 32, child: hover ? IconButton(key: const ValueKey('row-menu'), padding: EdgeInsets.zero, tooltip: 'More', icon: const Icon(Icons.more_horiz, size: 20), onPressed: onHold) : null),
              ],
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Holdable(
        onTap: onTap,
        onHold: onHold,
        child: more ? HoverReveal(builder: content) : content(false),
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
        final l = s.libraries.where((x) => x.path == item.path).firstOrNull ?? item;
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
          appBar: AppBar(leading: paneShowButton(context), 
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
