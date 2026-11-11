part of 'add_pdf_pages_option.dart';

// Watch a folder: the screens of the owner's mockups (watch-folder-mockups.html), frame by frame. Where you start it (Add to
// Library, beside Add a folder), the confirm screen, the Watched folders list (and its place beside Add to Library on a wide
// window), Stop watching, the summary of what a check added, and a folder that can't be reached (Choose again).

/// Whether this phone also checks with Cache closed (Android: a few times a day, adding while charging); iOS checks each time Cache opens. Tests set it.
bool Function() watchChecksInBackground = () => Platform.isAndroid;

/// "2 hours ago", "yesterday", "3 days ago": when a folder was checked.
String watchCheckedWords(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inHours < 24) return agoWords(d.isNegative ? Duration.zero : d);
  return dayWords(then, now) == 'yesterday' ? 'yesterday' : agoWords(d);
}

/// "7 PDFs added so far".
String watchAddedWords(int n) => n == 1 ? '1 PDF added so far' : '$n PDFs added so far';

/// Watch a folder: the folder picker (the one Add a folder uses), then the confirm screen. [fromList]: started from the Watched
/// folders list, which it goes back to.
Future<void> startWatchFolder(BuildContext context, {bool fromList = false}) async {
  final nav = Navigator.of(context);
  final w = watchFoldersShared;
  final state = addPdfShared;
  if (w == null || state == null) return;
  final AddPdfChoice? picked;
  try {
    picked = await addPdfFolderPicker();
  } catch (e) {
    logError('Watch a folder: the folder picker failed', error: e);
    return;
  }
  final choice = picked;
  if (choice == null || choice.folderRoot == null || !nav.mounted) return;
  await nav.push(MaterialPageRoute<void>(builder: (_) => WatchFolderConfirmPage(watch: w, state: state, choice: choice, fromList: fromList)));
}

/// Opens the Watched folders list as a page of its own.
void openWatchedFolders(BuildContext context) {
  final w = watchFoldersShared;
  if (w == null) return;
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WatchedFoldersPage(watch: w)));
}

/// The watch icon: a folder with a clock, drawn as the mockup's.
class _WatchIconPainter extends CustomPainter {
  const _WatchIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(3, 7)
        ..arcToPoint(const Offset(4.5, 5.5), radius: const Radius.circular(1.5))
        ..lineTo(9, 5.5)
        ..lineTo(11, 8)
        ..lineTo(18.5, 8)
        ..arcToPoint(const Offset(20, 9.5), radius: const Radius.circular(1.5))
        ..lineTo(20, 11),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(3, 7)
        ..lineTo(3, 17.5)
        ..arcToPoint(const Offset(4.5, 19), radius: const Radius.circular(1.5), clockwise: false)
        ..lineTo(12, 19),
      p,
    );
    canvas.drawCircle(const Offset(17, 17), 4, p);
    canvas.drawPath(
      Path()
        ..moveTo(17, 15)
        ..lineTo(17, 17)
        ..lineTo(18.3, 17.8),
      p,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WatchIconPainter old) => old.color != color;
}

/// The watch icon's tile, as the other rows' tiles.
class _WatchTile extends StatelessWidget {
  const _WatchTile();

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Color.alphaBlend(k.secondary.withValues(alpha: 0.12), k.surface), borderRadius: BorderRadius.circular(9)),
      child: CustomPaint(size: const Size.square(21), painter: _WatchIconPainter(k.accent)),
    );
  }
}

/// "Watch a folder" in Add to Library, under Add a folder; once a folder is watched, "Watched folders" with the count and the last
/// check (and, in the danger color, how many can't be reached). [onOpenList]: a wide window shows the list beside it instead of
/// opening a page; [selected]: it is shown there now.
class WatchFolderRow extends StatelessWidget {
  const WatchFolderRow({super.key, required this.watch, this.onOpenList, this.selected = false});

  final WatchFoldersState watch;
  final VoidCallback? onOpenList;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    const radius = BorderRadius.vertical(top: Radius.circular(4), bottom: Radius.circular(14));
    return ListenableBuilder(
      listenable: watch,
      builder: (context, _) {
        final n = watch.folders.length;
        final bad = watch.unreachable;
        final last = watch.lastCheck;
        final sub = n == 0
            ? 'New PDFs in it are added on their own'
            : '${n == 1 ? '1 folder' : '$n folders'}${bad == 0 && last != null ? ' · checked ${watchCheckedWords(last, watch.now)}' : ''}';
        return Material(
          color: k.surface,
          borderRadius: radius,
          child: InkWell(
            key: const ValueKey('watch-folder'),
            borderRadius: radius,
            onTap: () {
              if (n == 0) {
                unawaited(startWatchFolder(context));
              } else if (onOpenList != null) {
                onOpenList!();
              } else {
                openWatchedFolders(context);
              }
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: 52),
              foregroundDecoration: selected ? BoxDecoration(borderRadius: radius, border: Border.all(color: k.accent, width: 2)) : null,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const _WatchTile(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(n == 0 ? 'Watch a folder' : 'Watched folders', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                        Text(sub, key: const ValueKey('watch-folder-sub'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                        if (bad > 0)
                          Text("$bad can't be reached", key: const ValueKey('watch-folder-bad'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: k.emergency)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: k.secondary),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A hint line in the page's secondary color.
class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.padding = const EdgeInsets.fromLTRB(6, 2, 6, 10)});

  final String text;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(padding: padding, child: Text(text, style: TextStyle(fontSize: 14, height: 1.4, color: context.t.secondary)));
}

/// The filled pill ("Watch a folder", "Choose again").
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onPressed, this.icon, this.height = 50, super.key});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final style = FilledButton.styleFrom(
      backgroundColor: k.primary,
      foregroundColor: k.onPrimary,
      minimumSize: Size(0, height),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      shape: const StadiumBorder(),
    );
    final text = Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700));
    return icon == null
        ? FilledButton(onPressed: onPressed, style: style, child: text)
        : FilledButton.icon(onPressed: onPressed, style: style, icon: Icon(icon, size: 20), label: text);
  }
}

/// The page padding of the watch screens: a reading width on a wide window.
EdgeInsets _watchPadding(double width) {
  final side = width > 600 ? (width - 560) / 2 : 12.0;
  return EdgeInsets.fromLTRB(side, 4, side, 24);
}

// ---- the confirm screen

/// After picking the folder: the same card stack as Add a folder (the folder, what is in it now, the library with Change), the one
/// new line When it checks, and two ways to start: add what is in it now, or watch for new PDFs only.
class WatchFolderConfirmPage extends StatefulWidget {
  const WatchFolderConfirmPage({super.key, required this.watch, required this.state, required this.choice, this.battery, this.background, this.fromList = false});

  final WatchFoldersState watch;
  final AddPdfState state;

  /// The folder and the PDFs in it now.
  final AddPdfChoice choice;

  /// The battery now (for the time); the device's own when null.
  final BatteryReading? battery;

  /// Checks with Cache closed too (Android); [watchChecksInBackground] when null.
  final bool? background;
  final bool fromList;

  @override
  State<WatchFolderConfirmPage> createState() => _WatchFolderConfirmPageState();
}

class _WatchFolderConfirmPageState extends State<WatchFolderConfirmPage> {
  late AddPdfTarget _target = addPdfTargets(widget.state.libraries).first;
  BatteryReading? _battery;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _battery = widget.battery;
    if (_battery == null) {
      unawaited((widget.state.battery ?? readBattery)().then((b) {
        if (mounted) setState(() => _battery = b);
      }).catchError((_) {}));
    }
  }

  Future<void> _change() async {
    final t = await showAddPdfLibrarySheet(context, targets: addPdfTargets(widget.state.libraries), current: _target, fileName: widget.choice.folder ?? 'Folder');
    if (t != null && mounted) setState(() => _target = t);
  }

  Future<void> _watch(bool addExisting) async {
    setState(() => _busy = true);
    try {
      final c = widget.choice;
      await widget.watch.watch(root: c.folderRoot!, name: c.folder ?? 'Folder', target: _target, addExisting: addExisting);
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (widget.fromList) {
        nav.pop();
      } else {
        await nav.pushReplacement(MaterialPageRoute<void>(builder: (_) => WatchedFoldersPage(watch: widget.watch)));
      }
    } catch (e) {
      if (mounted) say(context, 'The folder could not be watched: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final c = widget.choice;
    final bg = widget.background ?? watchChecksInBackground();
    final time = addPdfTimeWords(c.bytes, _battery);
    return Scaffold(
      appBar: AppBar(title: const Text('Watch a folder')),
      body: LayoutBuilder(
        builder: (context, cs) => ListView(
          padding: _watchPadding(cs.maxWidth),
          children: [
            _Card(
              child: Row(
                children: [
                  const FileTile(icon: Icons.folder_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.folder ?? 'Folder', key: const ValueKey('watch-name'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                        Text('This folder and its subfolders', style: TextStyle(fontSize: 13, color: k.secondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _Stack(rows: [
              _Fact(
                label: 'In it now',
                value: c.files.isEmpty ? 'No PDFs yet' : '${addPdfCountWords(c)} · ${formatBytes(c.bytes)} · ${time.time}',
                valueWeight: FontWeight.w500, valueKey: const ValueKey('watch-count'),
                note: c.files.isEmpty ? null : 'Longer if pages are scans. A book you already have becomes a spare copy.',
              ),
              _Fact(
                label: 'Library',
                value: _target.title,
                valueWeight: FontWeight.w500, valueKey: const ValueKey('watch-library'),
                note: _target.isNew ? 'New. Your own PDFs go here. It syncs like any library.' : null,
                trailing: _Ghost(key: const ValueKey('watch-change'), label: 'Change', onPressed: _busy ? null : _change),
              ),
              _Fact(
                label: 'When it checks',
                value: bg ? 'A few times a day, and when you open Cache' : 'Each time you open Cache',
                valueWeight: FontWeight.w500, valueKey: const ValueKey('watch-when'),
                note: bg ? 'New PDFs are added when you open Cache, or while charging.' : 'Apple does not allow a folder to be watched in the background.',
              ),
            ]),
            const SizedBox(height: 14),
            if (c.files.isNotEmpty) ...[
              _Big(key: const ValueKey('watch-add'), label: 'Watch and add ${addPdfCountWords(c)}', busy: _busy, onPressed: _busy ? null : () => _watch(true)),
              const SizedBox(height: 12),
            ],
            _Big(key: const ValueKey('watch-new-only'), label: 'Watch new PDFs only', outlined: true, onPressed: _busy ? null : () => _watch(false)),
            const _Hint('A PDF you remove from this folder stays in Cache.', padding: EdgeInsets.fromLTRB(6, 8, 6, 0)),
            Center(child: _Txt(key: const ValueKey('watch-cancel'), label: 'Cancel', onPressed: _busy ? null : () => Navigator.of(context).maybePop())),
          ],
        ),
      ),
    );
  }
}

// ---- the list

/// Watched folders: each folder's last check, the count added, Check now and Stop watching; a folder that can't be reached gets
/// the red stripe and Choose again. [pane]: beside Add to Library on a wide window (one hint line on top, no back button).
class WatchedFoldersPage extends StatelessWidget {
  const WatchedFoldersPage({super.key, required this.watch, this.background, this.pane = false});

  final WatchFoldersState watch;
  final bool? background;
  final bool pane;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final bg = background ?? watchChecksInBackground();
    final top = bg ? 'Checks a few times a day. New PDFs are added when you open Cache, or while charging.' : 'Checked each time you open Cache. Apple does not allow background checks.';
    const removed = 'A PDF removed from a folder stays in Cache.';
    final list = ListenableBuilder(
      listenable: watch,
      builder: (context, _) => LayoutBuilder(
        builder: (context, cs) => ListView(
          key: const ValueKey('watched-list'),
          padding: pane ? const EdgeInsets.fromLTRB(6, 4, 12, 24) : _watchPadding(cs.maxWidth),
          children: [
            _Hint(pane ? '$top $removed' : top),
            if (watch.folders.isEmpty) const _Hint('No folders are watched.'),
            for (final f in watch.folders) ...[WatchedFolderCard(watch: watch, folder: f), const SizedBox(height: 8)],
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _Pill(key: const ValueKey('watch-another'), label: 'Watch a folder', icon: Icons.add, onPressed: () => startWatchFolder(context, fromList: !pane)),
              ),
            ),
            if (!pane) const _Hint(removed, padding: EdgeInsets.fromLTRB(6, 8, 6, 10)),
          ],
        ),
      ),
    );
    if (pane) {
      return Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 14, 12, 8),
              child: Text('Watched folders', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: k.text)),
            ),
            Expanded(child: Align(alignment: Alignment.topLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: list))),
          ],
        ),
      );
    }
    return Scaffold(appBar: AppBar(title: const Text('Watched folders')), body: list);
  }
}

/// Stop watching? Asked once; it says what stays.
Future<bool> confirmStopWatching(BuildContext context, WatchedFolder f) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Stop watching ${f.name}?'),
        content: Text([
          if (f.added > 0) f.added == 1 ? 'The 1 PDF already added stays in your library.' : 'The ${f.added} PDFs already added stay in your library.',
          'New PDFs in the folder are no longer added.',
        ].join(' ')),
        actions: [
          _Txt(key: const ValueKey('watch-keep'), label: 'Keep watching', onPressed: () => Navigator.of(ctx).pop(false)),
          _Txt(key: const ValueKey('watch-stop-yes'), label: 'Stop watching', danger: true, onPressed: () => Navigator.of(ctx).pop(true)),
        ],
      ),
    ) ==
    true;

/// One watched folder on the list.
class WatchedFolderCard extends StatelessWidget {
  const WatchedFolderCard({super.key, required this.watch, required this.folder});

  final WatchFoldersState watch;
  final WatchedFolder folder;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final f = folder;
    final bad = f.unreachable && !f.checking;
    final last = f.lastCheck;
    final lastWords = last == null ? null : watchCheckedWords(last, watch.now);
    final head = f.checking ? 'Checking now' : (bad ? "Can't reach this folder" : (lastWords == null ? 'Not checked yet' : 'Checked $lastWords'));
    final small = TextStyle(fontSize: 13, height: 1.35, color: k.secondary);
    final skipped = f.skipped.length;
    Future<void> stop() async {
      if (await confirmStopWatching(context, f)) await watch.stop(f);
    }

    return Container(
      key: ValueKey('watched-${f.id}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        border: bad ? Border(left: BorderSide(color: k.emergency, width: 4)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const FileTile(icon: Icons.folder_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: k.text)),
                    Text('${f.where} · and subfolders', style: TextStyle(fontSize: 13, color: k.secondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(head, key: ValueKey('watched-head-${f.id}'), style: TextStyle(fontSize: 14, color: k.text)),
          const SizedBox(height: 2),
          Text(bad && lastWords != null ? 'Last checked $lastWords · ${watchAddedWords(f.added)}' : watchAddedWords(f.added), key: ValueKey('watched-added-${f.id}'), style: small),
          const SizedBox(height: 2),
          Text('Goes to ${f.libraryTitle}', style: small),
          if (f.checking) Padding(padding: const EdgeInsets.only(top: 8), child: _bar(context, f.checkProgress)),
          if (bad)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'It may have been moved or renamed, or access was turned off. Checks for it are paused. PDFs already added are not affected.',
                style: TextStyle(fontSize: 13, height: 1.35, color: k.emergency),
              ),
            ),
          // a PDF it could not add: counted here, with Try again on the same line (the action row stays as drawn)
          if (skipped > 0 && !bad)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text("$skipped couldn't be added", key: ValueKey('watched-skipped-${f.id}'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: k.emergency)),
                  const SizedBox(width: 4),
                  _Txt(key: ValueKey('watch-try-again-${f.id}'), label: 'Try again', onPressed: () => watch.tryAgain(f)),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (bad)
                _Pill(
                  key: ValueKey('watch-choose-again-${f.id}'),
                  label: 'Choose again',
                  height: 42,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WatchChooseAgainPage(watch: watch, folder: f))),
                )
              else if (f.checking)
                // drawn as the mockup: the outlined button faded, not the theme's grey
                IgnorePointer(child: Opacity(opacity: 0.5, child: _Ghost(key: ValueKey('watch-checking-${f.id}'), label: 'Checking', onPressed: () {})))
              else
                _Ghost(key: ValueKey('watch-check-${f.id}'), label: 'Check now', icon: Icons.refresh, onPressed: () => watch.check(f)),
              _Txt(key: ValueKey('watch-stop-${f.id}'), label: 'Stop watching', danger: true, onPressed: stop),
            ],
          ),
        ],
      ),
    );
  }
}

// ---- Choose again

/// A folder that can't be reached, picked again: the same folder or another. Its library, count and history are kept.
class WatchChooseAgainPage extends StatefulWidget {
  const WatchChooseAgainPage({super.key, required this.watch, required this.folder});

  final WatchFoldersState watch;
  final WatchedFolder folder;

  @override
  State<WatchChooseAgainPage> createState() => _WatchChooseAgainPageState();
}

class _WatchChooseAgainPageState extends State<WatchChooseAgainPage> {
  AddPdfChoice? _picked;

  Future<void> _choose() async {
    try {
      final c = await addPdfFolderPicker();
      if (c != null && c.folderRoot != null && mounted) setState(() => _picked = c);
    } catch (e) {
      logError('Watch a folder: the folder picker failed', error: e);
    }
  }

  void _go() {
    final p = _picked!;
    unawaited(widget.watch.chooseAgain(widget.folder, root: p.folderRoot!, name: p.folder ?? widget.folder.name));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final f = widget.folder;
    final picked = _picked;
    final watchButton = _Big(key: const ValueKey('watch-again'), label: 'Watch this folder', onPressed: picked == null ? () {} : _go);
    return Scaffold(
      appBar: AppBar(title: const Text('Choose again')),
      body: LayoutBuilder(
        builder: (context, cs) => ListView(
          padding: _watchPadding(cs.maxWidth),
          children: [
            _Card(
              child: Row(
                children: [
                  const FileTile(icon: Icons.folder_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Pick ${f.name} again', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                        Text('Choose the same folder, or a different one.', style: TextStyle(fontSize: 13, color: k.secondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _Stack(rows: [
              _Fact(label: 'Folder', value: picked?.folder ?? 'Not chosen', valueWeight: FontWeight.w500, valueKey: const ValueKey('watch-again-folder'), trailing: _Ghost(key: const ValueKey('watch-again-choose'), label: 'Choose folder', onPressed: _choose)),
              _Fact(label: 'Library', value: f.libraryTitle, note: 'Unchanged', valueWeight: FontWeight.w500),
            ]),
            const _Hint('PDFs already added stay. Anything already added from this folder is skipped as a spare copy, not added twice.', padding: EdgeInsets.fromLTRB(6, 10, 6, 10)),
            // drawn faded until a folder is chosen, as the mockup
            picked == null ? IgnorePointer(child: Opacity(opacity: 0.45, child: watchButton)) : watchButton,
            const SizedBox(height: 6),
            Center(child: _Txt(label: 'Cancel', onPressed: () => Navigator.of(context).maybePop())),
          ],
        ),
      ),
    );
  }
}

// ---- what a check added

/// The "From Manuals" tag on a PDF a watched folder found.
class _FromTag extends StatelessWidget {
  const _FromTag(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: Color.alphaBlend(k.secondary.withValues(alpha: 0.12), k.surface), borderRadius: BorderRadius.circular(10)),
      child: Text('From $name', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: k.secondary)),
    );
  }
}

/// "18.0 MB · My books", and the folder's tag when a watched folder found it.
Widget _sizeLine(BuildContext context, AddPdfJob job, TextStyle style) {
  final name = job.watchName;
  return Text.rich(
    TextSpan(
      text: '${formatBytes(job.bytes)} · ${job.libraryTitle}',
      children: [
        if (name != null) ...[
          const TextSpan(text: ' · '),
          WidgetSpan(alignment: PlaceholderAlignment.middle, child: _FromTag(name)),
        ],
      ],
    ),
    key: ValueKey('add-pdf-size-line-${job.id}'),
    style: style,
  );
}

/// One summary card for the PDFs one check of a watched folder added: how many and where, then each in the existing result notes
/// (filed, in Unsorted with Place, Other and Leave, a spare copy), and Open Bookshelves.
class WatchCheckSummary extends StatelessWidget {
  const WatchCheckSummary({super.key, required this.state, required this.jobs, this.deps});

  final AddPdfState state;

  /// The check's PDFs that were added, newest first (as the progress page lists them).
  final List<AddPdfJob> jobs;
  final LibraryDeps? deps;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final first = jobs.last;
    final n = jobs.length;
    final d = deps;
    final ago = DateTime.now().difference(first.added);
    return _Card(
      child: Column(
        key: ValueKey('watch-summary-${first.checkId}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _DoneDot(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${n == 1 ? '1 new PDF' : '$n new PDFs'} from ${first.watchName ?? 'a folder'}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                    Text('Added to ${first.libraryTitle} · checked ${agoWords(ago.isNegative ? Duration.zero : ago)}', style: TextStyle(fontSize: 13, color: k.secondary)),
                  ],
                ),
              ),
            ],
          ),
          for (final (i, j) in jobs.reversed.indexed) ...[SizedBox(height: i == 0 ? 12 : 8), _summaryNote(context, j)],
          const SizedBox(height: 12),
          _Big(
            key: ValueKey('watch-summary-shelves-${first.checkId}'),
            label: 'Open Bookshelves',
            outlined: true,
            onPressed: d == null ? null : () => LibraryNav.of(context).open(context, bookshelvesSpec(d)),
          ),
        ],
      ),
    );
  }

  Widget _summaryNote(BuildContext context, AddPdfJob job) {
    final k = context.t;
    final r = job.result ?? const {};
    final same = (r['same'] as List?) ?? const [];
    final shelf = (r['shelf'] as Map?)?.cast<String, dynamic>();
    final suggested = (r['suggested'] as Map?)?.cast<String, dynamic>();
    final d = deps;
    final book = addPdfBook(d, job);
    final fill = k.background;
    if (same.isNotEmpty) {
      final copies = d?.shelves.copies;
      return _Note(
        key: ValueKey('watch-note-${job.id}'),
        fill: fill,
        tone: k.accent,
        title: job.title,
        body: 'A spare copy of an existing book.',
        actions: [
          if (!job.noteDone)
            _Ghost(
              label: 'Not the same book',
              onPressed: copies == null || book == null
                  ? null
                  : () async {
                      await copies.notSame(book, (r['copy'] ?? '') as String);
                      state.noteHandled(job);
                    },
            ),
        ],
      );
    }
    if (shelf != null) {
      final div = (shelf['div'] ?? '') as String;
      final call = book?.callNumber;
      return _Note(key: ValueKey('watch-note-${job.id}'), fill: fill, tone: k.ok, title: job.title, body: 'Filed in ${cdsChipLabel(div)}${call == null ? '' : ' · $call'}');
    }
    final guess = suggested?['div'] as String?;
    final placer = d?.shelves.placer;
    return _Note(
      key: ValueKey('watch-note-${job.id}'),
      fill: fill,
      tone: k.warning,
      title: job.title,
      body: guess == null ? "In Unsorted. Cache wasn't sure where it goes." : 'In Unsorted. Looks like ${cdsChipLabel(guess)}.',
      actions: job.noteDone
          ? const []
          : [
              if (guess != null)
                FilledButton(
                  key: ValueKey('watch-place-${job.id}'),
                  style: FilledButton.styleFrom(backgroundColor: k.primary, foregroundColor: k.onPrimary, minimumSize: const Size(0, 40), shape: const StadiumBorder()),
                  onPressed: placer == null || book == null
                      ? null
                      : () async {
                          await placer.place([(book, guess)]);
                          state.noteHandled(job);
                        },
                  child: const Text('Place'),
                ),
              _Ghost(label: guess == null ? 'Place it' : 'Other', onPressed: d == null || book == null ? null : () => openPlace(context, d, book)),
              _Txt(label: 'Leave', onPressed: () => state.noteHandled(job)),
            ],
    );
  }
}
